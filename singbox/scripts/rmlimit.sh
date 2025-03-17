#!/system/bin/sh

iptables="iptables -w 64"

# 红魔9Pro
${iptables} -D oem_out -j zte_fw_data_align_out 2>/dev/null
${iptables} -D OUTPUT -j zte_fw_gms 2>/dev/null

