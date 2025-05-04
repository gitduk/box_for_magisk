#!/system/bin/sh

# 设置错误处理
set -e

iptables="iptables -w 64"

# 设备特定的规则清理
cleanup_device_rules() {
  # 红魔9Pro
  $iptables -D oem_out -j zte_fw_data_align_out 2>/dev/null
  $iptables -D OUTPUT -j zte_fw_gms 2>/dev/null

  # 小米设备
  $iptables -D OUTPUT -j miui_firewall 2>/dev/null
  $iptables -D FORWARD -j miui_firewall 2>/dev/null

  # OPPO/Realme 设备
  $iptables -D OUTPUT -j oppo_firewall 2>/dev/null
  $iptables -D FORWARD -j oppo_firewall 2>/dev/null

  # Vivo 设备
  $iptables -D OUTPUT -j vivo_firewall 2>/dev/null
  $iptables -D FORWARD -j vivo_firewall 2>/dev/null

  # 华为设备
  $iptables -D OUTPUT -j huawei_firewall 2>/dev/null
  $iptables -D FORWARD -j huawei_firewall 2>/dev/null

  # 通用规则
  $iptables -D OUTPUT -j oem_out 2>/dev/null
  $iptables -D FORWARD -j oem_fwd 2>/dev/null
}

# 执行清理
cleanup_device_rules
