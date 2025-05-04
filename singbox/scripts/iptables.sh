#!/system/bin/sh

# 设置错误处理
set -e
trap 'handle_error $? $LINENO' ERR

source "${0%/*}/settings.sh"

# 定义链
chains="BOX_EXTERNAL BOX_LOCAL BOX_IP_V4 BOX_IP_V6"

# 错误处理函数
handle_error() {
  local exit_code=$1
  local line_number=$2
  # 只在非正常退出时记录错误
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 2 ]; then
    log ERROR "Error occurred at line $line_number with exit code $exit_code"
  fi
  cleanup_all
  exit $exit_code
}

# 安全检查函数
check_requirements() {
  # 检查 root 权限
  if [ "$(id -u)" != "0" ]; then
    log ERROR "This script requires root privileges"
    exit 1
  fi

  # 检查 iptables 命令
  if ! command -v iptables >/dev/null 2>&1; then
    log ERROR "iptables command not found"
    exit 1
  fi

  # 检查必要的变量
  local required_vars="box_user box_group redir_port tproxy_port fwmark"
  for var in $required_vars; do
    eval "value=\$$var"
    if [ -z "$value" ]; then
      log ERROR "Required variable $var is not set"
      exit 1
    fi
  done
}

# 统一的清理函数
cleanup_all() {
  log INFO "Starting cleanup of all rules"
  cleanup_rules nat
  cleanup_rules mangle
  cleanup_ipv6_rules
  cleanup_limit
  log INFO "Cleanup completed"
}

# 清理规则函数
cleanup_rules() {
  local table="$1"
  local iptables=$(get_iptables_cmd "$table" "ipv4")

  log INFO "Cleaning iptable rules for ${table}"

  # 从主链中移除引用
  $iptables -D PREROUTING -j BOX_EXTERNAL 2>/dev/null
  $iptables -D OUTPUT -j BOX_LOCAL 2>/dev/null

  # 清理自定义链
  for chain in $chains; do
    $iptables -t ${table} -F ${chain} 2>/dev/null
    $iptables -t ${table} -X ${chain} 2>/dev/null
  done

  return 0
}

# 优化的 iptables 命令构建函数
get_iptables_cmd() {
  local table="$1"
  local family="$2"
  local timeout=64
  case "$family" in
    "ipv6") echo "ip6tables -w $timeout -t $table" ;;
    *) echo "iptables -w $timeout -t $table" ;;
  esac
}

# 优化的链初始化函数
init_chains() {
  local table="$1"
  local family="$2"
  local iptables=$(get_iptables_cmd "$table" "$family")

  # 先清理现有链
  for chain in $chains; do
    # 从主链中移除引用
    $iptables -D PREROUTING -j "$chain" 2>/dev/null
    $iptables -D OUTPUT -j "$chain" 2>/dev/null
    # 清理链中的规则
    $iptables -F "$chain" 2>/dev/null
    # 删除链
    $iptables -X "$chain" 2>/dev/null
  done

  # 创建新链
  for chain in $chains; do
    # 尝试创建新链
    if ! $iptables -N "$chain" 2>/dev/null; then
      # 如果链已存在，确保它是空的
      $iptables -F "$chain" 2>/dev/null
    fi
  done

  return 0
}

# 优化的包处理函数
handle_packages() {
  local table="$1"
  local chain="$2"
  local action="$3"
  local family="$4"
  local iptables=$(get_iptables_cmd "$table" "$family")
  local packages="$(pm list packages -U)"
  local custom_packages="$(cat ${box_dir}/${action}.list 2>/dev/null)"
  local config_packages="$($jq -r ".inbounds[] | select(.type == \"tun\") | .${action}_package[] // empty" "$config_json" 2>/dev/null)"

  # 使用数组存储包名，提高效率
  local package_list=$(echo -e "${config_packages}\n${custom_packages}" | grep -v '^#' | grep -v '^$')
  for package in $package_list; do
    local uid="$(echo "${packages}" | grep -w "$package" | tr -dc '0-9')"
    [ -z "$uid" ] && continue
    log INFO "${action} package: $package, uid: $uid"

    case ${table} in
      nat)
        if [ "$action" = "exclude" ]; then
          $iptables -A ${chain} -p tcp -m owner --uid-owner ${uid} -j RETURN
          $iptables -A ${chain} -p udp -m owner --uid-owner ${uid} -j RETURN
        else
          $iptables -A ${chain} -p tcp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
          $iptables -A ${chain} -p udp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
        fi
        ;;
      mangle)
        if [ "$action" = "exclude" ]; then
          $iptables -A ${chain} -p tcp -m owner --uid-owner ${uid} -j RETURN
          $iptables -A ${chain} -p udp -m owner --uid-owner ${uid} -j RETURN
        else
          $iptables -A ${chain} -p tcp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
          $iptables -A ${chain} -p udp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
        fi
        ;;
    esac
  done
}

# 优化的 DNS 处理函数
setup_dns() {
  local table="$1"
  local chain="$2"
  local family="$3"
  local iptables=$(get_iptables_cmd "$table" "$family")

  for proto in tcp udp; do
    case ${table} in
      nat)
        $iptables -A ${chain} -p ${proto} --dport 53 -j REDIRECT --to-ports "${redir_port}"
        ;;
      mangle)
        $iptables -A ${chain} -p ${proto} --dport 53 -j TPROXY --on-port ${tproxy_port} --tproxy-mark ${fwmark}
        ;;
    esac
  done
}

# REDIRECT 模式实现
redirect() {
  local iptables=$(get_iptables_cmd "nat" "ipv4")

  if [ "$1" = "-d" ]; then
    cleanup_rules nat
    # 清除安全规则
    $iptables -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT 2>/dev/null
    return 0
  fi

  log INFO "Setting up iptables for redirect mode"

  # 初始化自定义链
  init_chains nat ipv4

  # 处理 sing-box 流量
  $iptables -I BOX_LOCAL -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -j RETURN

  # 处理应用过滤
  handle_packages nat BOX_LOCAL "include" ipv4
  handle_packages nat BOX_LOCAL "exclude" ipv4

  # 内网流量处理
  for subnet in $intranet; do
    $iptables -A BOX_EXTERNAL -d ${subnet} -j RETURN
    $iptables -A BOX_LOCAL -d ${subnet} -j RETURN
  done

  # DNS 处理
  setup_dns nat BOX_EXTERNAL ipv4
  setup_dns nat BOX_LOCAL ipv4

  # 处理特殊接口
  $iptables -A BOX_EXTERNAL -p tcp -i lo -j REDIRECT --to-ports "${redir_port}"
  for ap in $ap_list; do
    $iptables -A BOX_EXTERNAL -p tcp -i "${ap}" -j REDIRECT --to-ports "${redir_port}"
  done
  $iptables -A BOX_EXTERNAL -p tcp -i tun+ -j REDIRECT --to-ports "${redir_port}"

  # 配置链引用和默认规则
  $iptables -A BOX_EXTERNAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -p tcp -j REDIRECT --to-ports "${redir_port}"
  $iptables -A BOX_LOCAL -p udp -j REDIRECT --to-ports "${redir_port}"

  # 配置主链
  $iptables -I PREROUTING -j BOX_EXTERNAL
  $iptables -I OUTPUT -j BOX_LOCAL

  # 安全防护规则
  $iptables -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT

  # 性能优化：添加连接跟踪规则
  $iptables -A BOX_EXTERNAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  $iptables -A BOX_LOCAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

  # 优化：添加端口范围规则
  $iptables -A BOX_EXTERNAL -p tcp --dport 1:1024 -j REDIRECT --to-ports "${redir_port}"
  $iptables -A BOX_EXTERNAL -p udp --dport 1:1024 -j REDIRECT --to-ports "${redir_port}"
}

# TPROXY 模式实现
tproxy() {
  local iptables=$(get_iptables_cmd "mangle" "ipv4")

  if [ "$1" = "-d" ]; then
    cleanup_rules mangle
    # 清除路由规则
    ip rule del fwmark "${fwmark}" table "${table}" pref "${pref}" 2>/dev/null
    ip route del local default dev lo table "${table}" 2>/dev/null
    return 0
  fi

  log INFO "Setting up iptables for tproxy mode"

  # 初始化自定义链
  init_chains mangle ipv4

  # 配置策略路由
  ip rule del fwmark "${fwmark}" table "${table}" pref "${pref}" 2>/dev/null
  ip route del local default dev lo table "${table}" 2>/dev/null
  ip rule add fwmark "${fwmark}" table "${table}" pref "${pref}"
  ip route add local default dev lo table "${table}"

  # 处理 sing-box 流量
  $iptables -I BOX_LOCAL -m owner --uid-owner ${box_user} --gid-owner ${box_group} -j RETURN

  # 应用过滤
  handle_packages mangle BOX_LOCAL "include" ipv4
  handle_packages mangle BOX_LOCAL "exclude" ipv4

  # 内网流量处理
  for subnet in $intranet; do
    $iptables -A BOX_EXTERNAL -d ${subnet} -j RETURN
    $iptables -A BOX_LOCAL -d ${subnet} -j RETURN
  done

  # DNS 处理
  setup_dns mangle BOX_EXTERNAL ipv4

  # 处理特殊接口
  for proto in tcp udp; do
    $iptables -A BOX_EXTERNAL -p ${proto} -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
    for ap in $ap_list; do
      $iptables -A BOX_EXTERNAL -p ${proto} -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
    done
  done

  # 配置链引用和默认规则
  $iptables -A BOX_EXTERNAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -j BOX_IP_V4
  $iptables -A BOX_LOCAL -p tcp -j MARK --set-mark "${fwmark}"
  $iptables -A BOX_LOCAL -p udp -j MARK --set-mark "${fwmark}"

  # 配置主链
  $iptables -I PREROUTING -j BOX_EXTERNAL
  $iptables -I OUTPUT -j BOX_LOCAL

  # 性能优化：添加连接跟踪规则
  $iptables -A BOX_EXTERNAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  $iptables -A BOX_LOCAL -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

  # 优化：添加端口范围规则
  $iptables -A BOX_EXTERNAL -p tcp --dport 1:1024 -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
  $iptables -A BOX_EXTERNAL -p udp --dport 1:1024 -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"

  # 优化：添加 TCP 状态规则
  $iptables -A BOX_EXTERNAL -p tcp -m tcp --tcp-flags SYN,RST,ACK SYN -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
}

# IPv6 规则处理
setup_ipv6_rules() {
  if [ "${ipv6}" != "true" ]; then
    return 0
  fi

  local iptables=$(get_iptables_cmd "mangle" "ipv6")
  
  # 初始化 IPv6 链
  init_chains mangle ipv6

  # 处理 IPv6 流量
  $iptables -A BOX_EXTERNAL -j BOX_IP_V6
  $iptables -A BOX_LOCAL -j BOX_IP_V6

  # 配置主链
  $iptables -I PREROUTING -j BOX_EXTERNAL
  $iptables -I OUTPUT -j BOX_LOCAL
}

# 清理 IPv6 规则
cleanup_ipv6_rules() {
  local iptables=$(get_iptables_cmd "mangle" "ipv6")
  
  for chain in $chains; do
    $iptables -F "$chain" 2>/dev/null
    $iptables -X "$chain" 2>/dev/null
  done
}

# 优化的 TUN 模式实现
tun() {
  local iptables=$(get_iptables_cmd "filter" "ipv4")

  if [ -z "${tun_device}" ]; then
    log ERROR "Variable tun_device not set"
    exit 1
  fi

  if [ "$1" = "-d" ]; then
    log INFO "Cleaning up tun mode rules"
    $iptables -D FORWARD -i "${tun_device}" -j ACCEPT
    $iptables -D FORWARD -o "${tun_device}" -j ACCEPT
    return 0
  fi

  # 检查 TUN 设备是否存在
  if ! busybox ifconfig | grep -q "${tun_device}" 2>/dev/null; then
    log ERROR "TUN device ${tun_device} not found"
    exit 1
  fi

  log INFO "Setting up iptables for tun mode"
  $iptables -I FORWARD -i "${tun_device}" -j ACCEPT
  $iptables -I FORWARD -o "${tun_device}" -j ACCEPT

  # 系统参数优化
  sysctl -w net.ipv4.conf.default.rp_filter=2 &>/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=2 &>/dev/null

  # 性能优化：添加连接跟踪规则
  $iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # 优化：添加 TCP 状态规则
  $iptables -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST,ACK SYN -j ACCEPT

  # 优化：添加 ICMP 规则
  $iptables -A FORWARD -p icmp -j ACCEPT

  # 优化：添加 MTU 规则
  $iptables -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST,ACK SYN -m tcpmss --mss 1400:65535 -j TCPMSS --set-mss 1400
}

# 主程序入口
main() {
  log INFO "Starting iptables configuration"
  check_requirements
  
  # 根据模式执行相应的配置
  case "$1" in
    "redirect") redirect "$2" ;;
    "tproxy") tproxy "$2" ;;
    "tun") tun "$2" ;;
    "clear")
      redirect -d
      tproxy -d
      tun -d
      cleanup_ipv6_rules
      ;;
    *) log ERROR "Invalid mode: $1" && exit 1 ;;
  esac

  log INFO "Configuration completed successfully"
}

# 执行主程序
main "$@"

# 清理手机产商的网络限制
(sleep 3 && cleanup_limit) &
