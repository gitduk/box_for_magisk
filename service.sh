#!/system/bin/sh

[ -f "/data/adb/modules/box_for_magisk/disable" ] && exit 0

(
  until [ $(getprop init.svc.bootanim) = "stopped" ]; do
    sleep 5
  done

  for i in $(seq 1 10); do
    if ip route | grep -q default; then
      break
    fi
    sleep 0.5
  done

  if [ -f "/data/adb/singbox/scripts/service.sh" ]; then
    chmod 755 /data/adb/singbox/scripts/*
    /data/adb/singbox/scripts/service.sh start
  else
    echo "File '/data/adb/singbox/scripts/service.sh' not found"
  fi
)&
