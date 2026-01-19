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
  # 修复二进制文件权限（必须可执行）
  if [ -f "${BIN_PATH}" ]; then
    chmod 755 "${BIN_PATH}" 2>/dev/null || log warn "Failed to chmod sing-box binary"
    chown "${BOX_USER_GROUP}" "${BIN_PATH}" 2>/dev/null || true

    # 验证权限是否设置成功
    if [ ! -x "${BIN_PATH}" ]; then
      log error "sing-box binary is not executable after chmod"
      log error "Current permissions: $(ls -l ${BIN_PATH})"
    fi

    # 设置 Linux capabilities（用于 TUN 设备访问）
    # 这允许在使用 setuidgid 降低权限后仍然能创建 TUN 设备
    if [ -n "${tun_device}" ]; then
      if command_exists setcap; then
        log info "Setting capabilities for sing-box binary"
        setcap 'cap_net_admin,cap_net_raw,cap_net_bind_service+ep' "${BIN_PATH}" 2>/dev/null && \
          log info "Capabilities set successfully" || \
          log warn "Failed to set capabilities (may need to run as full root for TUN)"
      else
        log warn "setcap not found, TUN mode will require full root privileges"
      fi
    fi
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
  # 只要 config.json 中配置了 TUN inbound，就需要准备 TUN 设备
  if [ -n "${tun_device}" ]; then
    log info "Preparing TUN device for sing-box"

    # 创建 /dev/net 目录
    safe_mkdir /dev/net 0755

    # 检查并创建 TUN 设备节点
    if [ ! -c "/dev/tun" ]; then
      # 尝试创建 TUN 设备节点
      log warn "/dev/tun not found, trying to create it"
      mknod /dev/tun c 10 200 2>/dev/null || log warn "Failed to create /dev/tun"
    fi

    # 创建符号链接
    if [ -L /dev/net/tun ]; then
      rm -f /dev/net/tun 2>/dev/null
    fi
    ln -sf /dev/tun /dev/net/tun 2>/dev/null

    # 验证设备是否可用
    if [ ! -c "/dev/net/tun" ] && [ ! -c "/dev/tun" ]; then
      log error "Cannot create TUN device"
      log warn "System may not support TUN/TAP driver or kernel incompatibility"
      log info "Falling back to tproxy mode"
      sed -i 's/network_mode=.*/network_mode="tproxy"/g' "${SETTINGS_INI}"
      network_mode="tproxy"
      export network_mode
      return 1
    fi

    # 设置 TUN 设备权限（多种尝试）
    log info "Setting TUN device permissions"
    chmod 0666 /dev/tun 2>/dev/null || log warn "Failed to chmod /dev/tun"
    chmod 0666 /dev/net/tun 2>/dev/null || log warn "Failed to chmod /dev/net/tun"

    # 设置所有权
    chown root:root /dev/tun 2>/dev/null || true
    chown root:root /dev/net/tun 2>/dev/null || true

    # 显示设备状态
    log info "TUN device status:"
    ls -lZ /dev/tun /dev/net/tun 2>&1 | while read -r line; do
      log info "  $line"
    done

    # 尝试多种 SELinux 上下文
    if command_exists chcon; then
      log info "Setting SELinux context for TUN device"
      chcon u:object_r:tun_device:s0 /dev/tun 2>/dev/null || \
      chcon u:object_r:device:s0 /dev/tun 2>/dev/null || \
      true

      chcon u:object_r:tun_device:s0 /dev/net/tun 2>/dev/null || \
      chcon u:object_r:device:s0 /dev/net/tun 2>/dev/null || \
      true
    fi

    # 处理 SELinux
    if command_exists setenforce; then
      current_selinux=$(getenforce 2>/dev/null)
      log info "SELinux status: ${current_selinux}"
      if [ "$current_selinux" = "Enforcing" ]; then
        log warn "SELinux is enforcing, attempting to fix contexts"

        # 设置 sing-box 二进制的 SELinux context
        if command_exists chcon; then
          log info "Setting SELinux context for sing-box binary"
          # 尝试多种可能的 context
          chcon u:object_r:system_file:s0 "${BIN_PATH}" 2>/dev/null || \
          chcon u:object_r:executable_file:s0 "${BIN_PATH}" 2>/dev/null || \
          restorecon "${BIN_PATH}" 2>/dev/null || \
          true

          # 显示当前 context
          ls -Z "${BIN_PATH}" | while read -r line; do
            log info "  sing-box context: $line"
          done
        fi

        # 如果仍然是 Enforcing，建议用户禁用
        log warn "If TUN still fails, try: setenforce 0"
        log warn "To make it permanent, add 'SELINUX=permissive' to /system/etc/selinux/config"
      fi
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

  # 清理可能残留的 iptables 规则和路由，确保干净的启动环境
  log info "Cleaning up any existing rules before start"
  ${0%/*}/iptables.sh "clear" >/dev/null 2>&1 || true

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

  # TUN 模式下处理 SELinux（如果需要）
  if [ -n "${tun_device}" ] && command_exists getenforce; then
    current_selinux=$(getenforce 2>/dev/null)
    if [ "$current_selinux" = "Enforcing" ]; then
      log warn "SELinux is Enforcing, TUN mode may fail"
      log warn "Attempting to set Permissive mode temporarily"

      # 尝试临时设置为 Permissive
      if setenforce 0 2>/dev/null; then
        log info "SELinux set to Permissive mode for TUN operation"
        log info "Will restore to Enforcing after service starts"
        export SELINUX_WAS_ENFORCING="true"
      else
        log error "Failed to set SELinux to Permissive"
        log error "You may need to manually run: setenforce 0"
      fi
    fi
  fi

  # 启动服务
  log info "Launching ${BIN_NAME} process"

  # 决定启动方式
  # 策略：
  # 1. 优先使用 setuidgid + capabilities（更安全）
  # 2. 如果 setcap 失败，TUN 模式使用完整 root
  # 3. 其他模式总是使用 setuidgid

  local use_full_root=false

  # 检查是否需要 TUN 支持
  if [ "${network_mode}" = "tun" ] || [ "${REQUIRE_ROOT_FOR_TUN}" = "true" ]; then
    # 检查是否成功设置了 capabilities
    if command_exists getcap && getcap "${BIN_PATH}" 2>/dev/null | grep -q "cap_net_admin"; then
      log info "Capabilities detected, using setuidgid with enhanced privileges"
      log info "Starting sing-box as ${BOX_USER_GROUP} with capabilities"
      nohup busybox setuidgid "${BOX_USER_GROUP}" "${BIN_PATH}" run \
        -D "${BOX_DIR}" \
        -C "${BOX_DIR}" \
        >> "${BOX_LOG}" 2>&1 &
    else
      # Capabilities 未设置，使用完整 root
      log warn "Capabilities not set, falling back to full root privileges"
      use_full_root=true
    fi
  fi

  # 使用完整 root 权限（仅在必要时）
  if [ "$use_full_root" = "true" ]; then
    if [ "$(id -u)" -ne 0 ]; then
      log error "Not running as root, cannot start TUN mode"
      return 1
    fi

    log info "Starting sing-box with full root privileges (UID=0 GID=0)"
    nohup sh -c "cd ${BOX_DIR} && exec ${BIN_PATH} run -D ${BOX_DIR} -C ${BOX_DIR}" \
      >> "${BOX_LOG}" 2>&1 &

  # 普通模式（无 TUN）
  elif [ "$use_full_root" = "false" ] && [ -z "${REQUIRE_ROOT_FOR_TUN}" ]; then
    log info "Starting sing-box as ${BOX_USER_GROUP}"
    nohup busybox setuidgid "${BOX_USER_GROUP}" "${BIN_PATH}" run \
      -D "${BOX_DIR}" \
      -C "${BOX_DIR}" \
      >> "${BOX_LOG}" 2>&1 &
  fi

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

  log INFO "${BIN_NAME} started successfully"
  return 0
}

# -------------------- 停止服务 --------------------
stop_box() {
  local force_kill=${1:-false}

  log info "Stopping ${BIN_NAME} service"

  # 检查进程是否在运行（尝试多种方式）
  local pid=$(busybox pidof "${BIN_NAME}" 2>/dev/null || pidof "${BIN_NAME}" 2>/dev/null || ps | grep "${BIN_NAME}" | grep -v grep | awk '{print $1}' | head -1)

  if [ -z "$pid" ]; then
    log warn "${BIN_NAME} is not running"
    # 清理 iptables 规则
    ${0%/*}/iptables.sh "clear" 2>/dev/null || true
    return 0
  fi

  log info "Found ${BIN_NAME} process (PID: $pid)"

  # 清理 iptables 规则
  log info "Cleaning up iptables rules"
  ${0%/*}/iptables.sh "clear" 2>/dev/null || true

  # 温和停止
  log info "Sending SIGTERM to ${BIN_NAME} (PID: $pid)"
  kill -15 $pid 2>/dev/null || true

  # 等待进程退出
  sleep "${SHUTDOWN_WAIT}"

  # 检查是否需要强制停止
  pid=$(busybox pidof "${BIN_NAME}" 2>/dev/null || pidof "${BIN_NAME}" 2>/dev/null || ps | grep "${BIN_NAME}" | grep -v grep | awk '{print $1}' | head -1)

  if [ -n "$pid" ]; then
    if [ "$force_kill" = true ] || [ "$1" = "-f" ]; then
      log warn "${BIN_NAME} still running, sending SIGKILL"
      kill -9 $pid 2>/dev/null || true
      sleep 1
    else
      log warn "${BIN_NAME} is still running (PID: $pid), may be shutting down"
      log info "Use 'force-stop' to forcefully terminate the process"
      return 1
    fi
  fi

  log info "${BIN_NAME} service stopped"
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
