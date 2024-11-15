#!/system/bin/sh

box_dir=/data/adb/singbox
box_pid="${box_dir}/.box.pid"

if [ -f "${box_pid}" ]; then
    echo "Service is shutting down"
    su -c $box_dir/scripts/service.sh stop
else
    echo "Service is starting,please wait for a moment"
    su -c $box_dir/scripts/service.sh start
    exit
fi
