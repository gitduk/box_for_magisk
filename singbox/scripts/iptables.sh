#!/system/bin/sh

source "${0%/*}/settings.sh"

redirect() {
  # 使用 iptables 并启用锁等待机制
  iptables="iptables -w 64"

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

clear_iptables() {
  iptables="iptables -w 64"
  ip6tables="ip6tables -w 64"

  # 1. 先从主链中删除引用
  ${iptables} -t nat -D PREROUTING -j BOX_EXTERNAL 2>/dev/null
  ${iptables} -t nat -D OUTPUT -j BOX_LOCAL 2>/dev/null

  # 2. 删除 OUTPUT 链中的规则
  ${iptables} -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT 2>/dev/null
  if [ "${ipv6}" = "true" ]; then
    ${ip6tables} -D OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null
  fi

  # 3. 清空并删除自定义链
  # 清空链
  ${iptables} -t nat -F BOX_EXTERNAL 2>/dev/null
  ${iptables} -t nat -F BOX_LOCAL 2>/dev/null
  ${iptables} -t nat -F LOCAL_IP_V4 2>/dev/null

  # 删除链
  ${iptables} -t nat -X BOX_EXTERNAL 2>/dev/null
  ${iptables} -t nat -X BOX_LOCAL 2>/dev/null
  ${iptables} -t nat -X LOCAL_IP_V4 2>/dev/null

  log info "iptables rules cleared"
}

tproxy() {
  log info "use tproxy"
}

mixed() {
  log info "use mixed"
}

tun() {
  log info "use tun"
}

case "$1" in
  redirect) redirect;;
  tproxy) tproxy;;
  mixed) mixed;;
  tun) tun;;
  clear) clear_iptables ;;
  *)
    echo "${red}$0 $1 no found${normal}"
    echo "${yellow}usage${normal}: ${green}$0${normal} {${yellow}redirect|tproxy|mixed|tun|clear${normal}}"
    ;;
esac
