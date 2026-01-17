#!/system/bin/sh

# ============================================================
# 快速诊断脚本
# 帮助排查常见问题
# ============================================================

echo "========================================"
echo "SingBox 快速诊断"
echo "========================================"
echo ""

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOX_DIR="/data/adb/singbox"

echo "1. 检查文件完整性"
echo "-------------------"
for file in constants.sh utils.sh config.sh service.sh iptables.sh; do
  if [ -f "${SCRIPT_DIR}/${file}" ]; then
    echo -e "${GREEN}✓${NC} ${file} 存在"
  else
    echo -e "${RED}✗${NC} ${file} 缺失"
  fi
done
echo ""

echo "2. 检查关键配置文件"
echo "-------------------"
if [ -f "${BOX_DIR}/config.json" ]; then
  echo -e "${GREEN}✓${NC} config.json 存在"
  # 验证 JSON 格式
  if ${BOX_DIR}/bin/jq . "${BOX_DIR}/config.json" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} config.json 格式正确"
  else
    echo -e "${RED}✗${NC} config.json 格式错误"
  fi
else
  echo -e "${RED}✗${NC} config.json 不存在"
fi

if [ -f "${BOX_DIR}/settings.ini" ]; then
  echo -e "${GREEN}✓${NC} settings.ini 存在"
else
  echo -e "${RED}✗${NC} settings.ini 不存在"
fi
echo ""

echo "3. 检查二进制文件"
echo "-------------------"
if [ -f "${BOX_DIR}/bin/sing-box" ]; then
  echo -e "${GREEN}✓${NC} sing-box 存在"
  if [ -x "${BOX_DIR}/bin/sing-box" ]; then
    echo -e "${GREEN}✓${NC} sing-box 可执行"
  else
    echo -e "${RED}✗${NC} sing-box 不可执行"
  fi
else
  echo -e "${RED}✗${NC} sing-box 不存在"
fi

if [ -f "${BOX_DIR}/bin/jq" ]; then
  echo -e "${GREEN}✓${NC} jq 存在"
  if [ -x "${BOX_DIR}/bin/jq" ]; then
    echo -e "${GREEN}✓${NC} jq 可执行"
  else
    echo -e "${RED}✗${NC} jq 不可执行"
  fi
else
  echo -e "${RED}✗${NC} jq 不存在"
fi
echo ""

echo "4. 测试配置读取"
echo "-------------------"
if [ -f "${BOX_DIR}/bin/jq" ] && [ -f "${BOX_DIR}/config.json" ]; then
  echo "读取 tproxy 端口:"
  tproxy_port=$(${BOX_DIR}/bin/jq -r '.inbounds[] | select(.type == "tproxy") | .listen_port // empty' "${BOX_DIR}/config.json" 2>&1)
  if [ -n "$tproxy_port" ]; then
    echo -e "${GREEN}✓${NC} tproxy_port = ${tproxy_port}"
  else
    echo -e "${YELLOW}⚠${NC} tproxy_port 未配置或为空"
  fi

  echo "读取 redirect 端口:"
  redir_port=$(${BOX_DIR}/bin/jq -r '.inbounds[] | select(.type == "redirect") | .listen_port // empty' "${BOX_DIR}/config.json" 2>&1)
  if [ -n "$redir_port" ]; then
    echo -e "${GREEN}✓${NC} redir_port = ${redir_port}"
  else
    echo -e "${YELLOW}⚠${NC} redir_port 未配置或为空"
  fi

  echo "读取 TUN 设备:"
  tun_device=$(${BOX_DIR}/bin/jq -r '.inbounds[] | select(.type == "tun") | .interface_name // empty' "${BOX_DIR}/config.json" 2>&1)
  if [ -n "$tun_device" ]; then
    echo -e "${GREEN}✓${NC} tun_device = ${tun_device}"
  else
    echo -e "${YELLOW}⚠${NC} tun_device 未配置或为空"
  fi
fi
echo ""

echo "5. 检查进程状态"
echo "-------------------"
if busybox pidof sing-box >/dev/null 2>&1; then
  pid=$(busybox pidof sing-box)
  echo -e "${GREEN}✓${NC} sing-box 正在运行 (PID: ${pid})"

  # 内存使用
  mem=$(ps -p "${pid}" -o rss= 2>/dev/null | tr -d ' ')
  if [ -n "$mem" ]; then
    mem_mb=$((mem / 1024))
    echo "  内存使用: ${mem_mb} MB"
  fi

  # 运行时长
  uptime=$(ps -p "${pid}" -o etime= 2>/dev/null | tr -d ' ')
  if [ -n "$uptime" ]; then
    echo "  运行时长: ${uptime}"
  fi
else
  echo -e "${RED}✗${NC} sing-box 未运行"
fi
echo ""

echo "6. 检查网络配置"
echo "-------------------"
if [ -f "${BOX_DIR}/settings.ini" ]; then
  network_mode=$(grep '^network_mode=' "${BOX_DIR}/settings.ini" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  if [ -n "$network_mode" ]; then
    echo -e "${GREEN}✓${NC} network_mode = ${network_mode}"
  else
    echo -e "${YELLOW}⚠${NC} network_mode 未配置"
  fi

  ipv6=$(grep '^ipv6=' "${BOX_DIR}/settings.ini" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  if [ -n "$ipv6" ]; then
    echo -e "${GREEN}✓${NC} ipv6 = ${ipv6}"
  else
    echo -e "${YELLOW}⚠${NC} ipv6 未配置"
  fi
fi
echo ""

echo "7. 检查 iptables 规则"
echo "-------------------"
if iptables -t mangle -L BOX_EXTERNAL -n >/dev/null 2>&1; then
  rule_count=$(iptables -t mangle -L BOX_EXTERNAL -n 2>/dev/null | wc -l)
  echo -e "${GREEN}✓${NC} iptables 规则已配置 (${rule_count} 行)"
else
  echo -e "${YELLOW}⚠${NC} iptables 规则未配置"
fi
echo ""

echo "8. 检查路由规则"
echo "-------------------"
if ip rule list | grep -q "fwmark 0x1000000/0x1000000"; then
  echo -e "${GREEN}✓${NC} 策略路由已配置"
else
  echo -e "${YELLOW}⚠${NC} 策略路由未配置"
fi

if ip route show table 2024 | grep -q "local default"; then
  echo -e "${GREEN}✓${NC} 路由表 2024 已配置"
else
  echo -e "${YELLOW}⚠${NC} 路由表 2024 未配置"
fi
echo ""

echo "9. 检查日志文件"
echo "-------------------"
if [ -f "${BOX_DIR}/logs/box.log" ]; then
  log_size=$(stat -c%s "${BOX_DIR}/logs/box.log" 2>/dev/null || echo 0)
  log_size_kb=$((log_size / 1024))
  echo -e "${GREEN}✓${NC} box.log 存在 (${log_size_kb} KB)"

  # 检查最近的错误
  error_count=$(grep -c "ERROR\|error\|Error" "${BOX_DIR}/logs/box.log" 2>/dev/null | tail -100 || echo 0)
  if [ "$error_count" -gt 0 ]; then
    echo -e "${YELLOW}⚠${NC} 日志中有 ${error_count} 个错误（最近 100 行）"
    echo "  最近的错误:"
    grep "ERROR\|error\|Error" "${BOX_DIR}/logs/box.log" 2>/dev/null | tail -3 | while read -r line; do
      echo "    $line"
    done
  else
    echo -e "${GREEN}✓${NC} 日志中没有错误"
  fi
else
  echo -e "${YELLOW}⚠${NC} box.log 不存在"
fi
echo ""

echo "========================================"
echo "诊断完成"
echo "========================================"
echo ""

# 给出建议
echo "建议:"
if ! busybox pidof sing-box >/dev/null 2>&1; then
  echo "- sing-box 未运行，尝试启动: ${SCRIPT_DIR}/service.sh start"
fi

if [ -f "${BOX_DIR}/logs/box.log" ]; then
  error_count=$(grep -c "ERROR" "${BOX_DIR}/logs/box.log" 2>/dev/null | tail -100 || echo 0)
  if [ "$error_count" -gt 5 ]; then
    echo "- 日志中有较多错误，查看详细日志: cat ${BOX_DIR}/logs/box.log"
  fi
fi

echo ""
echo "更多命令:"
echo "  启动服务: ${SCRIPT_DIR}/service.sh start"
echo "  停止服务: ${SCRIPT_DIR}/service.sh stop"
echo "  查看状态: ${SCRIPT_DIR}/service.sh status"
echo "  健康检查: ${SCRIPT_DIR}/service.sh health"
