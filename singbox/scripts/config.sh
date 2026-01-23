#!/system/bin/sh

# ============================================================
# 配置加载模块
# 从 config.json 和 settings.ini 读取所有配置
# ============================================================

# 防止重复加载
[ -n "${CONFIG_LOADED}" ] && return 0
CONFIG_LOADED=1

# 依赖文件
source "${0%/*}/constants.sh"
source "${0%/*}/utils.sh"

# -------------------- 环境变量设置 --------------------
setup_environment() {
  if ! command -v busybox &> /dev/null; then
    export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH:/system/bin"
  fi
}

# -------------------- 下载配置文件 --------------------
download_config_from_url() {
  local url="$1"
  local retry_count=0

  log info "Downloading configuration from URL: ${url}"

  # 检查是否有可用的下载工具
  local download_tool=""
  if command -v curl >/dev/null 2>&1; then
    download_tool="curl"
  elif command -v wget >/dev/null 2>&1; then
    download_tool="wget"
  else
    log error "Neither curl nor wget found. Cannot download configuration file."
    log error "Please install curl or wget, or manually place config.json in ${BOX_DIR}/"
    return 1
  fi

  # 重试下载
  while [ $retry_count -lt $DOWNLOAD_MAX_RETRIES ]; do
    log info "Download attempt $((retry_count + 1))/${DOWNLOAD_MAX_RETRIES}..."

    # 根据工具选择下载命令
    if [ "$download_tool" = "curl" ]; then
      if curl -L -f -s -m "${DOWNLOAD_TIMEOUT}" -o "${CONFIG_JSON}" "${url}"; then
        log info "Configuration downloaded successfully"

        # 验证下载的文件是否是有效的 JSON
        if [ -f "${JQ_PATH}" ] && ${JQ_PATH} empty "${CONFIG_JSON}" >/dev/null 2>&1; then
          log info "Downloaded configuration is valid JSON"
          return 0
        else
          log warn "Downloaded file is not valid JSON, retrying..."
          rm -f "${CONFIG_JSON}" 2>/dev/null
        fi
      fi
    else
      if wget -q -T "${DOWNLOAD_TIMEOUT}" -O "${CONFIG_JSON}" "${url}"; then
        log info "Configuration downloaded successfully"

        # 验证下载的文件是否是有效的 JSON
        if [ -f "${JQ_PATH}" ] && ${JQ_PATH} empty "${CONFIG_JSON}" >/dev/null 2>&1; then
          log info "Downloaded configuration is valid JSON"
          return 0
        else
          log warn "Downloaded file is not valid JSON, retrying..."
          rm -f "${CONFIG_JSON}" 2>/dev/null
        fi
      fi
    fi

    retry_count=$((retry_count + 1))
    [ $retry_count -lt $DOWNLOAD_MAX_RETRIES ] && sleep 2
  done

  log error "Failed to download configuration after ${DOWNLOAD_MAX_RETRIES} attempts"
  return 1
}

# -------------------- 验证必需文件 --------------------
validate_required_files() {
  local missing_files=0

  # 检查 jq
  if [ ! -f "${JQ_PATH}" ]; then
    log error "Cannot find ${JQ_PATH}"
    missing_files=$((missing_files + 1))
  elif [ ! -x "${JQ_PATH}" ]; then
    log error "${JQ_PATH} is not executable"
    chmod 0700 "${JQ_PATH}" 2>/dev/null || missing_files=$((missing_files + 1))
  fi

  # 先检查 settings.ini 是否存在
  if [ ! -f "${SETTINGS_INI}" ]; then
    log error "Cannot find ${SETTINGS_INI}"
    missing_files=$((missing_files + 1))
  fi

  # 检查 config.json
  if [ ! -f "${CONFIG_JSON}" ]; then
    log warn "config.json not found at ${CONFIG_JSON}"

    # 如果 settings.ini 存在，尝试从 URL 下载
    if [ -f "${SETTINGS_INI}" ]; then
      # 加载 settings.ini 获取 URL
      source "${SETTINGS_INI}"

      if [ -n "${config_url}" ] && [ "${config_url}" != "" ]; then
        log info "Found config_url in settings.ini, attempting to download..."

        if download_config_from_url "${config_url}"; then
          log info "Configuration file downloaded successfully"
        else
          log error "Failed to download configuration from URL: ${config_url}"
          log error ""
          log error "Please either:"
          log error "  1. Check if the URL is accessible: ${config_url}"
          log error "  2. Manually place your config.json in: ${BOX_DIR}/"
          log error "  3. Fix the 'config_url' setting in: ${SETTINGS_INI}"
          missing_files=$((missing_files + 1))
        fi
      else
        log error "config.json not found and no config_url configured"
        log error ""
        log error "Please either:"
        log error "  1. Place your config.json in: ${BOX_DIR}/"
        log error "  2. Add 'config_url=\"https://your-url/config.json\"' in: ${SETTINGS_INI}"
        missing_files=$((missing_files + 1))
      fi
    else
      log error "Cannot find ${CONFIG_JSON}, and ${SETTINGS_INI} is also missing"
      missing_files=$((missing_files + 1))
    fi
  fi

  [ $missing_files -gt 0 ] && return 1
  return 0
}

# -------------------- 从 config.json 加载配置 --------------------
load_config_json() {
  local quiet="${1:-false}"

  [ "$quiet" = "false" ] && log info "Loading configuration from ${CONFIG_JSON}"

  # 检查 jq 和 config.json 是否存在
  if [ ! -f "${JQ_PATH}" ]; then
    log error "jq not found at ${JQ_PATH}"
    return 1
  fi

  if [ ! -f "${CONFIG_JSON}" ]; then
    log error "config.json not found at ${CONFIG_JSON}"
    return 1
  fi

  # DNS FakeIP 配置
  inet4_range=$(${JQ_PATH} -r '.dns.fakeip.inet4_range // empty' "${CONFIG_JSON}" 2>/dev/null)
  inet6_range=$(${JQ_PATH} -r '.dns.fakeip.inet6_range // empty' "${CONFIG_JSON}" 2>/dev/null)

  # Inbound 端口配置（直接使用 jq 命令）
  redir_port=$(${JQ_PATH} -r '.inbounds[] | select(.type == "redirect") | .listen_port // empty' "${CONFIG_JSON}" 2>/dev/null)
  tproxy_port=$(${JQ_PATH} -r '.inbounds[] | select(.type == "tproxy") | .listen_port // empty' "${CONFIG_JSON}" 2>/dev/null)

  # TUN 配置
  stack=$(${JQ_PATH} -r '.inbounds[] | select(.type == "tun") | .stack // empty' "${CONFIG_JSON}" 2>/dev/null)
  tun_device=$(${JQ_PATH} -r '.inbounds[] | select(.type == "tun") | .interface_name // empty' "${CONFIG_JSON}" 2>/dev/null)

  # 清理空值（jq 返回的 "empty" 字符串）
  [ "$inet4_range" = "" ] && inet4_range=""
  [ "$inet6_range" = "" ] && inet6_range=""
  [ "$redir_port" = "" ] && redir_port=""
  [ "$tproxy_port" = "" ] && tproxy_port=""
  [ "$stack" = "" ] && stack=""
  [ "$tun_device" = "" ] && tun_device=""

  # 验证端口配置
  if [ -n "$redir_port" ]; then
    validate_port "$redir_port" || log warn "Invalid redir_port: ${redir_port}"
  fi

  if [ -n "$tproxy_port" ]; then
    validate_port "$tproxy_port" || log warn "Invalid tproxy_port: ${tproxy_port}"
  fi

  # 友好提示：检查常见的配置缺失
  if [ -z "$tproxy_port" ] && [ -z "$redir_port" ] && [ -z "$tun_device" ]; then
    log warn "No inbound configuration found in ${CONFIG_JSON}"
    log warn "Please add at least one of the following inbound types:"
    log warn "  - tproxy: for transparent proxy mode"
    log warn "  - redirect: for redirect mode"
    log warn "  - tun: for TUN mode (recommended)"
  fi

  # 导出变量供其他脚本使用
  export inet4_range inet6_range redir_port tproxy_port stack tun_device

  return 0
}

# -------------------- 从 settings.ini 加载配置 --------------------
load_settings_ini() {
  local quiet="${1:-false}"

  [ "$quiet" = "false" ] && log info "Loading configuration from ${SETTINGS_INI}"

  # 加载用户配置
  source "${SETTINGS_INI}"

  # 设置默认值
  ipv6="${ipv6:-false}"
  network_mode="${network_mode:-tproxy}"

  # 验证网络模式
  case "$network_mode" in
    redirect|tproxy|tun)
      log info "Network mode: ${network_mode}"
      ;;
    *)
      log warn "Invalid network_mode: ${network_mode}, using default: tproxy"
      network_mode="tproxy"
      ;;
  esac

  # 验证 IPv6 配置
  case "$ipv6" in
    true|false)
      log info "IPv6: ${ipv6}"
      ;;
    *)
      log warn "Invalid ipv6 setting: ${ipv6}, using default: false"
      ipv6="false"
      ;;
  esac

  # 导出变量
  export ipv6 network_mode ap_list
}

# -------------------- 构建内网地址列表 --------------------
build_intranet_list() {
  # 合并内网地址和 FakeIP 范围
  intranet=("${INTRANET_V4[@]}")
  [ -n "$inet4_range" ] && intranet+=("$inet4_range")

  intranet6=("${INTRANET_V6[@]}")
  [ -n "$inet6_range" ] && intranet6+=("$inet6_range")

  # 导出数组
  export intranet intranet6
}

# -------------------- 清理不匹配的 inbound 配置 --------------------
remove_mismatched_inbounds() {
  local target_mode="$1"
  local quiet="${2:-false}"

  # 检查 jq 是否可用
  if [ ! -f "${JQ_PATH}" ]; then
    log error "jq not found, cannot clean up inbound configurations"
    return 1
  fi

  # 检查 config.json 是否存在
  if [ ! -f "${CONFIG_JSON}" ]; then
    log error "config.json not found, cannot clean up inbound configurations"
    return 1
  fi

  # 创建备份
  local backup_file="${CONFIG_JSON}.backup.$(date +%Y%m%d_%H%M%S)"
  cp "${CONFIG_JSON}" "${backup_file}" 2>/dev/null
  [ "$quiet" = "false" ] && log info "Created backup: ${backup_file}"

  # 获取当前所有 inbound 类型
  local all_types=$(${JQ_PATH} -r '.inbounds[].type' "${CONFIG_JSON}" 2>/dev/null | sort -u | tr '\n' ' ')

  # 根据 network_mode 确定要保留和删除的类型
  local types_to_remove=""
  case "$target_mode" in
    tproxy)
      # 保留 tproxy，删除 tun 和 redirect
      types_to_remove="tun redirect"
      ;;
    redirect)
      # 保留 redirect，删除 tun 和 tproxy
      types_to_remove="tun tproxy"
      ;;
    tun)
      # 保留 tun，删除 tproxy 和 redirect
      types_to_remove="tproxy redirect"
      ;;
    *)
      log error "Unknown network_mode: ${target_mode}"
      return 1
      ;;
  esac

  # 检查是否有需要删除的 inbound
  local has_removals=0
  for type in $types_to_remove; do
    if echo "$all_types" | grep -qw "$type"; then
      has_removals=1
      [ "$quiet" = "false" ] && log warn "Found mismatched inbound type: ${type} (network_mode is ${target_mode})"
    fi
  done

  # 如果没有需要删除的，直接返回
  if [ $has_removals -eq 0 ]; then
    [ "$quiet" = "false" ] && log info "No mismatched inbound configurations found"
    rm -f "${backup_file}" 2>/dev/null
    return 0
  fi

  # 使用 jq 删除不匹配的 inbound
  [ "$quiet" = "false" ] && log info "Removing mismatched inbound configurations..."

  # 逐个删除不匹配的类型
  local temp_file="${CONFIG_JSON}.tmp"
  local current_file="${CONFIG_JSON}"

  for type in $types_to_remove; do
    [ "$quiet" = "false" ] && log info "Removing inbound type: ${type}"

    if ${JQ_PATH} ".inbounds |= map(select(.type != \"${type}\"))" "${current_file}" > "${temp_file}" 2>/dev/null; then
      mv "${temp_file}" "${current_file}"
    else
      log error "Failed to remove inbound type: ${type}"
      log error "Restoring from backup..."
      mv "${backup_file}" "${CONFIG_JSON}"
      rm -f "${temp_file}" 2>/dev/null
      return 1
    fi
  done

  [ "$quiet" = "false" ] && log info "Successfully removed mismatched inbound configurations"
  [ "$quiet" = "false" ] && log info "Backup saved to: ${backup_file}"
  return 0
}

# -------------------- 检查配置一致性 --------------------
validate_config_consistency() {
  local quiet="${1:-false}"

  # 自动清理不匹配的 inbound 配置
  # 检查是否存在不匹配的 inbound 类型
  local need_cleanup=0

  case "$network_mode" in
    tproxy)
      # 如果是 tproxy 模式但有 tun 或 redirect inbound
      if [ -n "$tun_device" ] || [ -n "$redir_port" ]; then
        need_cleanup=1
      fi
      ;;
    redirect)
      # 如果是 redirect 模式但有 tun 或 tproxy inbound
      if [ -n "$tun_device" ] || [ -n "$tproxy_port" ]; then
        need_cleanup=1
      fi
      ;;
    tun)
      # 如果是 tun 模式但有 tproxy 或 redirect inbound
      if [ -n "$tproxy_port" ] || [ -n "$redir_port" ]; then
        need_cleanup=1
      fi
      ;;
  esac

  # 如果需要清理，执行清理操作
  if [ $need_cleanup -eq 1 ]; then
    [ "$quiet" = "false" ] && log warn "Detected mismatched inbound configuration"
    [ "$quiet" = "false" ] && log warn "  - network_mode in settings.ini: ${network_mode}"
    [ "$quiet" = "false" ] && log warn "  - Removing incompatible inbound types from config.json"

    if remove_mismatched_inbounds "$network_mode" "$quiet"; then
      # 重新加载配置以获取更新后的值
      load_config_json "true"
    else
      log error "Failed to clean up mismatched inbound configurations"
      return 1
    fi
  fi

  # 重要：如果 config.json 中有 TUN inbound，sing-box 需要完整 root 权限
  # 无论 network_mode 设置为什么，都需要调整启动方式
  if [ -n "$tun_device" ] && [ "$network_mode" != "tun" ]; then
    [ "$quiet" = "false" ] && log warn "Configuration notice:"
    [ "$quiet" = "false" ] && log warn "  - Your config.json has TUN inbound (${tun_device})"
    [ "$quiet" = "false" ] && log warn "  - But settings.ini has network_mode=\"${network_mode}\""
    [ "$quiet" = "false" ] && log warn "  - Will use full root privileges to support TUN inbound"
    [ "$quiet" = "false" ] && log warn "  - iptables rules will be configured for ${network_mode} mode"

    # 设置标志，表示需要使用完整 root 权限
    export REQUIRE_ROOT_FOR_TUN="true"
  fi

  # 检查是否设置了对应的端口
  if [ "$network_mode" = "tproxy" ] && [ -z "$tproxy_port" ]; then
    [ "$quiet" = "false" ] && log warn "network_mode is tproxy but no tproxy inbound found in config.json"
  elif [ "$network_mode" = "redirect" ] && [ -z "$redir_port" ]; then
    [ "$quiet" = "false" ] && log warn "network_mode is redirect but no redirect inbound found in config.json"
  elif [ "$network_mode" = "tun" ] && [ -z "$tun_device" ]; then
    [ "$quiet" = "false" ] && log warn "network_mode is tun but no tun inbound found in config.json"
  fi

  return 0
}

# -------------------- 检查 sing-box 配置 --------------------
validate_singbox_config() {
  if [ ! -f "${BIN_PATH}" ]; then
    log error "Cannot find ${BIN_PATH}"
    return 1
  fi

  log info "Validating sing-box configuration"

  if ! check_executable "${BIN_PATH}"; then
    return 1
  fi

  # 使用 sing-box check 验证配置
  if ${BIN_PATH} check -D "${BOX_DIR}/" -C "${BOX_DIR}" >/dev/null 2>&1; then
    log info "Configuration validation successful"
    return 0
  else
    log error "Configuration validation failed"
    ${BIN_PATH} check -D "${BOX_DIR}/" -C "${BOX_DIR}" 2>&1 | while read -r line; do
      log error "  $line"
    done
    return 1
  fi
}

# -------------------- 检查 busybox 版本 --------------------
check_busybox_version() {
  local quiet="${1:-false}"
  local busybox_code=$(busybox | busybox grep -oE '[0-9.]*' | head -n 1 2>/dev/null)

  if [ -n "$busybox_code" ]; then
    local current_version=$(echo "$busybox_code" | awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')
    local required_version=$(echo "1.36.1" | awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')

    [ "$quiet" = "false" ] && log info "Busybox version: ${busybox_code}"

    if [ "$current_version" -lt "$required_version" ]; then
      log warn "Busybox version is outdated. Please update to v1.36.1+"
      return 1
    fi
  else
    log warn "Unable to determine busybox version"
    return 1
  fi

  return 0
}

# -------------------- 显示配置摘要 --------------------
show_config_summary() {
  local quiet="${1:-false}"

  [ "$quiet" = "true" ] && return 0

  log info "==== Configuration Summary ===="
  log info "Network mode: ${network_mode}"
  log info "IPv6: ${ipv6}"
  [ -n "$tun_device" ] && log info "TUN device: ${tun_device}"
  [ -n "$stack" ] && log info "Stack: ${stack}"
  [ -n "$tproxy_port" ] && log info "TPROXY port: ${tproxy_port}"
  [ -n "$redir_port" ] && log info "Redirect port: ${redir_port}"
  [ -n "$inet4_range" ] && log info "IPv4 FakeIP range: ${inet4_range}"
  [ -n "$inet6_range" ] && log info "IPv6 FakeIP range: ${inet6_range}"
  log info "==============================="
}

# -------------------- 主初始化函数 --------------------
init_config() {
  local quiet="${1:-false}"

  # 如果已经初始化过，使用静默模式避免重复日志
  if [ -n "$CONFIG_INITIALIZED" ]; then
    quiet="true"
  fi

  setup_environment

  if ! validate_required_files; then
    log error "Required files validation failed"
    return 1
  fi

  load_config_json "$quiet"
  load_settings_ini "$quiet"
  build_intranet_list

  # 验证配置一致性（在显示摘要之前）
  if ! validate_config_consistency "$quiet"; then
    log error "Configuration consistency validation failed"
    return 1
  fi

  check_busybox_version "$quiet"

  show_config_summary "$quiet"

  # 标记已初始化
  export CONFIG_INITIALIZED=1

  return 0
}

# 自动初始化（如果直接执行）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  init_config
fi
