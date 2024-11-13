#!/system/bin/sh

SKIPUNZIP=1
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

if [ "$BOOTMODE" != "true" ]; then
  ui_print "! Please install in Magisk/KernelSU/APatch Manager"
  ui_print "! Install from recovery is NOT supported"
  abort "-----------------------------------------------------------"
elif [ "$KSU" = "true" ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  ui_print "! Please update your KernelSU and KernelSU Manager"
  abort "-----------------------------------------------------------"
fi

service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ]; then
  ui_print "- kernelSU version: $KSU_VER ($KSU_VER_CODE)"
  [ "$KSU_VER_CODE" -lt 10683 ] && service_dir="/data/adb/ksu/service.d"
elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "- APatch version: $APATCH_VER"
else
  ui_print "- Magisk version: $MAGISK_VER ($MAGISK_VER_CODE)"
fi

mkdir -p "${service_dir}"

# install module to /data/adb/modules/singbox
module_dir="/data/adb/modules/singbox"
if [ -d "${module_dir}" ]; then
  rm -rf "${module_dir}"
  ui_print "- Old module deleted."
fi

ui_print "- Installing SingBox for Magisk/KernelSU/APatch"
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# install singbox to /data/adb/singbox
if [ -d "/data/adb/singbox" ]; then
  ui_print "- Remove old singbox"
  rm -rf "/data/adb/singbox"
fi
mv "$MODPATH/singbox" /data/adb/

# install singbox_service.sh
ui_print "- Move service.sh to service dir"
mv -f "$MODPATH/service.sh" "${service_dir}/singbox_service.sh"

# set permissions
ui_print "- Setting permissions"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive /data/adb/singbox/ 0 3005 0755 0644
set_perm_recursive /data/adb/singbox/scripts/  0 3005 0755 0700
set_perm ${service_dir}/singbox_service.sh  0  0  0755
set_perm $MODPATH/uninstall.sh  0  0  0755
set_perm /data/adb/singbox/scripts/  0  0  0755

# fix "set_perm_recursive /data/adb/box/scripts" not working on some phones.
chmod ugo+x ${service_dir}/singbox_service.sh
chmod ugo+x $MODPATH/uninstall.sh
chmod ugo+x /data/adb/singbox/scripts/*

if [ -z "$(find /data/adb/singbox/bin -type f)" ]; then
  sed -Ei 's/^description=(\[.*][[:space:]]*)?/description=[ 😱 Module installed but you need to download sing-box Kernel manually ] /g' $MODPATH/module.prop
fi

if [ "$KSU" = "true" ]; then
  sed -i "s/name=.*/name=SingBox for KernelSU/g" $MODPATH/module.prop
  unzip -o "$ZIPFILE" -d "$MODPATH" >&2
elif [ "$APATCH" = "true" ]; then
  sed -i "s/name=.*/name=SingBox for APatch/g" $MODPATH/module.prop
  unzip -o "$ZIPFILE" -d "$MODPATH" >&2
else
  sed -i "s/name=.*/name=SingBox for Magisk/g" $MODPATH/module.prop
fi

ui_print "- Installation is complete"
ui_print "- Please put config.json to /data/adb/singbox/ and reboot your device"
