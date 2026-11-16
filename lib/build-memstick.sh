#!/usr/bin/env bash
#
# Builds a USB (memstick) image from an offline ISO.
#
#   build-memstick.sh <offline.iso> <output.img>
#
# Creating a UFS file system needs the FreeBSD toolchain, so the work is done
# in a temporary QEMU machine booted from the ISO itself: it copies its own
# root onto the new disk, writes the boot code and stops.
#
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="${1:?offline ISO}"
OUT="${2:?output image}"

case "$(uname -s)" in
Darwin|FreeBSD) fsize() { stat -L -f%z "$1"; }; cpus() { sysctl -n hw.ncpu; } ;;
*)              fsize() { stat -L -c%s "$1"; }; cpus() { nproc 2>/dev/null || echo 4; } ;;
esac
human() {
	awk -v n="$1" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (n >= 1024 && i < 5) { n /= 1024; i++ }
		printf "%.1f%s", n, u[i]
	}'
}

if [ -z "${PY:-}" ]; then
	if [ -r "$LIB/deps.sh" ]; then
		# shellcheck source=/dev/null
		. "$LIB/deps.sh"
		detect_platform
		PY="$(tool_path python3 || true)"
	else
		PY="$(command -v python3 || command -v python || true)"
	fi
fi
[ -n "$PY" ] && command -v "$PY" >/dev/null 2>&1 || {
	echo "python3 (>= 3.6) not found" >&2; exit 1; }

QEMU="${QEMU:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
command -v "$QEMU" >/dev/null || {
	echo "qemu-system-x86_64 not found (linux: apt install qemu-system-x86 | macos: brew install qemu)" >&2; exit 1; }
command -v "$QEMU_IMG" >/dev/null || {
	echo "qemu-img not found (linux: apt install qemu-utils | macos: brew install qemu)" >&2; exit 1; }

# QEMU's -drive syntax uses commas as separators; a literal comma in a path
# must be doubled. Spaces are fine because each option is a single argument.
qemu_path() { printf '%s' "${1//,/,,}"; }

# Pick a free TCP port for the temporary HTTP server unless one is given.
PORT="${HTTP_PORT:-$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
MON="$(mktemp -u "${TMPDIR:-/tmp}/pfmk-mon.XXXXXX")"
SER="$(mktemp -u "${TMPDIR:-/tmp}/pfmk-ser.XXXXXX")"
HTTPDIR="$(mktemp -d)"
cp "$LIB/mk-memstick.sh" "$HTTPDIR/"
cleanup() {
	if [ -n "${QPID:-}" ];  then kill "$QPID"  2>/dev/null || true; fi
	if [ -n "${HTPID:-}" ]; then kill "$HTPID" 2>/dev/null || true; fi
	rm -rf "$HTTPDIR"; rm -f "$MON" "$SER"
}
trap cleanup EXIT

# Image size: ISO contents + room for UFS. ISO9660 does not keep hard links,
# so /rescue would balloon when unpacked; mk-memstick.sh restores them as hard
# links, which makes "ISO size + 1 GB" enough.
ISOSZ=$(fsize "$ISO")
MB=$(( ISOSZ / 1048576 + 1024 ))
echo "== creating memstick image (${MB} MB)"
rm -f "$OUT"
"$QEMU_IMG" create -f raw "$OUT" "${MB}M" >/dev/null

( cd "$HTTPDIR" && exec "$PY" -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTPID=$!

# Use hardware acceleration when available.
ACCEL=()
if [ "$(uname -s)" = Darwin ]; then
	ACCEL=(-accel hvf)
elif [ -w /dev/kvm ]; then
	ACCEL=(-accel kvm)
fi

# On bash 3.2 an empty array expansion fails under "set -u", hence the guard.
"$QEMU" -machine q35 -m 2560 -smp "$(cpus)" ${ACCEL[@]+"${ACCEL[@]}"} \
	-drive "file=$(qemu_path "$OUT"),if=virtio,format=raw,cache=unsafe" \
	-drive "file=$(qemu_path "$ISO"),media=cdrom,readonly=on" -boot d \
	-netdev user,id=n0 -device e1000,netdev=n0 \
	-display none -vnc none \
	-monitor "unix:$MON,server,nowait" \
	-serial "file:$SER" -no-reboot >/dev/null 2>&1 &
QPID=$!

key() { QEMU_MON="$MON" "$PY" "$LIB/vmshot.py" keys "$@" >/dev/null 2>&1 || true; }
run() { QEMU_MON="$MON" "$PY" "$LIB/vmshot.py" run  "$1" >/dev/null 2>&1 || true; }

echo "== booting the installer (a few minutes)"
for _ in $(seq 1 60); do
	if [ -S "$MON" ]; then break; fi
	sleep 2
done
sleep 90

# License screen -> Welcome -> Rescue Shell
key ret;  sleep 8
key down; sleep 2
key ret;  sleep 10

echo "== transferring the build script"
run 'dhclient $(ifconfig -l | awk "{print \$1}") >/dev/null 2>&1; fetch -q -o /tmp/mk.sh http://10.0.2.2:'"$PORT"'/mk-memstick.sh'
sleep 10

echo "== copying (this can take 10-20 minutes)"
run 'sh /tmp/mk.sh vtbd0 > /dev/cuau0 2>&1; echo "===MK-EXIT=$?===" > /dev/cuau0'

for _ in $(seq 1 360); do
	if grep -q "MK-EXIT" "$SER" 2>/dev/null; then break; fi
	sleep 10
done

if grep -q "MK-EXIT=0" "$SER" 2>/dev/null; then
	grep -A3 'usage:' "$SER" | tail -2 | head -1 || true
	echo "   -> $(basename "$OUT") ($(human "$(fsize "$OUT")"))"
else
	echo "!! could not build the memstick image; last lines:" >&2
	tail -15 "$SER" >&2 || true
	exit 1
fi
