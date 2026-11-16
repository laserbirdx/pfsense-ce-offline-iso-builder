#!/bin/sh
# Runs INSIDE the VM: converts a finished memstick image to the serial console
# variant by editing loader.conf and boot.config on its UFS root.
set -e
DISK="${1:-vtbd0}"
mkdir -p /tmp/dst
mount "/dev/${DISK}s2a" /tmp/dst
cat >> /tmp/dst/boot/loader.conf <<'EOT'

# Serial console variant
boot_serial="YES"
console="comconsole,vidconsole"
comconsole_speed="115200"
hint.uart.0.flags="0x10"
EOT
printf -- '-S115200 -h' > /tmp/dst/boot.config
umount /tmp/dst
sync
echo "### SERIAL-OK"
