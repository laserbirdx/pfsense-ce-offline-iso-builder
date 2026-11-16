#!/usr/bin/env python3
"""Patch for backend/pfSense-install.

Does two things:
  1. Mounts the pkg mirror from the media into the chroot with nullfs. This is
     required because pkg runs inside the chroot and file:// URLs resolve
     relative to the chroot root.
  2. When the installation finishes, switches the installed system's repo URL
     to the official one. This must run while the target is still mounted;
     pfSense_post_install later removes the staging directory and turns
     pfSense.conf into a plain file, so the final path is written directly.
"""
import sys

ANCHORS = [
    (
        '''	/sbin/mount -t devfs -o nocover devfs "${_destdir}/dev" 2>/dev/null
	_CHROOT_DIR="${_destdir}"
	return 0''',
        '''	/sbin/mount -t devfs -o nocover devfs "${_destdir}/dev" 2>/dev/null

	# pkg runs inside the chroot and file:// URLs resolve relative to the
	# chroot root, so the mirror on the media must be mounted into it.
	if [ -d /offline/pkg ]; then
		/bin/mkdir -p "${_destdir}/offline/pkg"
		/sbin/mount -t nullfs -o ro /offline/pkg \\
		    "${_destdir}/offline/pkg" 2>/dev/null
	fi

	_CHROOT_DIR="${_destdir}"
	return 0''',
        "chroot_setup",
    ),
    (
        '''	"${UMOUNT}" "${_CHROOT_DIR}/dev"''',
        '''	"${UMOUNT}" "${_CHROOT_DIR}/dev"
	if [ -d "${_CHROOT_DIR}/offline/pkg" ]; then
		"${UMOUNT}" "${_CHROOT_DIR}/offline/pkg" 2> /dev/null
		/bin/rmdir "${_CHROOT_DIR}/offline/pkg" 2> /dev/null
		/bin/rmdir "${_CHROOT_DIR}/offline" 2> /dev/null
	fi''',
        "chroot_cleanup",
    ),
    (
        '''	/bin/rm "${_destdir}/usr/local/etc/pkg.conf.bkp"
	return 0''',
        '''	/bin/rm "${_destdir}/usr/local/etc/pkg.conf.bkp"

	# The media's file:// URL would be invalid after reboot; point the
	# installed system at the official pkg repository.
	if [ -f /offline/repos-online.conf ]; then
		for _rc in "${_destdir}"/usr/local/share/pfSense/pkg/repos/pfSense_Installer-repo-*.conf; do
			[ -f "${_rc}" ] || continue
			/bin/cp -f /offline/repos-online.conf "${_rc}"
		done
		_pc="${_destdir}/usr/local/etc/pkg/repos/pfSense.conf"
		/bin/mkdir -p "$(dirname "${_pc}")"
		/bin/rm -f "${_pc}"
		/bin/cp -f /offline/repos-online.conf "${_pc}"
	fi

	return 0''',
        "end of pfSense_install",
    ),
]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = open(src).read()
    for old, new, name in ANCHORS:
        if old not in s:
            print(f"anchor not found: {name}", file=sys.stderr)
            return 1
        s = s.replace(old, new, 1)
    open(dst, "w").write(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
