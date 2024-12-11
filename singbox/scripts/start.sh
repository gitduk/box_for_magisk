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
