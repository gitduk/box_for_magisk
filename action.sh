#!/system/bin/sh

box_dir=/data/adb/singbox
box_pid="${box_dir}/.box.pid"

if [ -f "${box_pid}" ]; then
    su -c $box_dir/scripts/service.sh stop
else
    su -c $box_dir/scripts/service.sh start
fi
