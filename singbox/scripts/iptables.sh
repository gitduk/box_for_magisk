#!/system/bin/sh

# ============================================================
# iptables 规则管理脚本
# 支持 redirect、tproxy、tun 三种模式
# ============================================================

# 加载依赖（先加载，确保函数可用）
source "${0%/*}/constants.sh"
source "${0%/*}/utils.sh"
source "${0%/*}/config.sh"

# -------------------- 错误处理函数 --------------------
handle_error() {
  local exit_code=$1
  local line_number=$2

  # 只在非正常退出时记录错误
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 2 ]; then
    log error "Error occurred at line ${line_number} with exit code ${exit_code}"
  fi

  cleanup_all
  exit "$exit_code"
}

# 设置错误处理（在函数定义之后）
set -e
trap 'handle_error $? $LINENO' ERR

# -------------------- 安全检查函数 --------------------
check_requirements() {
  check_root || exit 1

  # 检查 iptables 命令
  if ! command_exists iptables; then
    log error "iptables command not found"
    exit 1
  fi

  # 检查必要的变量
  local required_vars="BOX_USER BOX_GROUP FWMARK"
  for var in $required_vars; do
    eval "value=\$$var"
    if [ -z "$value" ]; then
      log error "Required variable ${var} is not set"
      exit 1
    fi
  done

  # 根据模式检查端口配置
  case "$1" in
    redirect)
      if [ -z "$redir_port" ]; then
        log error "Failed to start: redirect mode requires redir_port"
        log error ""
        log error "Your ${CONFIG_JSON} does not have a 'redirect' inbound configured."
        log error "Please add a redirect inbound to your config.json, or change network_mode in ${SETTINGS_INI}"
        log error ""
        log error "Example redirect inbound configuration:"
        log error '  {'
        log error '    "type": "redirect",'
        log error '    "tag": "redirect-in",'
        log error '    "listen": "::",'
        log error '    "listen_port": 7892'
        log error '  }'
        log error ""
        log error "Or change network_mode to match your config:"
        log error "  - If you have 'tun' inbound: network_mode=\"tun\""
        log error "  - If you have 'tproxy' inbound: network_mode=\"tproxy\""
        exit 1
      fi
      ;;
    tproxy)
      if [ -z "$tproxy_port" ]; then
        log error "Failed to start: tproxy mode requires tproxy_port"
        log error ""
        log error "Your ${CONFIG_JSON} does not have a 'tproxy' inbound configured."
        log error "Please add a tproxy inbound to your config.json, or change network_mode in ${SETTINGS_INI}"
        log error ""
        log error "Example tproxy inbound configuration:"
        log error '  {'
        log error '    "type": "tproxy",'
        log error '    "tag": "tproxy-in",'
        log error '    "listen": "::",'
        log error '    "listen_port": 7891'
        log error '  }'
        log error ""
        log error "Or change network_mode to match your config:"
        log error "  - If you have 'tun' inbound: network_mode=\"tun\""
        log error "  - If you have 'redirect' inbound: network_mode=\"redirect\""
        exit 1
      fi
      ;;
  esac
}

# -------------------- 获取 iptables 命令 --------------------
get_iptables_cmd() {
  local table="$1"
  local family="$2"

  case "$family" in
    ipv6) echo "ip6tables -w ${IPTABLES_TIMEOUT} -t ${table}" ;;
    *) echo "iptables -w ${IPTABLES_TIMEOUT} -t ${table}" ;;
  esac
}

# -------------------- 清理策略路由 --------------------
cleanup_policy_routing() {
  log info "Cleaning policy routing rules"

  # 清理 IPv4 路由规则
  ip rule del fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}" 2>/dev/null || true
  ip route del local default dev lo table "${ROUTE_TABLE}" 2>/dev/null || true

  # 清理 IPv6 路由规则
  if [ "${ipv6}" = "true" ]; then
    ip -6 rule del fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}" 2>/dev/null || true
    ip -6 route del local default dev lo table "${ROUTE_TABLE}" 2>/dev/null || true
    ip -6 rule del unreachable pref "${ROUTE_PREF}" 2>/dev/null || true
  fi

  # 刷新路由表
  ip route flush table "${ROUTE_TABLE}" 2>/dev/null || true
  ip -6 route flush table "${ROUTE_TABLE}" 2>/dev/null || true
}

# -------------------- 清理 iptables 规则 --------------------
cleanup_rules() {
  local table="$1"
  local family="${2:-ipv4}"
  local iptables=$(get_iptables_cmd "$table" "$family")

  log info "Cleaning ${family} iptables rules for ${table} table"

  # 从主链中移除引用
  for chain in $CHAINS; do
    $iptables -D PREROUTING -j "$chain" 2>/dev/null || true
    $iptables -D OUTPUT -j "$chain" 2>/dev/null || true
    $iptables -D FORWARD -i "$chain" -j ACCEPT 2>/dev/null || true
    $iptables -D FORWARD -o "$chain" -j ACCEPT 2>/dev/null || true
  done

  # 清理自定义链
  for chain in $CHAINS; do
    $iptables -F "$chain" 2>/dev/null || true
    $iptables -X "$chain" 2>/dev/null || true
  done

  # 清理特定规则
  if [ "$table" = "nat" ] && [ "$family" = "ipv4" ]; then
    $iptables -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${BOX_USER}" --gid-owner "${BOX_GROUP}" -j REJECT 2>/dev/null || true
  fi

  if [ "$table" = "mangle" ]; then
    if [ "$family" = "ipv6" ]; then
      local ip6tables=$(get_iptables_cmd "$table" "ipv6")
      $ip6tables -D OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null || true
    fi
  fi

  if [ "$table" = "filter" ]; then
    if [ -n "$tun_device" ]; then
      $iptables -D FORWARD -i "${tun_device}" -j ACCEPT 2>/dev/null || true
      $iptables -D FORWARD -o "${tun_device}" -j ACCEPT 2>/dev/null || true
    fi
  fi
}

# -------------------- 清理限制脚本 --------------------
cleanup_limit() {
  # 调用外部脚本清理厂商限制
  if [ -f "${0%/*}/rmlimit.sh" ]; then
    sh "${0%/*}/rmlimit.sh" 2>/dev/null || true
  fi
}

# -------------------- 统一的清理函数 --------------------
cleanup_all() {
  log info "Starting cleanup of all rules"

  cleanup_rules nat ipv4
  cleanup_rules mangle ipv4
  cleanup_rules filter ipv4

  if [ "${ipv6}" = "true" ]; then
    cleanup_rules mangle ipv6
    cleanup_rules filter ipv6
  fi

  cleanup_policy_routing
  cleanup_limit

  log info "Cleanup completed"
}

# -------------------- 初始化链 --------------------
init_chains() {
  local table="$1"
  local family="$2"
  local iptables=$(get_iptables_cmd "$table" "$family")

  # 先清理现有链
  for chain in $CHAINS; do
    $iptables -D PREROUTING -j "$chain" 2>/dev/null || true
    $iptables -D OUTPUT -j "$chain" 2>/dev/null || true
    $iptables -F "$chain" 2>/dev/null || true
    $iptables -X "$chain" 2>/dev/null || true
  done

  # 创建新链
  for chain in $CHAINS; do
    if ! $iptables -N "$chain" 2>/dev/null; then
      $iptables -F "$chain" 2>/dev/null || true
    fi
  done
}

# -------------------- 处理应用包过滤 --------------------
handle_packages() {
  local table="$1"
  local chain="$2"
  local action="$3"
  local family="$4"
  local iptables=$(get_iptables_cmd "$table" "$family")

  # 获取包列表
  local packages="$(pm list packages -U 2>/dev/null)"
  local custom_packages=""
  local config_packages=""

  # 读取自定义列表
  if [ "$action" = "exclude" ] && [ -f "${EXCLUDE_LIST}" ]; then
    custom_packages="$(cat "${EXCLUDE_LIST}" 2>/dev/null | grep -v '^#' | grep -v '^$')"
  elif [ "$action" = "include" ] && [ -f "${INCLUDE_LIST}" ]; then
    custom_packages="$(cat "${INCLUDE_LIST}" 2>/dev/null | grep -v '^#' | grep -v '^$')"
  fi

  # 读取配置文件中的包列表
  if [ -f "${JQ_PATH}" ] && [ -f "${CONFIG_JSON}" ]; then
    config_packages="$(${JQ_PATH} -r ".inbounds[] | select(.type == \"tun\") | .${action}_package[] // empty" "${CONFIG_JSON}" 2>/dev/null | grep -v '^$' || true)"
  fi

  # 合并包列表
  local package_list=$(echo -e "${config_packages}\n${custom_packages}" | grep -v '^$' | sort -u || true)

  # 处理每个包
  for package in $package_list; do
    local uid=$(get_app_uid "$package")
    [ -z "$uid" ] && continue

    log info "${action} package: ${package}, uid: ${uid}"

    case "${table}" in
      nat)
        if [ "$action" = "exclude" ]; then
          $iptables -A "${chain}" -p tcp -m owner --uid-owner "${uid}" -j RETURN 2>/dev/null || true
          $iptables -A "${chain}" -p udp -m owner --uid-owner "${uid}" -j RETURN 2>/dev/null || true
        else
          $iptables -A "${chain}" -p tcp -m owner --uid-owner "${uid}" -j REDIRECT --to-ports "${redir_port}" 2>/dev/null || true
          $iptables -A "${chain}" -p udp -m owner --uid-owner "${uid}" -j REDIRECT --to-ports "${redir_port}" 2>/dev/null || true
        fi
        ;;
      mangle)
        if [ "$action" = "exclude" ]; then
          $iptables -A "${chain}" -p tcp -m owner --uid-owner "${uid}" -j RETURN 2>/dev/null || true
          $iptables -A "${chain}" -p udp -m owner --uid-owner "${uid}" -j RETURN 2>/dev/null || true
        else
          $iptables -A "${chain}" -p tcp -m owner --uid-owner "${uid}" -j MARK --set-xmark "${FWMARK}" 2>/dev/null || true
          $iptables -A "${chain}" -p udp -m owner --uid-owner "${uid}" -j MARK --set-xmark "${FWMARK}" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

# -------------------- DNS 处理 --------------------
setup_dns() {
  local table="$1"
  local chain="$2"
  local family="$3"
  local iptables=$(get_iptables_cmd "$table" "$family")

  for proto in tcp udp; do
    case "${table}" in
      nat)
        $iptables -A "${chain}" -p "${proto}" --dport 53 -j REDIRECT --to-ports "${redir_port}" 2>/dev/null || true
        ;;
      mangle)
        $iptables -A "${chain}" -p "${proto}" --dport 53 -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${FWMARK}" 2>/dev/null || true
        ;;
    esac
  done
}

# -------------------- 处理内网流量 --------------------
bypass_intranet() {
  local table="$1"
  local family="$2"
  local iptables=$(get_iptables_cmd "$table" "$family")

  if [ "$family" = "ipv4" ]; then
    for subnet in "${intranet[@]}"; do
      $iptables -A BOX_EXTERNAL -d "${subnet}" -j RETURN 2>/dev/null || true
      $iptables -A BOX_LOCAL -d "${subnet}" -j RETURN 2>/dev/null || true
    done
  else
    for subnet in "${intranet6[@]}"; do
      $iptables -A BOX_EXTERNAL -d "${subnet}" -j RETURN 2>/dev/null || true
      $iptables -A BOX_LOCAL -d "${subnet}" -j RETURN 2>/dev/null || true
    done
  fi
}

# -------------------- 连接跟踪优化 --------------------
setup_conntrack_optimization() {
  local table="$1"
  local family="$2"
  local iptables=$(get_iptables_cmd "$table" "$family")

  $iptables -A BOX_EXTERNAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
  $iptables -A BOX_LOCAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
}

# -------------------- REDIRECT 模式实现 --------------------
redirect() {
  if [ "$1" = "-d" ]; then
    cleanup_rules nat ipv4
    return 0
  fi

  log info "Setting up iptables for redirect mode"

  local iptables=$(get_iptables_cmd "nat" "ipv4")

  # 初始化链
  init_chains nat ipv4

  # 处理 sing-box 自身流量
  $iptables -I BOX_LOCAL -m owner --uid-owner "${BOX_USER}" --gid-owner "${BOX_GROUP}" -j RETURN

  # 处理应用过滤
  handle_packages nat BOX_LOCAL "exclude" ipv4
  handle_packages nat BOX_LOCAL "include" ipv4

  # 内网流量绕过
  bypass_intranet nat ipv4

  # DNS 处理
  setup_dns nat BOX_EXTERNAL ipv4
  setup_dns nat BOX_LOCAL ipv4

  # 处理特殊接口
  $iptables -A BOX_EXTERNAL -p tcp -i lo -j REDIRECT --to-ports "${redir_port}"

  for ap in "${ap_list[@]}"; do
    $iptables -A BOX_EXTERNAL -p tcp -i "${ap}" -j REDIRECT --to-ports "${redir_port}"
  done

  # 连接跟踪优化
  setup_conntrack_optimization nat ipv4

  # 配置链引用和默认规则
  $iptables -A BOX_EXTERNAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -p tcp -j REDIRECT --to-ports "${redir_port}"
  $iptables -A BOX_LOCAL -p udp -j REDIRECT --to-ports "${redir_port}"

  # 配置主链
  $iptables -I PREROUTING -j BOX_EXTERNAL
  $iptables -I OUTPUT -j BOX_LOCAL

  # 安全防护规则
  $iptables -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${BOX_USER}" --gid-owner "${BOX_GROUP}" -m tcp --dport "${redir_port}" -j REJECT

  log info "Redirect mode setup completed"
}

# -------------------- TPROXY 模式实现 --------------------
tproxy() {
  if [ "$1" = "-d" ]; then
    cleanup_rules mangle ipv4
    cleanup_policy_routing
    return 0
  fi

  log info "Setting up iptables for tproxy mode"

  local iptables=$(get_iptables_cmd "mangle" "ipv4")

  # 初始化链
  init_chains mangle ipv4

  # 配置策略路由
  log info "Setting up policy routing"
  # 先删除可能存在的旧规则
  ip rule del fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}" 2>/dev/null || true
  ip route del local default dev lo table "${ROUTE_TABLE}" 2>/dev/null || true
  # 添加新规则（使用 || true 防止重复添加时失败）
  ip rule add fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}" 2>/dev/null || true
  ip route add local default dev lo table "${ROUTE_TABLE}" 2>/dev/null || true

  # 处理 sing-box 自身流量
  $iptables -I BOX_LOCAL -m owner --uid-owner "${BOX_USER}" --gid-owner "${BOX_GROUP}" -j RETURN

  # 应用过滤
  handle_packages mangle BOX_LOCAL "exclude" ipv4
  handle_packages mangle BOX_LOCAL "include" ipv4

  # 内网流量绕过
  bypass_intranet mangle ipv4

  # DNS 处理
  setup_dns mangle BOX_EXTERNAL ipv4

  # 处理特殊接口
  for proto in tcp udp; do
    $iptables -A BOX_EXTERNAL -p "${proto}" -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${FWMARK}"
    for ap in "${ap_list[@]}"; do
      $iptables -A BOX_EXTERNAL -p "${proto}" -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${FWMARK}"
    done
  done

  # 连接跟踪优化
  setup_conntrack_optimization mangle ipv4

  # 配置链引用和默认规则
  $iptables -A BOX_EXTERNAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -p tcp -j MARK --set-mark "${FWMARK}"
  $iptables -A BOX_LOCAL -p udp -j MARK --set-mark "${FWMARK}"

  # 配置主链
  $iptables -I PREROUTING -j BOX_EXTERNAL
  $iptables -I OUTPUT -j BOX_LOCAL

  # 设置 IPv6 规则
  if [ "${ipv6}" = "true" ]; then
    setup_ipv6_rules
  fi

  log info "TPROXY mode setup completed"
}

# -------------------- IPv6 规则处理 --------------------
setup_ipv6_rules() {
  log info "Setting up IPv6 rules for tproxy mode"

  local ip6tables=$(get_iptables_cmd "mangle" "ipv6")

  # 初始化 IPv6 链
  init_chains mangle ipv6

  # 配置 IPv6 策略路由
  log info "Setting up IPv6 policy routing"
  ip -6 rule del fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}" 2>/dev/null || true
  ip -6 route del local default dev lo table "${ROUTE_TABLE}" 2>/dev/null || true
  ip -6 rule add fwmark "${FWMARK}" table "${ROUTE_TABLE}" pref "${ROUTE_PREF}"
  ip -6 route add local default dev lo table "${ROUTE_TABLE}"

  # 删除 IPv6 阻断规则
  ip -6 rule del unreachable pref "${ROUTE_PREF}" 2>/dev/null || true

  # 处理 sing-box 自身流量
  $ip6tables -I BOX_LOCAL -m owner --uid-owner "${BOX_USER}" --gid-owner "${BOX_GROUP}" -j RETURN

  # 应用过滤
  handle_packages mangle BOX_LOCAL "exclude" ipv6
  handle_packages mangle BOX_LOCAL "include" ipv6

  # 内网流量绕过
  bypass_intranet mangle ipv6

  # DNS 处理
  setup_dns mangle BOX_EXTERNAL ipv6

  # 处理特殊接口
  for proto in tcp udp; do
    $ip6tables -A BOX_EXTERNAL -p "${proto}" -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${FWMARK}"
    for ap in "${ap_list[@]}"; do
      $ip6tables -A BOX_EXTERNAL -p "${proto}" -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${FWMARK}"
    done
  done

  # 连接跟踪优化
  setup_conntrack_optimization mangle ipv6

  # 配置链引用和默认规则
  $ip6tables -A BOX_EXTERNAL -j BOX_IP_V6
  $ip6tables -A BOX_LOCAL -j BOX_IP_V6
  $ip6tables -A BOX_LOCAL -p tcp -j MARK --set-mark "${FWMARK}"
  $ip6tables -A BOX_LOCAL -p udp -j MARK --set-mark "${FWMARK}"

  # 配置主链
  $ip6tables -I PREROUTING -j BOX_EXTERNAL
  $ip6tables -I OUTPUT -j BOX_LOCAL

  # 添加 UDP DNS 阻断规则（强制使用 DoH/DoT）
  if ! $ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null; then
    $ip6tables -A OUTPUT -p udp --destination-port 53 -j DROP
  fi

  log info "IPv6 rules setup completed"
}

# -------------------- TUN 模式实现 --------------------
tun() {
  if [ -z "${tun_device}" ]; then
    log error "Variable tun_device not set"
    exit 1
  fi

  if [ "$1" = "-d" ]; then
    log info "Cleaning up tun mode rules"
    local iptables=$(get_iptables_cmd "filter" "ipv4")
    $iptables -D FORWARD -i "${tun_device}" -j ACCEPT 2>/dev/null || true
    $iptables -D FORWARD -o "${tun_device}" -j ACCEPT 2>/dev/null || true

    if [ "${ipv6}" = "true" ]; then
      local ip6tables=$(get_iptables_cmd "filter" "ipv6")
      $ip6tables -D FORWARD -i "${tun_device}" -j ACCEPT 2>/dev/null || true
      $ip6tables -D FORWARD -o "${tun_device}" -j ACCEPT 2>/dev/null || true
    fi
    return 0
  fi

  # 检查 TUN 设备是否存在
  if ! busybox ifconfig 2>/dev/null | grep -q "${tun_device}"; then
    log error "TUN device ${tun_device} not found"
    exit 1
  fi

  log info "Setting up iptables for tun mode"

  local iptables=$(get_iptables_cmd "filter" "ipv4")
  $iptables -I FORWARD -i "${tun_device}" -j ACCEPT
  $iptables -I FORWARD -o "${tun_device}" -j ACCEPT

  # IPv6 支持
  if [ "${ipv6}" = "true" ]; then
    local ip6tables=$(get_iptables_cmd "filter" "ipv6")
    $ip6tables -I FORWARD -i "${tun_device}" -j ACCEPT
    $ip6tables -I FORWARD -o "${tun_device}" -j ACCEPT
  fi

  # 系统参数优化
  sysctl -w net.ipv4.conf.default.rp_filter=2 &>/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=2 &>/dev/null

  log info "TUN mode setup completed"
}

# -------------------- 主程序入口 --------------------
main() {
  log info "Starting iptables configuration"

  # 初始化配置（静默模式，避免重复日志）
  init_config true || exit 1

  # 检查系统要求
  check_requirements "$1" || exit 1

  # 根据模式执行相应的配置
  case "$1" in
    redirect)
      redirect "$2"
      ;;
    tproxy)
      tproxy "$2"
      ;;
    tun)
      tun "$2"
      ;;
    clear)
      cleanup_all
      ;;
    *)
      log error "Invalid mode: $1"
      log info "Usage: $0 {redirect|tproxy|tun|clear} [-d]"
      exit 1
      ;;
  esac

  log info "Configuration completed successfully"
}

# 执行主程序
main "$@"

# 清理手机厂商的网络限制（后台执行）
(sleep 3 && cleanup_limit) &
