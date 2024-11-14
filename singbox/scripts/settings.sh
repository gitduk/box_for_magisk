#!/system/bin/sh

if ! command -v busybox &> /dev/null; then
  export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH:/system/bin"
fi

# busysingbox Magisk/KSU/Apatch
busybox="/data/adb/magisk/busybox"
[ -f "/data/adb/ksu/bin/busybox" ] && busybox="/data/adb/ksu/bin/busybox"
[ -f "/data/adb/ap/bin/busybox" ] && busybox="/data/adb/ap/bin/busybox"

# box settings
bin_name="sing-box"
box_dir="/data/adb/singbox"
bin_path="${box_dir}/bin/${bin_name}"
run_log="${box_dir}/logs/run.log"
box_log="${box_dir}/logs/box.log"
box_pid="${box_dir}/.box.pid"
scripts_dir="${box_dir}/scripts"

mod_root="/data/adb/modules"
mod_dir="${mod_root}/singbox"
PROPFILE="${mod_root}/singbox_for_magisk/module.prop"

# clear logs
echo "" > "${run_log}"
echo "" > "${box_log}"

# log function
log() {
  export TZ=Asia/Shanghai
  now=$(date +"[%Y-%m-%d %H:%M:%S %Z]")
  case $1 in
    info)
      [ -t 1 ] && echo -e "\033[1;32m${now} [INFO]: $2\033[0m" || echo "${now} [Info]: $2" | tee -a "${run_log}"
      ;;
    warn)
      [ -t 1 ] && echo -e "\033[1;33m${now} [WARN]: $2\033[0m" || echo "${now} [Warn]: $2" | tee -a "${run_log}"
      ;;
    error)
      [ -t 1 ] && echo -e "\033[1;31m${now} [ERROR]: $2\033[0m" || echo "${now} [Error]: $2" | tee -a "${run_log}"
      ;;
    debug)
      [ -t 1 ] && echo -e "\033[1;36m${now} [DEBUG]: $2\033[0m" || echo "${now} [Debug]: $2" | tee -a "${run_log}"
      ;;
    *)
      [ -t 1 ] && echo -e "\033[1;30m${now} [$1]: $2\033[0m" || echo "${now} [$1]: $2" | tee -a "${run_log}"
      escaped_1=$(printf '%s\n' "$1" | sed 's/[\/&]/\\&/g')
      escaped_2=$(printf '%s\n' "$2" | sed 's/[\/&]/\\&/g')
      sed -Ei "s/^description=.*/description=${now} [${escaped_1}]: ${escaped_2} /g" "${PROPFILE}"
      ;;
  esac
}

# check box settings
settings="${box_dir}/settings.ini"
if [ ! -f "$settings" ]; then
  log ERROR "Cannot find ${box_dir}/settings.ini"
  exit 1
fi

# check sing-box config
config_json="${box_dir}/config.json"
if [ ! -f "$config_json" ]; then
  log ERROR "Cannot find ${box_dir}/config.json"
  exit 1
fi

# check jq command
jq="${box_dir}/bin/jq"
if [ ! -f "$jq" ]; then
  log ERROR "Cannot find ${box_dir}/bin/jq"
  exit 1
fi

# check sing-box command
if [ ! -f "$bin_path" ]; then
  log ERROR "Cannot find ${bin_path}"
  exit 1
fi

# iptables settings
fwmark="16777216/16777216"
table="2024"
pref="100"
box_user="root"
box_group="net_admin"

# set permission
box_user_group="${box_user}:${box_group}"
chown -R ${box_user_group} ${box_dir}
chown ${box_user_group} ${bin_path}
chmod 6755 ${bin_path}
chmod 0700 $jq

# get settingss from config.json
inet4_range=$($jq -r '.dns.fakeip.inet4_range  // empty' $config_json)
inet6_range=$($jq -r '.dns.fakeip.inet6_range  // empty' $config_json)
redir_port=$($jq -r '.inbounds[] | select(.type == "redirect") | .listen_port // empty' $config_json)
tproxy_port=$($jq -r '.inbounds[] | select(.type == "tproxy") | .listen_port // empty' $config_json)
stack=$($jq -r '.outbounds[] | select(.type == "tun") | .stack' $config_json)
tun_device=$($jq -r '.outbounds[] | select(.type == "tun") | .device' $config_json)

log debug "fake-ip-range: ${inet4_range}, ${inet6_range}"
log debug "redir_port: ${redir_port}, tproxy_port: ${tproxy_port}"
log debug "tun_device: ${tun_device}, stack: ${stack}"

# define intranet ip range
intranet=(
  0.0.0.0/8
  10.0.0.0/8
  100.64.0.0/10
  127.0.0.0/8
  169.254.0.0/16
  172.16.0.0/12
  192.0.0.0/24
  192.0.2.0/24
  192.88.99.0/24
  192.168.0.0/16
  198.51.100.0/24
  203.0.113.0/24
  224.0.0.0/4
  240.0.0.0/4
  255.0.0.0/4
  255.255.255.0/24
  255.255.255.255/32
)
intranet+=($inet4_range)

intranet6=(
  ::/128
  ::1/128
  ::ffff:0:0/96
  100::/64
  64:ff9b::/96
  2001::/32
  2001:10::/28
  2001:20::/28
  2001:db8::/32
  2002::/16
  2408:8000::/20
  2409:8000::/20
  240e::/18
  fc00::/7
  fe80::/10
  ff00::/8
)
intranet6+=($inet6_range)

# user custom config
source ${box_dir}/settings.ini

# check network_mode
if [ -z "${network_mode}" ]; then
  log warn "network_mode is not set, use default mode: redirect"
  network_mode="redirect"
fi
log debug "network_mode: ${network_mode}"

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

# check busybox
busybox_code=$(busybox | busybox grep -oE '[0-9.]*' | head -n 1)
if [ "$(echo "${busybox_code}" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" -lt "$(echo "1.36.1" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" ]; then
  log info "Current $(which busybox) v${busybox_code}"
  log warn "Please update your busybox to v1.36.1+"
else
  log info "Current $(which busybox) v${busybox_code}"
fi
