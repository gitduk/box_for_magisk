#!/system/bin/sh

# ============================================================
# 工具函数库
# 提供日志、进程管理、日志轮转等通用功能
# ============================================================

# 防止重复加载
[ -n "${UTILS_LOADED}" ] && return 0
UTILS_LOADED=1

# 依赖常量文件
source "${0%/*}/constants.sh"

# -------------------- 日志函数 --------------------
log() {
  export TZ="${TIMEZONE}"
  local now=$(date +"[%Y-%m-%d %H:%M:%S %Z]")
  local level="$1"
  local message="$2"

  # 统一转换为大写显示
  local display_level=$(echo "$level" | tr '[:lower:]' '[:upper:]')

  case "$level" in
    info)
      [ -t 1 ] && echo -e "\033[1;32m${now} [INFO]: ${message}\033[0m" || echo "${now} [INFO]: ${message}" | tee -a "${RUN_LOG}"
      ;;
    warn)
      [ -t 1 ] && echo -e "\033[1;33m${now} [WARN]: ${message}\033[0m" || echo "${now} [WARN]: ${message}" | tee -a "${RUN_LOG}"
      ;;
    error)
      [ -t 1 ] && echo -e "\033[1;31m${now} [ERROR]: ${message}\033[0m" || echo "${now} [ERROR]: ${message}" | tee -a "${RUN_LOG}"
      ;;
    debug)
      [ -t 1 ] && echo -e "\033[1;36m${now} [DEBUG]: ${message}\033[0m" || echo "${now} [DEBUG]: ${message}" | tee -a "${RUN_LOG}"
      ;;
    *)
      [ -t 1 ] && echo -e "\033[1;30m${now} [${display_level}]: ${message}\033[0m" || echo "${now} [${display_level}]: ${message}" | tee -a "${RUN_LOG}"
      ;;
  esac

  # 更新模块描述（所有日志级别都更新）
  if [ -f "${PROPFILE}" ]; then
    local escaped_level=$(printf '%s\n' "$display_level" | sed 's/[\/&]/\\&/g')
    local escaped_msg=$(printf '%s\n' "$message" | sed 's/[\/&]/\\&/g')
    sed -Ei "s/^description=.*/description=${now} [${escaped_level}]: ${escaped_msg} /g" "${PROPFILE}" 2>/dev/null || true
  fi
}

# -------------------- 日志轮转函数 --------------------
rotate_log() {
  local log_file="$1"

  [ ! -f "$log_file" ] && return 0

  local log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)

  # 如果日志文件超过最大大小，进行轮转
  if [ "$log_size" -gt "${LOG_MAX_SIZE}" ]; then
    log info "Rotating log file: $log_file (size: $log_size bytes)"

    # 删除最旧的备份
    [ -f "${log_file}.${LOG_MAX_BACKUPS}" ] && rm -f "${log_file}.${LOG_MAX_BACKUPS}"

    # 轮转现有备份
    local i="${LOG_MAX_BACKUPS}"
    while [ $i -gt 1 ]; do
      local prev=$((i - 1))
      [ -f "${log_file}.${prev}" ] && mv "${log_file}.${prev}" "${log_file}.${i}"
      i=$prev
    done

    # 移动当前日志到 .1
    mv "$log_file" "${log_file}.1"
    touch "$log_file"
  fi
}

# -------------------- 进程检查函数 --------------------
check_process_running() {
  local process_name="$1"
  local retries=0

  while [ $retries -lt "${MAX_RETRIES}" ]; do
    sleep "${RETRY_INTERVAL}"
    if PID=$(busybox pidof "$process_name"); then
      return 0
    fi
    retries=$((retries + 1))
  done

  log error "Process ${process_name} not found after ${MAX_RETRIES} retries"
  return 1
}

# -------------------- 等待网络就绪 --------------------
wait_for_network() {
  local max_wait=10
  log info "Waiting for network to be ready"

  for i in $(seq 1 $max_wait); do
    if ip route | grep -q default; then
      log info "Network is ready"
      return 0
    fi
    sleep 0.5
  done

  log warn "Network may not be ready, proceeding anyway"
  return 1
}

# -------------------- 检查命令是否存在 --------------------
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# -------------------- 安全的 kill 进程 --------------------
safe_kill() {
  local process_name="$1"
  local signal="${2:-15}"  # 默认 SIGTERM

  if busybox pgrep "$process_name" >/dev/null; then
    log info "Killing process: ${process_name} with signal ${signal}"
    if ! busybox pkill -"${signal}" "$process_name" >/dev/null 2>&1; then
      if command_exists killall; then
        killall -"${signal}" "$process_name" >/dev/null 2>&1
      else
        kill -"${signal}" "$(busybox pidof "$process_name")" >/dev/null 2>&1
      fi
    fi
    return 0
  fi
  return 1
}

# -------------------- 强制 kill 进程 --------------------
force_kill() {
  local process_name="$1"

  log warn "Force killing process: ${process_name}"
  safe_kill "$process_name" 9

  sleep "${SHUTDOWN_WAIT}"
  if ! busybox pidof "$process_name" >/dev/null 2>&1; then
    log info "Process ${process_name} forcefully stopped"
    return 0
  fi

  log error "Failed to force kill ${process_name}"
  return 1
}

# -------------------- 获取应用 UID --------------------
get_app_uid() {
  local package="$1"
  local packages="$(pm list packages -U 2>/dev/null)"
  local uid=$(echo "$packages" | grep -w "$package" | tr -dc '0-9')
  echo "$uid"
}

# -------------------- 读取配置项 --------------------
read_config() {
  local config_file="$1"
  local key="$2"
  local default="$3"

  if [ -f "$config_file" ]; then
    local value=$(grep "^${key}=" "$config_file" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    [ -n "$value" ] && echo "$value" || echo "$default"
  else
    echo "$default"
  fi
}

# -------------------- 从 JSON 读取配置 --------------------
read_json_config() {
  local json_path="$1"
  local jq_query="$2"
  local default="$3"

  if [ -f "${JQ_PATH}" ] && [ -f "$json_path" ]; then
    local value=$(${JQ_PATH} -r "$jq_query" "$json_path" 2>/dev/null)
    [ -n "$value" ] && [ "$value" != "null" ] && echo "$value" || echo "$default"
  else
    echo "$default"
  fi
}

# -------------------- 验证 IP 地址 --------------------
validate_ip() {
  local ip="$1"
  # 简单的 IPv4 验证
  echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && return 0 || return 1
}

# -------------------- 验证端口 --------------------
validate_port() {
  local port="$1"
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null && return 0 || return 1
}

# -------------------- 检查 root 权限 --------------------
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log error "This script requires root privileges"
    return 1
  fi
  return 0
}

# -------------------- 创建目录（安全） --------------------
safe_mkdir() {
  local dir="$1"
  local mode="${2:-0755}"

  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    chmod "$mode" "$dir"
  fi
}

# -------------------- 检查文件是否可执行 --------------------
check_executable() {
  local file="$1"

  if [ ! -f "$file" ]; then
    log error "File not found: ${file}"
    return 1
  fi

  if [ ! -x "$file" ]; then
    log error "File is not executable: ${file}"
    return 1
  fi

  return 0
}

# -------------------- 清理旧的 PID 文件 --------------------
cleanup_pid_files() {
  local pid_dir="/data/local/tmp"
  find "$pid_dir" -name "*.pid" -mtime +1 -delete 2>/dev/null
}

# -------------------- 检查磁盘空间 --------------------
check_disk_space() {
  local path="$1"
  local required_mb="${2:-10}"  # 默认要求 10MB

  # Android 的 df 命令可能不支持 -m 选项，使用 -k 并转换
  local available_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')

  if [ -z "$available_kb" ] || [ "$available_kb" = "" ]; then
    # 如果 df 命令失败，跳过检查
    return 0
  fi

  local available_mb=$((available_kb / 1024))

  if [ "$available_mb" -lt "$required_mb" ]; then
    log warn "Low disk space: ${available_mb}MB available, ${required_mb}MB required"
    return 1
  fi

  return 0
}
