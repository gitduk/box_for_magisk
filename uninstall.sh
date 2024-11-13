#!/system/bin/sh

singbox_data_dir="/data/adb/singbox"

if [ -f "/data/adb/ksu/service.d/singbox_service.sh" ]; then
  rm -rf "/data/adb/ksu/service.d/singbox_service.sh"
fi

if [ -f "/data/adb/service.d/singbox_service.sh" ]; then
  rm -rf "/data/adb/service.d/singbox_service.sh"
fi

if [ ! -d "${singbox_data_dir}" ]; then
  exit 1
else
  rm -rf "${singbox_data_dir}"
fi
