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
mod_dir="${mod_root}/box_for_magisk"
PROPFILE="${mod_root}/box_for_magisk/module.prop"

settings="${box_dir}/settings.ini"
config_json="${box_dir}/config.json"
jq="${box_dir}/bin/jq"

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

# iptables settings
fwmark="16777216/16777216"
table="2024"
pref="100"
box_user="root"
box_group="net_admin"
box_user_group="${box_user}:${box_group}"

# check jq command
if [ ! -f "$jq" ]; then
  log ERROR "Cannot find ${box_dir}/bin/jq"
  exit 1
else
  chmod 0700 $jq
fi

# Check jq permissions
if [ ! -x "${jq}" ]; then
  log ERROR "${jq} is not executable."
  exit 1
fi

# check sing-box config
if [ ! -f "$config_json" ]; then
  log ERROR "Cannot find ${box_dir}/config.json"
  exit 1
fi

# get settingss from config.json
inet4_range=$($jq -r '.dns.fakeip.inet4_range  // empty' $config_json)
inet6_range=$($jq -r '.dns.fakeip.inet6_range  // empty' $config_json)
redir_port=$($jq -r '.inbounds[] | select(.type == "redirect") | .listen_port // empty' $config_json)
tproxy_port=$($jq -r '.inbounds[] | select(.type == "tproxy") | .listen_port // empty' $config_json)
stack=$($jq -r '.inbounds[] | select(.type == "tun") | .stack // empty' $config_json)
tun_device=$($jq -r '.inbounds[] | select(.type == "tun") | .interface_name // empty' $config_json)

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

# check box settings
if [ ! -f "$settings" ]; then
  log ERROR "Cannot find ${box_dir}/settings.ini"
  exit 1
fi

# user custom config
source ${box_dir}/settings.ini
