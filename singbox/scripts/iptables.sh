#!/system/bin/sh

source "${0%/*}/settings.sh"

redirect() {
  # 使用 iptables 并启用锁等待机制
  iptables="iptables -w 64"

  if [ "$1" == "-d" ]; then
    ${iptables} -t nat -D PREROUTING -j BOX_EXTERNAL 2>/dev/null
    ${iptables} -t nat -D OUTPUT -j BOX_LOCAL 2>/dev/null

    # 清空并删除自定义链
    ${iptables} -t nat -F BOX_EXTERNAL 2>/dev/null
    ${iptables} -t nat -X BOX_EXTERNAL 2>/dev/null
    ${iptables} -t nat -F BOX_LOCAL 2>/dev/null
    ${iptables} -t nat -X BOX_LOCAL 2>/dev/null
    ${iptables} -t nat -F LOCAL_IP_V4 2>/dev/null
    ${iptables} -t nat -X LOCAL_IP_V4 2>/dev/null

    # 清除 OUTPUT 相关的安全规则
    ${iptables} -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT 2>/dev/null
    return 0
  fi

  # 1. 创建和清空自定义链
  ${iptables} -t nat -N BOX_EXTERNAL 2>/dev/null
  ${iptables} -t nat -F BOX_EXTERNAL
  ${iptables} -t nat -N BOX_LOCAL 2>/dev/null
  ${iptables} -t nat -F BOX_LOCAL
  ${iptables} -t nat -N LOCAL_IP_V4 2>/dev/null
  ${iptables} -t nat -F LOCAL_IP_V4

  # 2. 配置绕过规则（应该最先匹配）
  # 用户和组绕过配置
  ${iptables} -t nat -I BOX_LOCAL -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -j RETURN

  # 3. 处理内网流量（优先级高的绕过规则）
  for subnet in ${intranet[@]} ; do
    ${iptables} -t nat -A BOX_EXTERNAL -d ${subnet} -j RETURN
    ${iptables} -t nat -A BOX_LOCAL -d ${subnet} -j RETURN
  done

  # 4. DNS 处理（重要的基础服务）
  if [ -n "${redir_port}" ]; then
    for proto in tcp udp; do
      ${iptables} -t nat -A BOX_EXTERNAL -p ${proto} --dport 53 -j REDIRECT --to-ports "${redir_port}"
      ${iptables} -t nat -A BOX_LOCAL -p ${proto} --dport 53 -j REDIRECT --to-ports "${redir_port}"
    done
  fi

  # 5. ICMP 处理
  if [ -n "${inet4_range}" ]; then
    ${iptables} -t nat -A BOX_EXTERNAL -d "${inet4_range}" -p icmp -j DNAT --to-destination 127.0.0.1
    ${iptables} -t nat -A BOX_LOCAL -d "${inet4_range}" -p icmp -j DNAT --to-destination 127.0.0.1
  fi

  # 6. 特定应用处理（应用专用规则）
  packages="$(pm list packages -U)"
  $jq -r '.inbounds[] | select(.type == "tun") | .include_package[] // empty' "$config_json" | while read -r package; do
    [ -z "$package" ] && continue
    uid="$(echo "${packages}" | grep -w "$package" | tr -dc '0-9')"
    [ -z "$uid" ] && continue
    log debug "Configuring iptables rules for package: ${package}, UID: ${uid}"
    ${iptables} -t nat -A BOX_LOCAL -p tcp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
    ${iptables} -t nat -A BOX_LOCAL -p udp -m owner --uid-owner ${uid} -j REDIRECT --to-ports "${redir_port}"
  done

  # 7. 接口处理
  # 处理本地回环接口流量
  ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i lo -j REDIRECT --to-ports "${redir_port}"
  # 处理 AP 接口流量
  for ap in "${ap_list[@]}"; do
    ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i "${ap}" -j REDIRECT --to-ports "${redir_port}"
  done
  # 添加对 tun 接口的支持
  ${iptables} -t nat -A BOX_EXTERNAL -p tcp -i tun+ -j REDIRECT --to-ports "${redir_port}"

  # 8. 链接引用（在所有特定规则之后）
  ${iptables} -t nat -A BOX_EXTERNAL -j LOCAL_IP_V4
  ${iptables} -t nat -A BOX_LOCAL -j LOCAL_IP_V4

  # 9. 通用流量处理（作为默认规则）
  ${iptables} -t nat -A BOX_LOCAL -p tcp -j REDIRECT --to-ports "${redir_port}"

  # 10. 主链配置（最后进行）
  ${iptables} -t nat -I PREROUTING -j BOX_EXTERNAL
  ${iptables} -t nat -I OUTPUT -j BOX_LOCAL

  # 11. 安全防护（最后添加）
  ${iptables} -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT
}

tproxy() {
  # 设置 iptables 命令，添加 -w 64 参数防止并发操作冲突
  iptables="iptables -w 64"

  if [ "$1" == "-d" ]; then
    # 从主链中移除自定义链的引用
    ${iptables} -t mangle -D PREROUTING -j BOX_EXTERNAL 2>/dev/null

    # 清空并删除自定义链
    ${iptables} -t mangle -F BOX_EXTERNAL 2>/dev/null
    ${iptables} -t mangle -X BOX_EXTERNAL 2>/dev/null
    ${iptables} -t mangle -F BOX_LOCAL 2>/dev/null
    ${iptables} -t mangle -X BOX_LOCAL 2>/dev/null
    ${iptables} -t mangle -F LOCAL_IP_V4 2>/dev/null
    ${iptables} -t mangle -X LOCAL_IP_V4 2>/dev/null

    # 清除路由规则
    ip rule del fwmark "${fwmark}" table "${table}" pref "${pref}" 2>/dev/null
    ip route del local default dev lo table "${table}" 2>/dev/null
    return 0
  fi

  # 配置策略路由：将带有特定 mark 的流量转发到指定路由表
  ip rule add fwmark "${fwmark}" table "${table}" pref "${pref}"
  # 在路由表中添加本地路由规则
  ip route add local default dev lo table "${table}"

  # === 处理外部流量（PREROUTING 链）===
  # 创建并清空 BOX_EXTERNAL 链
  ${iptables} -t mangle -N BOX_EXTERNAL 2>/dev/null
  ${iptables} -t mangle -F BOX_EXTERNAL

  # DNS 流量处理：将 TCP/UDP 53 端口的流量转发到 TPROXY
  ${iptables} -t mangle -A BOX_EXTERNAL -p tcp --dport 53 -j TPROXY --on-port ${tproxy_port} --tproxy-mark ${fwmark}
  ${iptables} -t mangle -A BOX_EXTERNAL -p udp --dport 53 -j TPROXY --on-port ${tproxy_port} --tproxy-mark ${fwmark}

  # 内网 IP 直连：遍历内网地址列表，添加直连规则
  for subnet in ${intranet[@]} ; do
    ${iptables} -t mangle -A BOX_EXTERNAL -d ${subnet} -j RETURN
  done

  # 创建并清空用于存放本地 IP 规则的链
  ${iptables} -t mangle -N LOCAL_IP_V4
  ${iptables} -t mangle -F LOCAL_IP_V4
  ${iptables} -t mangle -A BOX_EXTERNAL -j LOCAL_IP_V4

  # 处理回环接口流量
  ${iptables} -t mangle -A BOX_EXTERNAL -p tcp -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
  ${iptables} -t mangle -A BOX_EXTERNAL -p udp -i lo -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"

  # 处理指定网络接口的流量（通常是 AP 接口）
  for ap in ${ap_list[@]} ; do
    ${iptables} -t mangle -A BOX_EXTERNAL -p tcp -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
    ${iptables} -t mangle -A BOX_EXTERNAL -p udp -i "${ap}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
  done

  # 将 BOX_EXTERNAL 链插入到 PREROUTING 链的开头
  ${iptables} -t mangle -I PREROUTING -j BOX_EXTERNAL

  # === 处理本地产生的流量（OUTPUT 链）===
  # 创建并清空 BOX_LOCAL 链
  ${iptables} -t mangle -N BOX_LOCAL
  ${iptables} -t mangle -F BOX_LOCAL

  # 放行 sing-box 程序自身的流量，避免循环
  ${iptables} -t mangle -A BOX_LOCAL -m owner --uid-owner ${box_user} --gid-owner ${box_group} -j RETURN

  # 处理本地 DNS 查询请求
  ${iptables} -t mangle -A BOX_LOCAL -p tcp --dport 53 -j MARK --set-xmark ${fwmark}
  ${iptables} -t mangle -A BOX_LOCAL -p udp --dport 53 -j MARK --set-xmark ${fwmark}

  # 特殊应用处理
  packages="$(pm list packages -U)"
  $jq -r '.inbounds[] | select(.type == "tun") | .include_package[] // empty' "$config_json" | while read -r package; do
    [ -z "$package" ] && continue
    uid="$(echo "${packages}" | grep -w "$package" | tr -dc '0-9')"
    [ -z "$uid" ] && continue
    log debug "Configuring iptables rules for package: ${package}, UID: ${uid}"
    ${iptables} -t mangle -A BOX_LOCAL -p tcp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
    ${iptables} -t mangle -A BOX_LOCAL -p udp -m owner --uid-owner ${uid} -j MARK --set-xmark ${fwmark}
  done

  # 内网 IP 直连
  for subnet in ${intranet[@]} ; do
    ${iptables} -t mangle -A BOX_LOCAL -d ${subnet} -j RETURN
  done

  # 应用本地 IP 规则
  ${iptables} -t mangle -A BOX_LOCAL -j LOCAL_IP_V4

  # 给所有其他 TCP/UDP 流量打上标记
  ${iptables} -t mangle -A BOX_LOCAL -p tcp -j MARK --set-mark "${fwmark}"
  ${iptables} -t mangle -A BOX_LOCAL -p udp -j MARK --set-mark "${fwmark}"
}

mixed() {
  log info "use mixed"
}

tun() {
  log info "use tun"
}

# clear iptables rules
if [ "$1" == "clear" ]; then
  case "${network_mode}" in
    redirect) redirect -d;;
    tproxy) tproxy -d;;
    mixed) mixed -d;;
    tun) tun -d;;
    *) log error "network_mode: ${network_mode} not found"; exit 1;;
  esac
  if [ "${ipv6}" = "true" ]; then
    ip6tables -w 64 -D OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null
  fi
  log info "iptables rules cleared"
  exit 0
fi

# add iptables rules
case "$1" in
  redirect) redirect;;
  tproxy) tproxy;;
  mixed) mixed;;
  tun) tun;;
  *)
    echo "${red}$0 $1 no found${normal}"
    echo "${yellow}usage${normal}: ${green}$0${normal} {${yellow}redirect|tproxy|mixed|tun|clear${normal}}"
    ;;
esac
