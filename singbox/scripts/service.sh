#!/system/bin/sh

source "${0%/*}/settings.sh"

# Check whether busybox is installed or not on the system using command -v
if ! command -v busybox &> /dev/null; then
  log error "$(which busybox) command not found."
  exit 1
fi

# check sing-box command
if [ ! -f "$bin_path" ]; then
  log ERROR "Cannot find ${bin_path}"
  exit 1
fi

# check network_mode
if [ -z "${network_mode}" ]; then
  log ERROR "network_mode is not set"
  exit 1
fi

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

# clear logs
echo -n "" > "${run_log}"
echo -n "" > "${box_log}"

box_is_alive() {
  local PID=$(<"${box_pid}" 2>/dev/null)
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "$(<"${run_log}")"
    log error "${bin_name} service is not running."
    log error "please check ${run_log} and ${box_log} for more information."
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
  else
    log info "${bin_name} is running."
  fi

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
    log INFO "$bin_name service is running!!!"
    echo -n "$PID" > "${box_pid}"
  fi
}

system_info() {
    box_version=$(busybox awk '!/^ *#/ && /version=/ { print $0 }' "$PROPFILE" 2>/dev/null)
    timezone=$(getprop persist.sys.timezone)
    sim_operator=$(getprop gsm.sim.operator.alpha)
    sim_type=$(getprop gsm.network.type)
    date=$(date)
    cpu_abi=$(getprop ro.product.cpu.abi)

    log info "${timezone}"
    log info "${sim_operator} / ${sim_type}"
    log info "${date}"
    log info "${box_version}"
    log info "${cpu_abi}"
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
  # Clear the log file and add the timestamp and delimiter
  # cd /data/adb/box/bin; chmod 755 *
  log INFO "Module is working! but no service is running"
  system_info

  # set permission
  chown -R ${box_user_group} ${box_dir}
  chown ${box_user_group} ${bin_path}
  chmod 6755 ${bin_path}

  # Check permissions
  if [ ! -x "${bin_path}" ]; then
    log ERROR "${bin_path} is not executable."
    exit 1
  fi

  # run sing-box
  log info "start ${bin_name} service."

  # sing-box config
  log debug "fake-ip-range: ${inet4_range}, ${inet6_range}"
  log debug "redir_port: ${redir_port}, tproxy_port: ${tproxy_port}"
  log debug "tun_device: ${tun_device}, stack: ${stack}"
  log debug "network_mode: ${network_mode}"

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

  log info "set iptable rules"
  ${scripts_dir}/iptables.sh "${network_mode}"
  ipv6_setup

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
  else
    log warn "${bin_name} Not stopped; may still be shutting down or failed to shut down."
    force_stop
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
    rm -f "${box_pid}"
  fi
}

ipv6_setup() {
  if [ "${ipv6}" == "true" ]; then
    log debug "ipv6: enabled"
    {
      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv6.conf.all.forwarding=1
      sysctl -w net.ipv6.conf.all.accept_ra=2
      sysctl -w net.ipv6.conf.wlan0.accept_ra=2
      sysctl -w net.ipv6.conf.all.disable_ipv6=0
      sysctl -w net.ipv6.conf.default.disable_ipv6=0
      sysctl -w net.ipv6.conf.wlan0.disable_ipv6=0
      # del: block Askes ipv6 completely
      ip -6 rule del unreachable pref "${pref}" 2>/dev/null
      # add: blocks all outgoing IPv6 traffic using the UDP protocol to port 53, effectively preventing DNS queries over IPv6.
      if ! ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null; then
        ip6tables -w 64 -A OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null
      fi
    } &> /dev/null
  else
    {
      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv6.conf.all.forwarding=0
      sysctl -w net.ipv6.conf.all.accept_ra=0
      sysctl -w net.ipv6.conf.wlan0.accept_ra=0
      sysctl -w net.ipv6.conf.all.disable_ipv6=1
      sysctl -w net.ipv6.conf.default.disable_ipv6=1
      sysctl -w net.ipv6.conf.wlan0.disable_ipv6=1
      # add: block Askes ipv6 completely
      ip -6 rule add unreachable pref "${pref}" 2>/dev/null
      # del: blocks all outgoing IPv6 traffic using the UDP protocol to port 53, effectively preventing DNS queries over IPv6.
      if ip6tables -C OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null; then
        ip6tables -w 64 -D OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null
      fi
    } &> /dev/null
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
    # stop
    stop_box
    sleep 0.5
    # start
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
