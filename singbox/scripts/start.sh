#!/system/bin/sh

source "${0%/*}/settings.sh"

# check busybox
busybox_code=$(busybox | busybox grep -oE '[0-9.]*' | head -n 1)
if [ "$(echo "${busybox_code}" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" -lt "$(echo "1.36.1" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" ]; then
  log info "Current $(which busybox) v${busybox_code}"
  log warn "Please update your busybox to v1.36.1+"
else
  log info "Current $(which busybox) v${busybox_code}"
fi

# clear logs
echo -n "" > "${run_log}"
echo -n "" > "${box_log}"

# check box settings
if [ ! -f "$settings" ]; then
  log ERROR "Cannot find ${box_dir}/settings.ini"
  exit 1
fi

# check sing-box config
if [ ! -f "$config_json" ]; then
  log ERROR "Cannot find ${box_dir}/config.json"
  exit 1
fi

# check jq command
if [ ! -f "$jq" ]; then
  log ERROR "Cannot find ${box_dir}/bin/jq"
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

start_inotifyd() {
  PIDS=($($busybox pidof inotifyd))
  for PID in "${PIDS[@]}"; do
    if grep -q -e "inotifyd.sh" "/proc/$PID/cmdline"; then
      kill -9 "$PID"
    fi
  done
  log info "running inotifyd"
  inotifyd "${scripts_dir}/inotifyd.sh" "${mod_dir}" > "/dev/null" 2>&1 &
  log info "DONE"
}

${scripts_dir}/service.sh start
start_inotifyd
