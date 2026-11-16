#!/bin/sh
#
# Runs INSIDE the VM (FreeBSD). Copies the root file system of the running
# offline installer ISO into a memstick image that boots from USB with both
# BIOS and UEFI.
#
# Partition layout matches Netgate's own memstick image:
#   s1 0xef  EFI (FAT)      -> EFI/BOOT/bootx64.efi
#   s2 0xa5  FreeBSD (UFS)  -> root file system, boot1/boot2 + BSD label
#   s3 0x0b  FAT            -> a place where users can drop config.xml
#
set -e

DISK="${1:-vtbd0}"
# The installer binary validates the root label (system_get_rootfs_mount);
# it must match the label Netgate's own memstick image uses.
LABEL="pfSense_Install"
SRC=/tmp/src
DST=/tmp/dst

echo "### output disk: /dev/${DISK}"
SECTORS=$(diskinfo "/dev/${DISK}" | awk '{print $4}')
echo "### total sectors: ${SECTORS}"

EFI_SIZE=66584
FAT_SIZE=131072
# The MBR scheme must align slice starts; let gpart place them.
UFS_SIZE=$(( SECTORS - EFI_SIZE - FAT_SIZE - 8192 ))

echo "### partitioning (UFS ${UFS_SIZE} sectors)"
gpart destroy -F "${DISK}" 2>/dev/null || true
gpart create -s mbr "${DISK}"
gpart add -t '!239' -s "${EFI_SIZE}" "${DISK}"
gpart add -t freebsd -s "${UFS_SIZE}" "${DISK}"
gpart add -t '!11' -s "${FAT_SIZE}" "${DISK}"
gpart set -a active -i 2 "${DISK}"
gpart bootcode -b /boot/mbr "${DISK}"

echo "### BSD label + boot1/boot2"
# Clear a label left over from a previous attempt, or gpart says "File exists".
gpart destroy -F "${DISK}s2" 2>/dev/null || true
dd if=/dev/zero of="/dev/${DISK}s2" bs=512 count=64 2>/dev/null || true
gpart create -s bsd "${DISK}s2"
gpart add -t freebsd-ufs "${DISK}s2"
gpart bootcode -b /boot/boot "${DISK}s2"

echo "### creating UFS"
newfs -U -L "${LABEL}" "/dev/${DISK}s2a"

echo "### mounting source root"
mkdir -p "${SRC}" "${DST}"
mount_cd9660 /dev/iso9660/PFSENSE "${SRC}" 2>/dev/null || \
    mount -t cd9660 -o ro /dev/cd0 "${SRC}"
mount "/dev/${DISK}s2a" "${DST}"

# cd9660 does not keep hard links: the ~148 entries under /rescue are links to
# one crunched binary and take ~2.7 GB when copied naively. So /rescue is
# excluded here and recreated with hard links below.
echo "### copying (this takes a few minutes)"
tar -C "${SRC}" --exclude './rescue/*' -cf - . | tar -C "${DST}" -xpf -

echo "### recreating /rescue with hard links"
mkdir -p "${DST}/rescue"
cp -p "${SRC}/rescue/rescue" "${DST}/rescue/rescue"
RSZ=$(stat -f %z "${SRC}/rescue/rescue")
for f in "${SRC}"/rescue/*; do
	b=$(basename "${f}")
	[ "${b}" = "rescue" ] && continue
	if [ "$(stat -f %z "${f}")" = "${RSZ}" ]; then
		ln "${DST}/rescue/rescue" "${DST}/rescue/${b}"
	else
		cp -p "${f}" "${DST}/rescue/${b}"
	fi
done

echo "### usage:"
df -h "${DST}"

echo "### writing fstab"
printf '/dev/ufs/%s / ufs ro,noatime 1 1\n' "${LABEL}" > "${DST}/etc/fstab"

echo "### EFI partition"
newfs_msdos -F 16 -L EFISYS "/dev/${DISK}s1"
mkdir -p /tmp/efi
mount -t msdosfs "/dev/${DISK}s1" /tmp/efi
mkdir -p /tmp/efi/EFI/BOOT
cp "${SRC}/boot/loader.efi" /tmp/efi/EFI/BOOT/bootx64.efi
umount /tmp/efi

echo "### auxiliary FAT partition"
# 64 MB is too small for FAT32 (needs at least 65525 clusters) -> FAT16.
newfs_msdos -F 16 -L PFSENSE "/dev/${DISK}s3"
mkdir -p /tmp/aux
mount -t msdosfs "/dev/${DISK}s3" /tmp/aux
if [ -f "${SRC}/COPYRIGHT" ]; then cp "${SRC}/COPYRIGHT" /tmp/aux/LICENSE.txt; fi
printf 'pfSense CE offline installation media.\r\nYou can put your config.xml on this partition.\r\n' > /tmp/aux/README.txt
umount /tmp/aux

echo "### syncing"
umount "${DST}"
umount "${SRC}"
sync

echo "### DONE"
