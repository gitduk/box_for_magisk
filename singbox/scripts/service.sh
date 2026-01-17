#!/system/bin/sh

# ============================================================
# SingBox 服务管理脚本
# 提供启动、停止、重启和状态检查功能
# ============================================================

# 加载依赖
source "${0%/*}/constants.sh"
source "${0%/*}/utils.sh"
source "${0%/*}/config.sh"

# -------------------- 修复权限 --------------------
fix_permissions() {
  # 修复二进制文件权限
  if [ -f "${BIN_PATH}" ]; then
    chmod 755 "${BIN_PATH}" 2>/dev/null || true
    chown "${BOX_USER_GROUP}" "${BIN_PATH}" 2>/dev/null || true
  fi

  if [ -f "${JQ_PATH}" ]; then
    chmod 755 "${JQ_PATH}" 2>/dev/null || true
  fi

  # 修复脚本权限
  chmod 755 "${BOX_DIR}/scripts"/*.sh 2>/dev/null || true

  # 修复目录权限
  chown -R "${BOX_USER_GROUP}" "${BOX_DIR}" 2>/dev/null || true
  chmod 755 "${BOX_DIR}" 2>/dev/null || true
  chmod 755 "${BOX_DIR}/bin" 2>/dev/null || true
  chmod 755 "${BOX_DIR}/scripts" 2>/dev/null || true
}

# -------------------- 初始化环境 --------------------
init_environment() {
  # 创建必要的目录
  safe_mkdir "${LOG_DIR}" 0755
  safe_mkdir "$(dirname "${BIN_PATH}")" 0755

  # 修复权限（每次启动时自动修复）
  fix_permissions

  # 日志轮转
  rotate_log "${RUN_LOG}"
  rotate_log "${BOX_LOG}"
}

# -------------------- 检查系统要求 --------------------
check_system_requirements() {
  log info "Checking system requirements"

  # 检查 root 权限
  check_root || return 1

  # 检查 sing-box 二进制文件
  if ! check_executable "${BIN_PATH}"; then
    log error "Cannot find or execute ${BIN_PATH}"
    return 1
  fi

  # 检查网络模式配置
  if [ -z "${network_mode}" ]; then
    log error "network_mode is not set"
    return 1
  fi

  # 检查并创建 TUN 设备
  if [ -n "${tun_device}" ] && [ "${network_mode}" = "tun" ]; then
    safe_mkdir /dev/net 0755
    [ ! -L /dev/net/tun ] && ln -s /dev/tun /dev/net/tun 2>/dev/null

    if [ ! -c "/dev/net/tun" ]; then
      log error "Cannot create /dev/net/tun"
      log warn "System may not support TUN/TAP driver or kernel incompatibility"
      log info "Falling back to tproxy mode"

      # 持久化降级决策
      sed -i 's/network_mode=.*/network_mode="tproxy"/g' "${SETTINGS_INI}"
      network_mode="tproxy"
      export network_mode
      return 1
    fi
  fi

  # 检查磁盘空间
  if ! check_disk_space "${BOX_DIR}" 50; then
    log warn "Low disk space in ${BOX_DIR}"
  fi

  # 检查 busybox 版本
  check_busybox_version

  return 0
}

# -------------------- 设置 IPv6 --------------------
setup_ipv6() {
  # 基础网络设置
  sysctl -w net.ipv4.ip_forward=1 &>/dev/null

  if [ "${ipv6}" = "true" ]; then
    log info "Enabling IPv6"

    # 启用 IPv6 设置
    sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=2 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=0 &>/dev/null

    # 删除 IPv6 阻断规则
    ip -6 rule del unreachable pref "${ROUTE_PREF}" 2>/dev/null || true
  else
    log info "Disabling IPv6"

    # 禁用 IPv6 设置
    sysctl -w net.ipv6.conf.all.forwarding=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.accept_ra=0 &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.wlan0.disable_ipv6=1 &>/dev/null

    # 添加 IPv6 阻断规则
    ip -6 rule add unreachable pref "${ROUTE_PREF}" 2>/dev/null || true
  fi
}

# -------------------- 配置系统参数 --------------------
configure_system_parameters() {
  log info "Configuring system parameters"

  # 设置文件描述符限制
  ulimit -SHn "${FILE_DESCRIPTOR_LIMIT}"

  # 网络优化参数
  sysctl -w net.core.rmem_max=16777216 &>/dev/null
  sysctl -w net.core.wmem_max=16777216 &>/dev/null
  sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" &>/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 87380 16777216" &>/dev/null
}

# -------------------- 启动服务 --------------------
start_box() {
  log info "Starting ${BIN_NAME} service"

  # 检查是否已经在运行
  if busybox pidof "${BIN_NAME}" >/dev/null 2>&1; then
    log warn "${BIN_NAME} is already running"
    return 1
  fi

  # 验证配置文件
  log info "Validating configuration"
  if ! ${BIN_PATH} check -D "${BOX_DIR}/" -C "${BOX_DIR}" > "${BOX_LOG}" 2>&1; then
    log error "Configuration validation failed:"
    cat "${BOX_LOG}" | while read -r line; do
      log error "  $line"
    done
    return 1
  fi

  # 配置系统参数
  configure_system_parameters

  # 启动服务
  log info "Launching ${BIN_NAME} process"
  nohup busybox setuidgid "${BOX_USER_GROUP}" "${BIN_PATH}" run \
    -D "${BOX_DIR}" \
    -C "${BOX_DIR}" \
    >> "${BOX_LOG}" 2>&1 &

  # 等待进程启动
  sleep "${STARTUP_WAIT}"

  # 检查进程状态
  if check_process_running "${BIN_NAME}"; then
    local pid=$(busybox pidof "${BIN_NAME}")
    log INFO "${BIN_NAME} started successfully (PID: ${pid})"
  else
    log ERROR "${BIN_NAME} failed to start"
    log error "Last log entries:"
    tail -20 "${BOX_LOG}" | while read -r line; do
      log error "  $line"
    done
    safe_kill "${BIN_NAME}" 15
    return 1
  fi

  # 设置 iptables 规则
  log info "Setting up iptables rules for ${network_mode} mode"
  if ! ${0%/*}/iptables.sh "${network_mode}"; then
    log error "Failed to setup iptables rules"
    safe_kill "${BIN_NAME}" 15
    return 1
  fi

  # 配置 IPv6
  setup_ipv6

  log INFO "module started successfully"
  return 0
}

# -------------------- 停止服务 --------------------
stop_box() {
  local force_kill=${1:-false}

  log info "Stopping ${BIN_NAME} service"

  # 检查进程是否在运行
  if ! busybox pidof "${BIN_NAME}" >/dev/null 2>&1; then
    log warn "${BIN_NAME} is not running"
    # 清理 iptables 规则
    ${0%/*}/iptables.sh "clear" 2>/dev/null || true
    return 0
  fi

  # 清理 iptables 规则
  log info "Cleaning up iptables rules"
  ${0%/*}/iptables.sh "clear" 2>/dev/null || true

  # 温和停止
  if ! safe_kill "${BIN_NAME}" 15; then
    log warn "${BIN_NAME} process not found"
    return 0
  fi

  # 等待进程退出
  sleep "${SHUTDOWN_WAIT}"

  # 检查是否需要强制停止
  if busybox pidof "${BIN_NAME}" >/dev/null 2>&1; then
    if [ "$force_kill" = true ] || [ "$1" = "-f" ]; then
      force_kill "${BIN_NAME}"
    else
      log WARN "${BIN_NAME} is still running, may be shutting down"
      log info "Use 'force-stop' to forcefully terminate the process"
      return 1
    fi
  fi

  log INFO "${BIN_NAME} service stopped"
  return 0
}

# -------------------- 重启服务 --------------------
restart_box() {
  log info "Restarting ${BIN_NAME} service"

  # 停止服务
  stop_box

  # 等待清理完成
  sleep 1

  # 重新加载配置
  if ! init_config; then
    log error "Failed to reload configuration"
    return 1
  fi

  # 检查系统要求
  if ! check_system_requirements; then
    log error "System requirements check failed"
    return 1
  fi

  # 启动服务
  start_box
}

# -------------------- 服务状态 --------------------
status_box() {
  local pid

  if pid=$(busybox pidof "${BIN_NAME}" 2>/dev/null); then
    log info "${BIN_NAME} is running (PID: ${pid})"

    # 显示运行时长
    if [ -d "/proc/${pid}" ]; then
      local uptime=$(ps -p "${pid}" -o etime= 2>/dev/null | tr -d ' ')
      [ -n "$uptime" ] && log info "Uptime: ${uptime}"
    fi

    # 显示内存使用
    local mem=$(ps -p "${pid}" -o rss= 2>/dev/null | tr -d ' ')
    if [ -n "$mem" ]; then
      local mem_mb=$((mem / 1024))
      log info "Memory usage: ${mem_mb} MB"
    fi

    # 显示网络模式
    log info "Network mode: ${network_mode}"

    # 检查配置文件
    if [ -f "${CONFIG_JSON}" ]; then
      log info "Config file: ${CONFIG_JSON}"
    fi

    # 显示最近的日志
    if [ -f "${BOX_LOG}" ]; then
      log info "Recent log entries:"
      tail -5 "${BOX_LOG}" | while read -r line; do
        echo "  $line"
      done
    fi

    return 0
  else
    log warn "${BIN_NAME} is not running"
    return 1
  fi
}

# -------------------- 健康检查 --------------------
health_check() {
  log info "Performing health check"

  # 检查进程
  if ! busybox pidof "${BIN_NAME}" >/dev/null 2>&1; then
    log error "Health check failed: process not running"
    return 1
  fi

  # 检查配置文件
  if [ ! -f "${CONFIG_JSON}" ]; then
    log error "Health check failed: config file not found"
    return 1
  fi

  # 检查日志文件
  if [ ! -f "${BOX_LOG}" ]; then
    log warn "Health check warning: log file not found"
  fi

  # 检查最近的错误
  if [ -f "${BOX_LOG}" ]; then
    local error_count=$(grep -c "ERROR" "${BOX_LOG}" 2>/dev/null | tail -100 || echo 0)
    if [ "$error_count" -gt 10 ]; then
      log warn "Health check warning: ${error_count} errors in recent logs"
    fi
  fi

  # 检查网络连接（如果有 curl）
  if command_exists curl; then
    if curl -s --max-time 5 --connect-timeout 3 http://www.google.com > /dev/null 2>&1; then
      log info "Health check: network connectivity OK"
    else
      log warn "Health check warning: network connectivity test failed"
    fi
  fi

  log info "Health check completed"
  return 0
}

# -------------------- 主程序入口 --------------------
main() {
  # 初始化环境
  init_environment

  # 执行命令
  case "$1" in
    start)
      # 加载配置
      init_config || exit 1

      # 检查系统要求
      check_system_requirements || exit 1

      # 启动服务
      start_box
      ;;
    stop)
      stop_box "$2"
      ;;
    restart)
      restart_box
      ;;
    force-stop)
      stop_box -f
      ;;
    status)
      # 加载配置（不验证）
      setup_environment
      load_settings_ini

      status_box
      exit $?
      ;;
    health)
      # 加载配置（不验证）
      setup_environment
      load_settings_ini

      health_check
      exit $?
      ;;
    *)
      echo "Usage: $0 {start|stop|restart|force-stop|status|health}"
      echo ""
      echo "Commands:"
      echo "  start       - Start the sing-box service"
      echo "  stop        - Stop the sing-box service gracefully"
      echo "  restart     - Restart the sing-box service"
      echo "  force-stop  - Force stop the sing-box service"
      echo "  status      - Show service status"
      echo "  health      - Perform health check"
      exit 1
      ;;
  esac
}

# 执行主程序
main "$@"
