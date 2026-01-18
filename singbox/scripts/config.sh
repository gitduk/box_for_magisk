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

  # 检查 config.json
  if [ ! -f "${CONFIG_JSON}" ]; then
    log error "Cannot find ${CONFIG_JSON}"
    missing_files=$((missing_files + 1))
  fi

  # 检查 settings.ini
  if [ ! -f "${SETTINGS_INI}" ]; then
    log error "Cannot find ${SETTINGS_INI}"
    missing_files=$((missing_files + 1))
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
