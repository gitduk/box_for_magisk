#!/system/bin/sh

source "${0%/*}/settings.sh"

box_is_alive() {
  local PID=$(<"${box_pid}" 2>/dev/null)
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "$(<"${run_log}")"
    log error "${bin_name} service is not running."
    log error "please check ${run_log} for more information."
    log error "killing stale pid $PID"
    killall -15 "sing-box" >/dev/null 2>&1 || busybox pkill -15 "sing-box" >/dev/null 2>&1
    [ -f "${box_pid}" ] && rm -f "${box_pid}"
    exit 1
  else
    return 0
  fi
}

# Function to display the usage of a binary
# This script retrieves information about a running binary process and logs it to a log file.
box_status() {
  # Get the process ID of the binary
  local PID=$(busybox pidof ${bin_name})

  if [ -z "$PID" ]; then
    log Error "${bin_name} is not running."
    return 1
  fi

  stack=$(if [ "${bin_name}" != "clash" ]; then find "${box_dir}" -type f -name "*.json" -exec busybox awk -F'"' '/"stack"/{print $4}' {} +; else busybox awk '!/^ *#/ && /stack: / { print $2;found=1; exit}' "${clash_config}"; fi)
  TOAST=1 log info "${bin_name} service is running."

  log info "proxy: ${proxy_mode} + network: ${network_mode} $(if [[ "${network_mode}" == @(mixed|tun) ]]; then echo "+ stack: ${stack}"; fi)"

  # Get the memory usage of the binary
  rss=$(grep VmRSS /proc/$PID/status | busybox awk '{ print $2 }')
  [ "${rss}" -ge 1024 ] && bin_rss="$(expr ${rss} / 1024) MB" || bin_rss="${rss} KB"
  swap=$(grep VmSwap /proc/$PID/status | busybox awk '{ print $2 }')
  [ "${swap}" -ge 1024 ] && bin_swap="$(expr ${swap} / 1024) MB" || bin_swap="${swap} KB"

  # Get the state of the binary
  state=$(grep State /proc/$PID/status | busybox awk '{ print $2" "$3 }')

  # Get the user and group of the binary
  user_group=$(stat -c %U:%G /proc/$PID)

  # Log the information
  log info "${bin_name} has started with the '${user_group}' user group."
  log info "${bin_name} status: ${state} (PID: $PID)"
  log info "${bin_name} memory usage: ${bin_rss}, swap: ${bin_swap}"

  # Get the CPU usage of the binary
  cpu=$(ps -p $PID -o %cpu | busybox awk 'NR==2{print $1}' 2> /dev/null)

  cpus_allowed=$(grep Cpus_allowed_list /proc/$PID/status | busybox awk '{ print $2" "$3 }')
  cpuset=$(ps -p $PID -o cpu | busybox awk 'NR==2{print $1}' 2> /dev/null)

  if [ -n "${cpu}" ]; then
    log info "${bin_name} CPU usage: ${cpu}%"
  else
    log info "${bin_name} CPU usage: not available"
  fi
  if [ -n "${cpuset}" ]; then
    log info "${bin_name} list of allowed CPUs : ${cpus_allowed}"
    log info "${bin_name} Which CPU running on : ${cpuset}"
  else
    log info "${bin_name} Which CPU running on : not available"
  fi

  # Check battery temperature
  temperature_celsius=$(($(cat /sys/class/power_supply/battery/temp) / 10))
  log info "battery temperature: ${temperature_celsius}°C"

  # Get the running time of the binary
  running_time=$(busybox ps -o comm,etime | grep ${bin_name} | busybox awk '{print $2}')
  if [ -n "${running_time}" ]; then
    log info "${bin_name} running time: ${running_time}"
  else
    log info "${bin_name} running time: not available."
  fi

  # Save the process ID to the pid file
  if [ -n "$PID" ]; then
    log INFO "🥰 $bin_name service is running!!!"
    echo -n "$PID" > "${box_pid}"
  fi
}

start_box() {
  # Clear the log file and add the timestamp and delimiter
  # cd /data/adb/box/bin; chmod 755 *
  log INFO "🤪 Module is working! but no service is running"
  box_version=$(busybox awk '!/^ *#/ && /version=/ { print $0 }' "$PROPFILE" 2>/dev/null)

  timezone=$(getprop persist.sys.timezone)
  sim_operator=$(getprop gsm.sim.operator.alpha)
  sim_type=$(getprop gsm.network.type)
  date=$(date)
  cpu_abi=$(getprop ro.product.cpu.abi)

  if [ -t 1 ]; then
    echo -e "${yellow}${timezone}${normal}"
    echo -e "${yellow}${sim_operator} / ${sim_type}${normal}"
    echo -e "${yellow}${date}${normal}"
    echo -e "${yellow}${box_version}${normal}"
    echo -e "${yellow}${cpu_abi}${normal}"
    echo -e "${white}━━━━━━━━━━━━━━━━━━${normal}"
  else
    {
      echo "${timezone}"
      echo "${sim_operator} / ${sim_type}"
      echo "${date}"
      echo "${box_version}"
      echo "${cpu_abi}"
      echo "━━━━━━━━━━━━━━━━━━"
    } | tee -a "${run_log}" > /dev/null 2>&1
  fi

  # Update iptables if bin_name is still running
  if [ -z "$PID" ]; then
    PID="$(busybox pidof "${bin_name}")"
  fi

  # sing-box is still running, renew iptables
  if [ -n "$PID" ]; then
    pid_name="${box_dir}/pid_name.txt"
    ps -p $PID -o comm= > "${pid_name}"
    sed -i '/^[[:space:]]*$/d' "${pid_name}"
    log debug "$(<"${pid_name}")(PID: $PID) service is still running, auto restart BOX."
    rm -f "${pid_name}"
    stop_box
    exit 1
  fi

  # Check permissions
  if [ ! -x "${bin_path}" ]; then
    log error "${bin_path} is not executable."
    exit 1
  fi

  # create tun
  if [[ "${network_mode}" == @(mixed|tun) ]]; then
    mkdir -p /dev/net
    [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun
    if [ ! -c "/dev/net/tun" ]; then
      log error "Cannot create /dev/net/tun. Possible reasons:"
      log warn "Your system does not support the TUN/TAP driver."
      log warn "Your system kernel version is not compatible with the TUN/TAP driver."
      log info "change network_mode to tproxy"
      sed -i 's/network_mode=.*/network_mode="tproxy"/g' "${settings}"
      exit 1
    fi
  fi

  # run sing-box
  log info "start ${bin_name} service."
  ulimit -SHn 1000000
  # Use ulimit to limit the memory usage of a process to 200MB
  # ulimit -v 200000  # Set the virtual memory limit in KB
  if ${bin_path} check -D "${box_dir}/" -C "${box_dir}" > "${box_log}" 2>&1; then
    nohup busybox setuidgid "${box_user_group}" "${bin_path}" run -D "${box_dir}" -C "${box_dir}" >> "${box_log}" 2>&1 &
    PID=$!
    echo -n $PID > "${box_pid}"
    sleep 1
  else
    log error "$(<"${run_log}")"
    log ERROR "configuration failed. Please check the ${run_log} file."
    exit 1
  fi

  count=0
  while [ $count -le 10 ]; do
    sleep 0.17
    box_is_alive || break
    count=$((count + 1))
  done
  box_status

  true
}

stop_box() {
  # Kill each binary using a loop
  # Check if the binary is running using pgrep
  if busybox pgrep "${bin_name}" >/dev/null; then
    # Use `busybox pkill` to kill the binary with signal 15, otherwise use `killall`.
    if busybox pkill -15 "${bin_name}" >/dev/null 2>&1; then
      : # Do nothing if busybox pkill is successful
    else
      killall -15 "${bin_name}" >/dev/null 2>&1 || kill -15 "$(busybox pidof "${bin_name}")" >/dev/null 2>&1
    fi
  fi

  # Check if the binary has stopped
  sleep 0.5
  if ! busybox pidof "${bin_name}" >/dev/null 2>&1; then
    # Delete the `box.pid` file if it exists
    if [ -f "${box_pid}" ]; then
      rm -f "${box_pid}"
    fi
    log warn "${bin_name} shutting down, service is stopped."
    TOAST=1 log warn "${bin_name} disconnected."

    [ -t 1 ] && echo -e "${white}━━━━━━━━━━━━━━━━━━${normal}"
  else
    log warn "${bin_name} Not stopped; may still be shutting down or failed to shut down."
    force_stop
  fi

  log INFO "😭 $bin_name shutting down, service is stopped !!!"
}

force_stop() {
  # try forcing it to shut down.
  log warn "try forcing it to shut down."
  # Use `busybox pkill` to kill the binary with signal 9, otherwise use `killall`.
  if busybox pkill -9 "${bin_name}"; then
    : # Do nothing if busybox pkill is successful
  else
    if command -v killall >/dev/null 2>&1; then
      killall -9 "${bin_name}" >/dev/null 2>&1 || true
    else
      pkill -9 "${bin_name}" >/dev/null 2>&1 || true
    fi
  fi
  sleep 0.5
  if ! busybox pidof "${bin_name}" >/dev/null 2>&1; then
    log warn "done, YOU can sleep peacefully."
    rm -f "${box_pid}"
  fi
}

# Check whether busybox is installed or not on the system using command -v
if ! command -v busybox &> /dev/null; then
  log error "$(which busybox) command not found."
  exit 1
fi


# setup iptables
setup_iptables() {
    log debug "fake-ip-range: ${inet4_range}, ${inet6_range}"
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

    # 1. 先从主链中删除引用
    ${iptables} -t nat -D PREROUTING -j BOX_EXTERNAL 2>/dev/null
    ${iptables} -t nat -D OUTPUT -j BOX_LOCAL 2>/dev/null

    # 2. 删除 OUTPUT 链中的 REJECT 规则
    ${iptables} -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${box_user}" --gid-owner "${box_group}" -m tcp --dport "${redir_port}" -j REJECT 2>/dev/null

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

case "$1" in
  start)
    stop_box
    start_box
    setup_iptables
    # settings put global http_proxy 127.0.0.1:7890
    ;;
  stop)
    stop_box
    clear_iptables
    # settings delete global http_proxy 127.0.0.1:7890
    ;;
  restart)
    stop_box
    sleep 0.5
    start_box
    ;;
  status)
    # Check whether the service is running or not
    if busybox pidof "${bin_name}" >/dev/null; then
      echo "${yellow}$("${bin_path}" version)${normal}"
      box_bin_status
    else
      log warn "${bin_name} shutting down, service is stopped."
    fi
    ;;
  *)
    echo "${red}$0 $1 no found${normal}"
    echo "${yellow}usage${normal}: ${green}$0${normal} {${yellow}start|stop|restart|status${normal}}"
    ;;
esac
