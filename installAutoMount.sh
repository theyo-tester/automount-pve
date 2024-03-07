#!/bin/bash

cp -p mount_usb_memory.sh /etc/
cp -p 99-auto-mount-sdxy.rules /etc/udev/rules.d/
cp -p usb-mount@.service /etc/systemd/system/

# we maybe need to replace some services, as they want to pull in the deprecated systemd-udev-settle
serviceToCheck="zfs-import-cache"
if systemctl is-enabled --quiet "$serviceToCheck"; then
  # Read the service file content
  service_file_content=$(systemctl cat "$serviceToCheck")
  if grep -q "^Requires=systemd-udev-settle" <<< "$service_file_content"; then
    echo "overriding ${serviceToCheck} with our unit file to avoid pulling in of systemd-udev-settle"
    cp -p ${serviceToCheck}.service /etc/systemd/system/
  fi
fi

serviceToCheck="zfs-import-scan"
if systemctl is-enabled --quiet "$serviceToCheck"; then
  # Read the service file content
  service_file_content=$(systemctl cat "$serviceToCheck")
  #check if it is dependend of the systemd-udev-settle.
  if grep -q "^Requires=systemd-udev-settle" <<< "$service_file_content"; then
    echo "overriding ${serviceToCheck} with our unit file to avoid pulling in of systemd-udev-settle"
    cp -p ${serviceToCheck}.service /etc/systemd/system/
  fi
fi

if systemctl is-enabled --quiet systemd-udev-settle; then
  # if we don't mask it, it will screw up everything at boot (most probably because we use LVM in pve). It is deprecated anyway.
  systemctl mask systemd-udev-settle
fi

systemctl daemon-reload

udevadm control --reload-rules
