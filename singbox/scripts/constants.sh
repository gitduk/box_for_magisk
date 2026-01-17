#!/system/bin/sh

# ============================================================
# 常量定义文件
# 所有配置常量集中管理，便于维护
# ============================================================

# 防止重复加载
[ -n "${CONSTANTS_LOADED}" ] && return 0
CONSTANTS_LOADED=1

# -------------------- 路径常量 --------------------
readonly BOX_DIR="/data/adb/singbox"
readonly MOD_ROOT="/data/adb/modules"
readonly MOD_DIR="${MOD_ROOT}/box_for_magisk"
readonly SERVICE_DIR="/data/adb/service.d"

# -------------------- 二进制文件 --------------------
readonly BIN_NAME="sing-box"
readonly BIN_PATH="${BOX_DIR}/bin/${BIN_NAME}"
readonly JQ_PATH="${BOX_DIR}/bin/jq"

# -------------------- 配置文件 --------------------
readonly CONFIG_JSON="${BOX_DIR}/config.json"
readonly SETTINGS_INI="${BOX_DIR}/settings.ini"
readonly PROPFILE="${MOD_DIR}/module.prop"

# -------------------- 日志文件 --------------------
readonly RUN_LOG="${BOX_DIR}/logs/run.log"
readonly BOX_LOG="${BOX_DIR}/logs/box.log"
readonly LOG_DIR="${BOX_DIR}/logs"
readonly LOG_MAX_SIZE=10485760  # 10MB
readonly LOG_MAX_BACKUPS=3

# -------------------- 过滤列表 --------------------
readonly INCLUDE_LIST="${BOX_DIR}/include.list"
readonly EXCLUDE_LIST="${BOX_DIR}/exclude.list"

# -------------------- 网络常量 --------------------
readonly FWMARK="16777216/16777216"
readonly ROUTE_TABLE="2024"
readonly ROUTE_PREF="100"

# -------------------- iptables 常量 --------------------
readonly IPTABLES_TIMEOUT=64
readonly CHAINS="BOX_EXTERNAL BOX_LOCAL BOX_IP_V4 BOX_IP_V6"

# -------------------- 用户和组 --------------------
readonly BOX_USER="root"
readonly BOX_GROUP="net_admin"
readonly BOX_USER_GROUP="${BOX_USER}:${BOX_GROUP}"

# -------------------- 进程检查常量 --------------------
readonly MAX_RETRIES=10
readonly RETRY_INTERVAL=0.5
readonly STARTUP_WAIT=3
readonly SHUTDOWN_WAIT=0.5

# -------------------- 系统限制 --------------------
readonly FILE_DESCRIPTOR_LIMIT=1000000

# -------------------- 时区 --------------------
readonly TIMEZONE="Asia/Shanghai"

# -------------------- 内网地址范围 (IPv4) --------------------
# 注意: sh 不支持 readonly 数组，使用普通数组
INTRANET_V4=(
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

# -------------------- 内网地址范围 (IPv6) --------------------
INTRANET_V6=(
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

# -------------------- busybox 路径 --------------------
# 根据不同的 root 方案查找 busybox
BUSYBOX="/data/adb/magisk/busybox"
[ -f "/data/adb/ksu/bin/busybox" ] && BUSYBOX="/data/adb/ksu/bin/busybox"
[ -f "/data/adb/ap/bin/busybox" ] && BUSYBOX="/data/adb/ap/bin/busybox"
