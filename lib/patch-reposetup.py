#!/usr/bin/env python3
"""Patch for backend/pfSense-repo-setup.

The repo definitions ship on the offline media, but the pfSense.conf symlink
points inside the chroot, so the definitions must exist there too. An
existing file is left alone: the repo URL is switched to the official one at
the end of the installation and this step must not undo that.
"""
import sys

OLD = '''PKG_REPO_CONF="${REPO_DIR}/pkg/repos/${REPO_BASE_NAME}-repo-${REPO_NAME}.conf"

if [ ! -f "${CHROOT_DIR}${PKG_REPO_CONF}" ]; then'''

NEW = '''PKG_REPO_CONF="${REPO_DIR}/pkg/repos/${REPO_BASE_NAME}-repo-${REPO_NAME}.conf"

# The offline media ships the repo definitions; the pfSense.conf symlink
# points inside the chroot, so they must be copied there as well.
if [ -d /offline/repos ] && [ ! -f "${CHROOT_DIR}${PKG_REPO_CONF}" ]; then
	/bin/mkdir -p "${CHROOT_DIR}${REPO_DIR}/pkg/repos"
	/bin/cp -f /offline/repos/* "${CHROOT_DIR}${REPO_DIR}/pkg/repos/"
fi

if [ ! -f "${CHROOT_DIR}${PKG_REPO_CONF}" ]; then'''


def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = open(src).read()
    if OLD not in s:
        print("anchor not found: PKG_REPO_CONF", file=sys.stderr)
        return 1
    open(dst, "w").write(s.replace(OLD, NEW, 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
