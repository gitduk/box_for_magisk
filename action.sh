#!/system/bin/sh

box_dir=/data/adb/singbox

if busybox pidof "sing-box" &>/dev/null; then
  su -c $box_dir/scripts/service.sh stop
else
  su -c $box_dir/scripts/service.sh start
fi
