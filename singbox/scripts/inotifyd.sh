#!/system/bin/sh

source "${0%/*}/settings.sh"

events="$1"
monitor_file="$3"

if [ "${monitor_file}" = "disable" ]; then
  if [ "${events}" = "d" ]; then
     log info "[$events] module is enabled, start sing-box service"
    "${scripts_dir}/service.sh" start
  elif [ "${events}" = "n" ]; then
    log info "[$events] module is disabled, stop sing-box service"
    "${scripts_dir}/service.sh" stop
  fi
fi
