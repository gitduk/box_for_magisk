#!/system/bin/sh

source "${0%/*}/settings.sh"

# 统一的清理函数
cleanup_rules() {
  local table="$1"
  local chains="BOX_EXTERNAL BOX_LOCAL LOCAL_IP_V4"
  local iptables="iptables -w 64"

  log info "Cleaning iptable rules for ${table}"

  # 从主链中移除引用
  ${iptables} -t ${table} -D PREROUTING -j BOX_EXTERNAL 2>/dev/null
  ${iptables} -t ${table} -D OUTPUT -j BOX_LOCAL 2>/dev/null

  # 清理自定义链
  for chain in "${chains[@]}"; do
    ${iptables} -t ${table} -F ${chain} 2>/dev/null
    ${iptables} -t ${table} -X ${chain} 2>/dev/null
  done
}

# 处理内网地址
setup_intranet_rules() {
  local table="$1"
  local chain="$2"
  local iptables="iptables -w 64"

  for subnet in ${intranet[@]}; do
    ${iptables} -t ${table} -A ${chain} -d ${subnet} -j RETURN
  done
}

# 统一的包过滤函数
handle_packages() {
  local table="$1"
  local chain="$2"
  local action="$3"
  local iptables="iptables -w 64"
  local packages="$(pm list packages -U)"

  $jq -r ".inbounds[] | select(.type == \"tun\") | .${action}_package[] // empty" "$config_json" | while read -r package; do
    [ -z "$package" ] && continue
    uid="$(echo "${packages}" | grep -w "$package" | tr -dc '0-9')"
    [ -z "$uid" ] && continue
    log info "${action} package: $package, uid: $uid"

    case ${table} in
      nat)
        ${iptables} -t nat -A ${chain} -p tcp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
        ${iptables} -t nat -A ${chain} -p udp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
        ;;
      mangle)
        ${iptables} -t mangle -A ${chain} -p tcp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
        ${iptables} -t mangle -A ${chain} -p udp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
        ;;
    esac
  done
}

# REDIRECT 模式实现
redirect() {
  local iptables="iptables -w 64"

  if [ "$1" == "-d" ]; then
    cleanup_rules nat
    # 清除安全规则
    ${iptables} -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT 2>/dev/null
    return 0
  fi

  log info "Setting up iptables for redirect mode"

  # 创建自定义链
  for chain in BOX_EXTERNAL BOX_LOCAL LOCAL_IP_V4; do
    ${iptables} -t nat -N ${chain} 2>/dev/null
    ${iptables} -t nat -F ${chain}
  done

  # 设置基础绕过规则
  ${iptables} -t nat -I BOX_LOCAL -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -j RETURN

  # 处理应用过滤
  handle_packages nat BOX_LOCAL "exclude"
  handle_packages nat BOX_LOCAL "include"

  # 内网流量处理
  setup_intranet_rules nat BOX_EXTERNAL
  setup_intranet_rules nat BOX_LOCAL

  # DNS 处理
  for proto in tcp udp; do
    ${iptables} -t nat -A BOX_EXTERNAL -p ${proto} --dport 53 -j REDIRECT --to-ports "${redir_port}"
    ${iptables} -t nat -A BOX_LOCAL -p ${proto} --dport 53 -j REDIRECT --to-ports "${redir_port}"
  done

  # 处理特殊接口
  ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i lo -j REDIRECT --to-ports "${redir_port}"
  for ap in "${ap_list[@]}"; do
    ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i "${ap}" -j REDIRECT --to-ports "${redir_port}"
  done
  ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i tun+ -j REDIRECT --to-ports "${redir_port}"

  # 配置链引用和默认规则
  ${iptables} -t nat -A BOX_EXTERNAL -j LOCAL_IP_V4
  ${iptables} -t nat -A BOX_LOCAL -j LOCAL_IP_V4
  ${iptables} -t nat -A BOX_LOCAL -p tcp -j REDIRECT --to-ports "${redir_port}"
  ${iptables} -t nat -A BOX_LOCAL -p udp -j REDIRECT --to-ports "${redir_port}"

  # 配置主链
  ${iptables} -t nat -I PREROUTING -j BOX_EXTERNAL
  ${iptables} -t nat -I OUTPUT -j BOX_LOCAL

  # 安全防护规则
  ${iptables} -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT
}

# TPROXY 模式实现
tproxy() {
  local iptables="iptables -w 64"

  if [ "$1" == "-d" ]; then
    cleanup_rules mangle
    # 清除路由规则
    ip rule del fwmark "${fwmark}" table "${table}" pref "${pref}" 2>/dev/null
    ip route del local default dev lo table "${table}" 2>/dev/null
    return 0
  fi

  log info "Setting up iptables for tproxy mode"

  # 配置策略路由
  ip rule add fwmark "${fwmark}" table "${table}" pref "${pref}"
  ip route add local default dev lo table "${table}"

  # 创建自定义链
  for chain in BOX_EXTERNAL BOX_LOCAL LOCAL_IP_V4; do
    ${iptables} -t mangle -N ${chain} 2>/dev/null
    ${iptables} -t mangle -F ${chain}
  done

  # DNS 处理
  for proto in tcp udp; do
    ${iptables} -t mangle -A BOX_EXTERNAL -p ${proto} --dport 53 -j TPROXY --on-port ${tproxy_port} --tproxy-mark ${fwmark}
  done

  # 内网流量处理
  setup_intranet_rules mangle BOX_EXTERNAL
  setup_intranet_rules mangle BOX_LOCAL

  # 处理本地流量
  ${iptables} -t mangle -A BOX_LOCAL -m owner --uid-owner ${box_user} --gid-owner ${box_group} -j RETURN

  # 应用过滤
  handle_packages mangle BOX_LOCAL "exclude"
  handle_packages mangle BOX_LOCAL "include"

  # 处理特殊接口
  for proto in tcp udp; do
    ${iptables} -t mangle -A BOX_EXTERNAL -p ${proto} -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
    for ap in ${ap_list[@]}; do
      ${iptables} -t mangle -A BOX_EXTERNAL -p ${proto} -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
    done
  done

  # 配置链引用和默认规则
  ${iptables} -t mangle -A BOX_EXTERNAL -j LOCAL_IP_V4
  ${iptables} -t mangle -A BOX_LOCAL -j LOCAL_IP_V4
  ${iptables} -t mangle -A BOX_LOCAL -p tcp -j MARK --set-mark "${fwmark}"
  ${iptables} -t mangle -A BOX_LOCAL -p udp -j MARK --set-mark "${fwmark}"

  # 配置主链
  ${iptables} -t mangle -I PREROUTING -j BOX_EXTERNAL
  ${iptables} -t mangle -I OUTPUT -j BOX_LOCAL
}

# TUN 模式实现
tun() {
  local iptables="iptables -w 64"

  if [[ -z "${tun_device}" ]]; then
    log ERROR "Variable tun_device not set"
    exit 1
  fi

  if [[ "$1" == "-d" ]]; then
    log info "Cleaning up tun mode rules"
    ${iptables} -D FORWARD -i "${tun_device}" -j ACCEPT
    ${iptables} -D FORWARD -o "${tun_device}" -j ACCEPT
    return 0
  fi

  # 检查 TUN 设备是否存在
  if ! busybox ifconfig | grep -q "${tun_device}" 2>/dev/null; then
    log ERROR "TUN device ${tun_device} not found"
    exit 1
  fi

  log info "Setting up iptables for tun mode"
  ${iptables} -I FORWARD -i "${tun_device}" -j ACCEPT
  ${iptables} -I FORWARD -o "${tun_device}" -j ACCEPT

  # 系统参数优化
  sysctl -w net.ipv4.conf.default.rp_filter=2 &>/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=2 &>/dev/null
}

# 主程序入口
case "$1" in
  redirect) redirect ;;
  tproxy) tproxy ;;
  tun) tun ;;
  clear)
    redirect -d
    tproxy -d
    tun -d
    ;;
  *)
    echo "Usage: $0 {redirect|tproxy|tun|clear}"
    exit 1
    ;;
esac
