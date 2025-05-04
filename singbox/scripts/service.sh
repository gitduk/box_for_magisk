#!/system/bin/sh

source "${0%/*}/settings.sh"

# 创建必要的目录
mkdir -p "${box_dir}/logs"
chmod 755 "${box_dir}/logs"

# 检查必要的系统条件
check_system_requirements() {
  # 检查 sing-box 命令
  if [ ! -f "$bin_path" ]; then
    log ERROR "Cannot find ${bin_path}"
    return 1
  fi

  # 检查 network_mode 变量
  if [ -z "${network_mode}" ]; then
    log ERROR "network_mode is not set"
    return 1
  fi

  # 检查并创建 TUN 设备
  if [ -n "${tun_device}" ]; then
    log info "Creating TUN device: ${tun_device}"
    mkdir -p /dev/net
    [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun

    if [ ! -c "/dev/net/tun" ]; then
      log error "Cannot create /dev/net/tun"
      log warn "System may not support TUN/TAP driver or kernel incompatibility"
      log info "Falling back to TPROXY mode"
      sed -i 's/network_mode=.*/network_mode="tproxy"/g' "${settings}"
      return 1
    fi
  fi

  # 检查 busybox 版本
  busybox_code=$(busybox | busybox grep -oE '[0-9.]*' | head -n 1)
  if [ "$(echo "${busybox_code}" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" -lt "$(echo "1.36.1" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" ]; then
    log info "Current $(which busybox) v${busybox_code}"
    log warn "Please update your busybox to v1.36.1+"
  fi

  return 0
}

# 检查进程运行状态
check_process_running() {
  local process_name="$1"
  local retries=0
  local max_retries=10
  local sleep_interval=0.5

  while [ $retries -lt $max_retries ]; do
    sleep $sleep_interval
    if PID=$(busybox pidof "$process_name"); then
      return 0
    fi
    retries=$((retries + 1))
  done
  return 1
}

# 设置IPv6环境
setup_ipv6() {
  # 基础网络设置
  sysctl -w net.ipv4.ip_forward=1 &>/dev/null

  if [ "${ipv6}" == "true" ]; then
    log info "IPv6: enabled"

    # 启用IPv6设置
    sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=0 &>/dev/null

    # 删除IPv6阻断规则
    ip -6 rule del unreachable pref "${pref}" &>/dev/null

    # 添加UDP DNS阻断规则
    if ! ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null; then
      ip6tables -w 64 -A OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null
    fi
  else
    log info "IPv6: disabled"
    # 禁用IPv6设置
    sysctl -w net.ipv6.conf.all.forwarding=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=1 &>/dev/null

    # 添加IPv6阻断规则
    ip -6 rule add unreachable pref "${pref}" &>/dev/null

    # 删除UDP DNS阻断规则
    if ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null; then
      ip6tables -w 64 -D OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null
    fi
  fi
}

# 启动服务
start_box() {
  # 清理日志文件
  : > "${run_log}"
  : > "${box_log}"

  # 设置权限
  chown -R ${box_user_group} ${box_dir}
  chown ${box_user_group} ${bin_path}
  chmod 6755 ${bin_path}

  # 检查执行权限
  if [ ! -x "${bin_path}" ]; then
    log ERROR "${bin_path} is not executable"
    return 1
  fi

  # 打印配置信息
  [ -n "${tun_device}" ] && log info "tun device: ${tun_device}"
  [ -n "${stack}" ] && log info "stack: ${stack}"
  [ -n "${tproxy_port}" ] && log info "tproxy_port: ${tproxy_port}"
  [ -n "${redir_port}" ] && log info "redir_port: ${redir_port}"
  [ -n "${network_mode}" ] && log info "network_mode: ${network_mode}"
  [ -n "${inet4_range}" ] && log info "inet4_range: ${inet4_range}"
  [ -n "${inet6_range}" ] && log info "inet6_range: ${inet6_range}"

  # 设置系统限制
  ulimit -SHn 1000000

  # 启动服务
  log info "Starting ${bin_name} service"
  if ${bin_path} check -D "${box_dir}/" -C "${box_dir}" > "${box_log}" 2>&1; then
    nohup busybox setuidgid "${box_user_group}" "${bin_path}" run -D "${box_dir}" -C "${box_dir}" >> "${box_log}" 2>&1 &
    sleep 1
  else
    log ERROR "$(<"${box_log}")"
    return 1
  fi

  # 检查进程状态
  if check_process_running "${bin_name}"; then
    PID=$(busybox pidof "${bin_name}")
  else
    log ERROR "$(<"${box_log}")"
    killall -15 "${bin_name}" >/dev/null 2>&1 || busybox pkill -15 "${bin_name}" >/dev/null 2>&1
    return 1
  fi

  # 设置 iptables 规则
  ${scripts_dir}/iptables.sh "${network_mode}"

  # IPv6 配置
  setup_ipv6

  log INFO "${bin_name} started"

  return 0
}

# 停止服务
stop_box() {
  local force_kill=${1:-false}

  # 温和停止
  if busybox pgrep "${bin_name}" >/dev/null; then
    if ! busybox pkill -15 "${bin_name}" >/dev/null 2>&1; then
      killall -15 "${bin_name}" >/dev/null 2>&1 || kill -15 "$(busybox pidof "${bin_name}")" >/dev/null 2>&1
    fi
  fi

  # 检查是否需要强制停止
  sleep 0.5
  if busybox pidof "${bin_name}" >/dev/null 2>&1; then
    if [ "$force_kill" = true ] || [ "$1" = "-f" ]; then
      force_stop
    else
      log WARN "${bin_name} is still running, may be shutting down or failed to stop"
      return 1
    fi
  fi

  # 清理 iptables 规则
  ${scripts_dir}/iptables.sh "clear"

  log INFO "${bin_name} stopped"

  return 0
}

# 强制停止服务
force_stop() {
  log warn "Forcing service shutdown"

  if ! busybox pkill -9 "${bin_name}"; then
    if command -v killall >/dev/null 2>&1; then
      killall -9 "${bin_name}" >/dev/null 2>&1
    else
      pkill -9 "${bin_name}" >/dev/null 2>&1
    fi
  fi

  sleep 0.5
  if ! busybox pidof "${bin_name}" >/dev/null 2>&1; then
    log INFO "Service forcefully stopped"
    return 0
  fi
  return 1
}

# 入口
case "$1" in
  start)
    check_system_requirements || exit 1
    start_box
    ;;
  stop)
    stop_box
    ;;
  restart)
    stop_box
    sleep 0.5
    check_system_requirements || exit 1
    start_box
    ;;
  force-stop)
    stop_box -f
    ;;
  status)
    if busybox pidof "${bin_name}" >/dev/null; then
      echo "${bin_name} is running"
      exit 0
    else
      echo "${bin_name} is not running"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|force-stop|status}"
    exit 1
    ;;
esac
