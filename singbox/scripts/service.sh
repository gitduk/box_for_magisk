#!/system/bin/sh

source "${0%/*}/settings.sh"

# create tun
if [ -n "${tun_device}" ] && [[ "${network_mode}" == @(mixed|tun) ]]; then
  log debug "use tun device: ${tun_device}"
  mkdir -p /dev/net
  [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun
  if [ ! -c "/dev/net/tun" ]; then
    log error "Cannot create /dev/net/tun. Possible reasons:"
    log warn "Your system does not support the TUN/TAP driver."
    log warn "Your system kernel version is not compatible with the TUN/TAP driver."
    log info "change network_mode to tproxy"
    sed -i 's/network_mode=.*/network_mode="redirect"/g' "${settings}"
    exit 1
  fi
fi

check_process_running() {
  local retries=0
  local max_retries=10
  local sleep_interval=0.5
  while [ $retries -le $max_retries ]; do
    sleep $sleep_interval
    PID=$(busybox pidof "$1")
    [ -n "$PID" ] && return 0
    retries=$((retries + 1))
  done
  return 1
}

renew_iptables() {
    # Update iptables if bin_name is still running
    if [ -z "$PID" ]; then
      PID="$(busybox pidof "${bin_name}")"
    fi

    # if sing-box is still running, stop it
    if [ -n "$PID" ]; then
      pid_name="${box_dir}/pid_name.txt"
      ps -p $PID -o comm= > "${pid_name}"
      sed -i '/^[[:space:]]*$/d' "${pid_name}"
      log debug "$(<"${pid_name}")(PID: $PID) service is still running, auto restart box."
      rm -f "${pid_name}"
      stop_box
      exit 1
    fi

    return 0
}

start_box() {
  log INFO "Module is working! but no service is running"

  # Clear the log file
  echo -n "" > "${run_log}"
  echo -n "" > "${box_log}"

  # set permission
  chown -R ${box_user_group} ${box_dir}
  chown ${box_user_group} ${bin_path}
  chmod 6755 ${bin_path}

  # Check permissions
  if [ ! -x "${bin_path}" ]; then
    log ERROR "${bin_path} is not executable."
    exit 1
  fi

  # sing-box config
  log debug "fake-ip-range: ${inet4_range}, ${inet6_range}"
  log debug "redir_port: ${redir_port}, tproxy_port: ${tproxy_port}"
  log debug "tun_device: ${tun_device}, stack: ${stack}"
  log debug "network_mode: ${network_mode}"

  # Use ulimit to limit the memory usage of a process to 200MB
  # ulimit -v 200000  # Set the virtual memory limit in KB
  ulimit -SHn 1000000

  log info "start ${bin_name} service."
  if ${bin_path} check -D "${box_dir}/" -C "${box_dir}" > "${box_log}" 2>&1; then
    nohup busybox setuidgid "${box_user_group}" "${bin_path}" run -D "${box_dir}" -C "${box_dir}" >> "${box_log}" 2>&1 &
    sleep 1
  else
    log error "$(<"${run_log}")"
    log ERROR "configuration failed. Please check the ${run_log} file."
    exit 1
  fi

  # check if the binary is running
  if check_process_running "${bin_name}"; then
    PID="$(busybox pidof "${bin_name}")"
    echo "$PID" > "${box_pid}"
  else
    log ERROR "${bin_name} is not running. Please check ${run_log} and ${box_log}."
    killall -15 "${bin_name}" >/dev/null 2>&1 || busybox pkill -15 "${bin_name}" >/dev/null 2>&1
    exit 1
  fi

  log info "setup iptable rules"
  ${scripts_dir}/iptables.sh "${network_mode}"

  log info "setup ipv6 forwarding"
  ipv6_setup

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
  if busybox pidof "${bin_name}" >/dev/null 2>&1; then
    log warn "${bin_name} Not stopped, may still be shutting down or failed to shut down."
    force_stop
  fi

  # clear the pid file
  if ! busybox pidof "${bin_name}" &>/dev/null && [ -f "${box_pid}" ]; then
    rm -f "${box_pid}"
  fi

  log INFO "$bin_name shutting down, service is stopped !!!"

  log info "clear iptable rules"
  ${scripts_dir}/iptables.sh "clear"
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
  fi
}

ipv6_setup() {
  sysctl -w net.ipv4.ip_forward=1 &>/dev/null
  if [ "${ipv6}" == "true" ]; then
    log debug "ipv6: enabled"
    sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=0 &>/dev/null
    # del: block Askes ipv6 completely
    ip -6 rule del unreachable pref "${pref}" &>/dev/null
    # add: blocks all outgoing IPv6 traffic using the UDP protocol to port 53, effectively preventing DNS queries over IPv6.
    if ! ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null; then
      ip6tables -w 64 -A OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null
    fi
  else
    sysctl -w net.ipv6.conf.all.forwarding=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=1 &>/dev/null
    # add: block Askes ipv6 completely
    ip -6 rule add unreachable pref "${pref}" &>/dev/null
    # del: blocks all outgoing IPv6 traffic using the UDP protocol to port 53, effectively preventing DNS queries over IPv6.
    if ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null; then
      ip6tables -w 64 -D OUTPUT -p udp --destination-port 53 -j DROP &>/dev/null
    fi
  fi
}

case "$1" in
  start)
    start_box
    ;;
  stop)
    stop_box
    ;;
  restart)
    stop_box
    sleep 0.5
    start_box
    ;;
  *)
    echo "${red}$0 $1 no found${normal}"
    echo "${yellow}usage${normal}: ${green}$0${normal} {${yellow}start|stop|restart${normal}}"
    ;;
esac
