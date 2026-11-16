#!/usr/bin/env bash
#
# pfsense-ce-offline-iso-builder — builds fully offline installation media for
# pfSense CE.
#
# Since 2.8.0 Netgate only ships the "Netgate Installer" for CE: a small
# network installer that downloads packages during installation. This tool
# takes the official installer image YOU downloaded and embeds a mirror of the
# official pkg repository into it, producing media that installs without
# internet access.
#
# This repository contains NO Netgate/pfSense binaries or trademarks. You
# supply the installer image (shop.netgate.com, free); packages are fetched
# from Netgate's public pkg servers. See README.md for licensing notes.
#
# Runs on Linux, macOS and Windows (MSYS2/WSL) and tries to install missing
# dependencies by itself.
#
set -euo pipefail

# --- resolve the script directory, following symlinks ---------------------
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
	_dir="$(cd -P "$(dirname "$_src")" && pwd)"
	_src="$(readlink "$_src")"
	case "$_src" in
	/*) ;;
	*)  _src="$_dir/$_src" ;;
	esac
done
SELF="$(cd -P "$(dirname "$_src")" && pwd)"
LIB="$SELF/lib"
unset _src _dir

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/laserbirdx/pfsense-ce-offline-iso-builder/main}"

# --- bootstrap lib/ when the .sh was downloaded standalone -----------------
_bootstrap_fetch() {
	local url="$1" dst="$2" allow_install="$3" py _sudo=""
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --max-time 30 -o "$dst.part" "$url" 2>/dev/null && [ -s "$dst.part" ] && { mv -f "$dst.part" "$dst"; return 0; }
		rm -f "$dst.part"
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -O "$dst.part" "$url" 2>/dev/null && [ -s "$dst.part" ] && { mv -f "$dst.part" "$dst"; return 0; }
		rm -f "$dst.part"
	fi
	for py in python3 python; do
		command -v "$py" >/dev/null 2>&1 || continue
		case "$(command -v "$py")" in *WindowsApps*|*windowsapps*) continue ;; esac
		if "$py" - "$url" "$dst.part" <<'PY' 2>/dev/null && [ -s "$dst.part" ]; then
import sys
try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen
data = urlopen(sys.argv[1], timeout=30).read()
open(sys.argv[2], "wb").write(data)
PY
			mv -f "$dst.part" "$dst"
			return 0
		fi
		rm -f "$dst.part"
	done
	if [ "$allow_install" = 1 ]; then
		if [ "$(id -u 2>/dev/null || echo 0)" != "0" ]; then
			if command -v sudo >/dev/null 2>&1; then _sudo="sudo"
			elif command -v doas >/dev/null 2>&1; then _sudo="doas"
			else return 1
			fi
		fi
		if command -v apt-get >/dev/null 2>&1; then
			$_sudo apt-get update -qq >/dev/null 2>&1 || true
			$_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1 || true
		elif command -v dnf >/dev/null 2>&1;      then $_sudo dnf install -y -q curl >/dev/null 2>&1 || true
		elif command -v microdnf >/dev/null 2>&1; then $_sudo microdnf install -y curl >/dev/null 2>&1 || true
		elif command -v yum >/dev/null 2>&1;      then $_sudo yum install -y -q curl >/dev/null 2>&1 || true
		elif command -v pacman >/dev/null 2>&1;   then $_sudo pacman -S --noconfirm --needed curl >/dev/null 2>&1 || true
		elif command -v zypper >/dev/null 2>&1;   then $_sudo zypper --non-interactive install curl >/dev/null 2>&1 || true
		elif command -v apk >/dev/null 2>&1;      then $_sudo apk add --quiet curl >/dev/null 2>&1 || true
		elif command -v xbps-install >/dev/null 2>&1; then $_sudo xbps-install -Sy curl >/dev/null 2>&1 || true
		elif command -v pkg >/dev/null 2>&1;      then $_sudo env ASSUME_ALWAYS_YES=yes pkg install -y curl >/dev/null 2>&1 || true
		fi
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --retry 3 --max-time 30 -o "$dst.part" "$url" 2>/dev/null && [ -s "$dst.part" ] && { mv -f "$dst.part" "$dst"; return 0; }
			rm -f "$dst.part"
		fi
	fi
	return 1
}

_bootstrap_lib() {
	local req=(
		deps.sh space.sh mirror-repo.py pkgsum.py
		patch-install.py patch-reposetup.py
		build-memstick.sh mk-memstick.sh patch-serial.sh vmshot.py
	)
	local f need=0 allow_install=1 arg
	for arg in "$@"; do
		[ "$arg" = "--no-install" ] && allow_install=0
	done
	for f in "${req[@]}"; do
		[ -s "$LIB/$f" ] || { need=1; break; }
	done
	[ "$need" = 0 ] && return 0

	if ! mkdir -p "$LIB" 2>/dev/null || [ ! -w "$LIB" ]; then
		LIB="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/pfsense-ce-offline-iso-builder/lib"
		mkdir -p "$LIB" || { echo "error: cannot create helper directory: $LIB" >&2; exit 1; }
		need=0
		for f in "${req[@]}"; do
			[ -s "$LIB/$f" ] || { need=1; break; }
		done
		[ "$need" = 0 ] && return 0
	fi

	printf '\033[36m==\033[0m helper files missing in lib/, fetching from repository...\n' >&2
	for f in "${req[@]}"; do
		[ -s "$LIB/$f" ] && continue
		if ! _bootstrap_fetch "$REPO_RAW_BASE/lib/$f" "$LIB/$f" "$allow_install"; then
			printf '\033[31merror:\033[0m could not download lib/%s from %s\n' "$f" "$REPO_RAW_BASE" >&2
			printf '       Either connect to the internet once or copy the full repository (including lib/).\n' >&2
			exit 1
		fi
	done
	chmod +x "$LIB"/*.sh "$LIB"/*.py 2>/dev/null || true
}

_bootstrap_lib "$@"
unset -f _bootstrap_fetch _bootstrap_lib

for _m in deps.sh space.sh; do
	[ -r "$LIB/$_m" ] || { echo "missing module: lib/$_m" >&2; exit 1; }
	# shellcheck source=/dev/null
	. "$LIB/$_m"
done
unset _m

# --- defaults --------------------------------------------------------------
PKG_HOST="${PKG_HOST:-http://pkg01-atx.netgate.com}"
INSTALLER=""
OUTDIR="$PWD/out"
MIRRORDIR="$PWD/mirror"
CONSOLES="vga"
WANT_MEMSTICK=0
JOBS=4
SKIP_SPACE=0
CACHE_ACTION=""          # keep | clean | "" (ask)
LIST_ONLY=0
VERSIONS=()

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

detect_platform

if [ "$PLATFORM" = macos ] || [ "$PLATFORM" = freebsd ]; then
	fsize() { stat -L -f%z "$1"; }
else
	fsize() { stat -L -c%s "$1"; }
fi

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@"
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$@"
	else
		"$PY" - "$@" <<'PY'
import hashlib, sys
for p in sys.argv[1:]:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    print(f"{h.hexdigest()}  {p}")
PY
	fi
}

human() {
	awk -v n="$1" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (n >= 1024 && i < 5) { n /= 1024; i++ }
		printf "%.1f%s", n, u[i]
	}'
}

usage() {
	cat <<'EOF'
pfsense-ce-offline-iso-builder — offline installation media builder for pfSense CE

Usage:
  ./pfsense-ce-offline-iso-builder.sh --list
  ./pfsense-ce-offline-iso-builder.sh -i <netgate-installer.iso> [options] <version...>

Options:
  -i, --installer <iso>   Netgate Installer ISO (.gz also accepted; searched
                          for automatically if omitted)
  -o, --out <dir>         Output directory        (default: ./out)
  -M, --mirror <dir>      Package mirror directory (default: ./mirror)
  -c, --console <type>    vga | serial | both     (default: vga)
      --memstick          Also build a USB image (requires qemu)
  -j, --jobs <n>          Parallel downloads      (default: 4)
      --keep-cache        Keep the mirror when done, without asking
      --clean-cache       Delete the mirror when done, without asking
      --no-install        Do not install missing dependencies
      --skip-space-check  Skip the disk space check
      --list              List CE versions available on the server and exit
  -h, --help              Show this help

Examples:
  ./pfsense-ce-offline-iso-builder.sh --list
  ./pfsense-ce-offline-iso-builder.sh -i netgate-installer-v1.2-RELEASE-amd64.iso \
      -c both 2.9.0
  ./pfsense-ce-offline-iso-builder.sh -i netgate-installer-v1.2-RELEASE-amd64.iso \
      -c both --memstick 2.9.0 2.8.1
EOF
}

ORIG_ARGS="$*"

# --- arguments -------------------------------------------------------------
# AUTO_INSTALL and PLATFORM/PKGMGR are used in lib/deps.sh.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
	case "$1" in
	-i|--installer)     INSTALLER="${2:?-i expects a file}";       shift 2 ;;
	-o|--out)           OUTDIR="${2:?-o expects a directory}";     shift 2 ;;
	-M|--mirror)        MIRRORDIR="${2:?-M expects a directory}";  shift 2 ;;
	-c|--console)       CONSOLES="${2:?-c expects a value}";       shift 2 ;;
	-j|--jobs)          JOBS="${2:?-j expects a number}";          shift 2 ;;
	--memstick)         WANT_MEMSTICK=1;    shift ;;
	--keep-cache)       CACHE_ACTION=keep;  shift ;;
	--clean-cache)      CACHE_ACTION=clean; shift ;;
	--no-install)       AUTO_INSTALL=0;     shift ;;
	--skip-space-check) SKIP_SPACE=1;       shift ;;
	--list)             LIST_ONLY=1;        shift ;;
	-h|--help)          usage; exit 0 ;;
	--)                 shift; while [ $# -gt 0 ]; do VERSIONS+=("$1"); shift; done ;;
	-*)                 usage >&2; echo >&2; die "unknown option: $1" ;;
	*)                  VERSIONS+=("$1"); shift ;;
	esac
done

case "$CONSOLES" in
vga)    CONSOLE_LIST=(vga) ;;
serial) CONSOLE_LIST=(serial) ;;
both)   CONSOLE_LIST=(vga serial) ;;
*)      die "--console must be vga, serial or both (got: $CONSOLES)" ;;
esac

case "$JOBS" in
''|*[!0-9]*) die "--jobs must be a number (got: $JOBS)" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"

# --- internet connectivity -------------------------------------------------
# Checked first: installing dependencies and mirroring both need the network.
# Without it, a build can still run if the mirror is already complete.
NET_OK=0
if net_check "$PKG_HOST/"; then
	NET_OK=1
	info "internet: OK (${PKG_HOST#*://} reachable)"
else
	warn "cannot reach ${PKG_HOST#*://} - no internet connection or the server is down"
	if [ "$LIST_ONLY" = 1 ]; then
		die "--list needs an internet connection"
	fi
	warn "continuing offline: only versions already fully mirrored can be built"
fi

# --- dependencies ----------------------------------------------------------
NEEDED=(curl python3 xorriso sevenzip)
if [ "$WANT_MEMSTICK" = 1 ]; then NEEDED+=(qemu qemu-img); fi
if ! ensure_tools "${NEEDED[@]}"; then
	if [ "$NET_OK" != 1 ]; then
		die "could not satisfy dependencies (installing them needs an internet connection)"
	fi
	die "could not satisfy dependencies"
fi

CURL="$(tool_path curl)"
PY="$(tool_path python3)"
XORRISO="$(tool_path xorriso)"
SEVENZ="$(tool_path sevenzip)"
export CURL PY XORRISO SEVENZ
if [ "$WANT_MEMSTICK" = 1 ]; then
	QEMU="$(tool_path qemu)"
	QEMU_IMG="$(tool_path qemu-img)"
	export QEMU QEMU_IMG
fi
[ -f "$LIB/mirror-repo.py" ] || die "lib/mirror-repo.py is missing"

# --- list versions ---------------------------------------------------------
list_versions() {
	info "pfSense CE versions on the server ($PKG_HOST)"
	local found=0 minor patch v code
	for minor in $(seq 6 12); do
		for patch in $(seq 0 4); do
			v="2_${minor}_${patch}"
			code="$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 10 \
				"$PKG_HOST/pfSense_v${v}_amd64-core/meta.conf" 2>/dev/null || true)"
			if [ "$code" = "200" ]; then
				printf '   %s\n' "${v//_/.}"
				found=1
			fi
		done
	done
	if [ "$found" != 1 ]; then
		warn "no versions found - check your network connection"
		return 1
	fi
	return 0
}

if [ "$LIST_ONLY" = 1 ]; then
	list_versions
	exit $?
fi

# --- validation ------------------------------------------------------------
if [ ${#VERSIONS[@]} -eq 0 ]; then
	usage >&2; echo >&2; die "specify at least one version (e.g. 2.9.0)"
fi
INSTALLER_URL_PAGE="https://shop.netgate.com/products/netgate-installer"

# If -i was not given (or the path does not exist), look in the usual places.
# Directory names may contain spaces, so the list is read line by line.
find_installer() {
	local d f best=""
	while IFS= read -r d; do
		[ -n "$d" ] && [ -d "$d" ] || continue
		for f in "$d"/netgate-installer*.iso "$d"/netgate-installer*.iso.gz; do
			[ -f "$f" ] || continue
			if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
		done
	done < <( { printf '%s\n' "$PWD" "$SELF"; download_dirs_uniq; } | awk '!seen[$0]++')
	if [ -n "$best" ]; then printf '%s\n' "$best"; fi
}

installer_help() {
	cat >&2 <<EOF

The Netgate Installer ISO is required and could not be found.

  1. Download it for free from the page that just opened (requires a
     Netgate account):
     $INSTALLER_URL_PAGE
     Pick the "AMD64 ISO"; it must be v1.2-RELEASE or newer.

  2. Put the downloaded file into one of these directories:
$( { printf '%s\n' "$PWD"; download_dirs_uniq; } | awk '!seen[$0]++' | sed 's/^/     /')

  3. Run this command again (it will find the file by itself):
     $0 ${ORIG_ARGS:-<arguments>}

  Alternatively, pass the path directly with -i.

EOF
}

if [ -z "$INSTALLER" ] || [ ! -e "$INSTALLER" ]; then
	if [ -n "$INSTALLER" ]; then
		warn "installer not found at the given path: $INSTALLER"
	fi
	_found="$(find_installer || true)"
	if [ -n "$_found" ]; then
		INSTALLER="$_found"
		info "found installer: $INSTALLER"
	else
		if open_url "$INSTALLER_URL_PAGE"; then
			info "opened the download page in your browser"
		fi
		installer_help
		die "no installer"
	fi
fi

# Make relative paths absolute so later directory changes cannot break them.
abspath() {
	case "$1" in
	/*) printf '%s\n' "$1" ;;
	*)  printf '%s\n' "$PWD/${1#./}" ;;
	esac
}
INSTALLER="$(abspath "$INSTALLER")"
OUTDIR="$(abspath "$OUTDIR")"
MIRRORDIR="$(abspath "$MIRRORDIR")"

if [ "${INSTALLER%.gz}" != "$INSTALLER" ]; then
	if [ ! -f "${INSTALLER%.gz}" ]; then
		info "decompressing installer"
		if command -v gunzip >/dev/null 2>&1; then
			gunzip -kf "$INSTALLER" || die "could not decompress the installer"
		else
			"$PY" - "$INSTALLER" "${INSTALLER%.gz}" <<'PY' || die "could not decompress the installer"
import gzip, shutil, sys
with gzip.open(sys.argv[1], "rb") as fin, open(sys.argv[2], "wb") as fout:
    shutil.copyfileobj(fin, fout)
PY
		fi
	fi
	INSTALLER="${INSTALLER%.gz}"
fi
[ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"

mkdir -p "$OUTDIR" "$MIRRORDIR" || die "could not create directories"
WORK="$OUTDIR/.work"
mkdir -p "$WORK"

# --- disk space ------------------------------------------------------------
if [ "$SKIP_SPACE" != 1 ]; then
	n_iso=$(( ${#VERSIONS[@]} * ${#CONSOLE_LIST[@]} ))
	n_mem=0
	if [ "$WANT_MEMSTICK" = 1 ]; then n_mem="$n_iso"; fi
	check_space "$OUTDIR" "$MIRRORDIR" "${#VERSIONS[@]}" "$n_iso" "$n_mem" \
		"$(fsize "$INSTALLER")" 1 || exit 1
fi

# --- inspect the installer -------------------------------------------------
"$SEVENZ" e -so "$INSTALLER" bin/sh > "$WORK/_sh" 2>/dev/null \
	|| die "could not read the ISO: $INSTALLER"
# Read FreeBSD ABI version directly from ELF PT_NOTE (no external `file` tool needed).
INST_FBSD="$("$PY" - "$WORK/_sh" <<'PY' 2>/dev/null || true
import struct, sys
data = open(sys.argv[1], "rb").read()
if data[:4] == b"\x7fELF":
    endian = "<" if data[5] == 1 else ">"
    if data[4] == 2:
        phoff, = struct.unpack_from(endian + "Q", data, 32)
        phentsize, phnum = struct.unpack_from(endian + "HH", data, 54)
        fmt, off_i, sz_i = endian + "IIQQQQQQ", 2, 5
    else:
        phoff, = struct.unpack_from(endian + "I", data, 28)
        phentsize, phnum = struct.unpack_from(endian + "HH", data, 42)
        fmt, off_i, sz_i = endian + "IIIIIIII", 1, 4
    for i in range(phnum):
        ph = struct.unpack_from(fmt, data, phoff + i * phentsize)
        if ph[0] != 4:
            continue
        p, end = ph[off_i], ph[off_i] + ph[sz_i]
        while p + 12 <= end:
            nsz, dsz, ntype = struct.unpack_from(endian + "III", data, p)
            p += 12
            name = data[p:p + nsz]
            p += (nsz + 3) & ~3
            desc = data[p:p + dsz]
            p += (dsz + 3) & ~3
            if name.rstrip(b"\x00") == b"FreeBSD" and ntype == 1 and len(desc) >= 4:
                v, = struct.unpack_from(endian + "I", desc, 0)
                print(f"{v // 100000}.{(v // 1000) % 100}")
                sys.exit(0)
PY
)"
if [ -z "$INST_FBSD" ] && command -v file >/dev/null 2>&1; then
	INST_FBSD="$(LC_ALL=C file "$WORK/_sh" 2>/dev/null \
		| grep -oE 'FreeBSD [0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
fi
INST_MAJOR="${INST_FBSD%%.*}"
rm -f "$WORK/_sh"
[ -n "$INST_MAJOR" ] || die "could not determine the installer's FreeBSD version; is this the right ISO?"
info "installer base: FreeBSD $INST_FBSD"

# Note: "7z l | grep -q" is avoided on purpose; when grep exits early 7z gets
# SIGPIPE and, with pipefail, the pipeline looks like it failed.
INST=usr/local/libexec/installer
"$SEVENZ" l "$INSTALLER" > "$WORK/_isolist.txt" 2>/dev/null || true
grep -q "$INST/backend/pfSense-install" "$WORK/_isolist.txt" || die \
"this installer version is not supported (v1.2-RELEASE or newer required).
     Get the current image: https://shop.netgate.com/products/netgate-installer"

BOOTDIR="$WORK/bootimgs"
if [ ! -f "$BOOTDIR/eltorito_img2_uefi.img" ]; then
	info "extracting boot images"
	rm -rf "$BOOTDIR"; mkdir -p "$BOOTDIR"
	"$XORRISO" -indev "$INSTALLER" -osirrox on -extract_boot_images "$BOOTDIR" \
		>/dev/null 2>&1 || die "could not extract boot images"
	[ -f "$BOOTDIR/eltorito_img2_uefi.img" ] || die "UEFI boot image not found"
fi

SRCX="$WORK/iso-scripts"
if [ ! -d "$SRCX/$INST/backend" ]; then
	info "extracting installer scripts"
	"$SEVENZ" x -y -o"$SRCX" "$INSTALLER" "$INST/*" "boot/loader.conf" \
		>/dev/null 2>&1 || die "could not extract installer scripts"
fi

# --- repo conf generator ---------------------------------------------------
# $1 = URL prefix; if $2 is non-empty, mirror_type: srv is added
gen_repo_conf() {
	local url="$1" srv="${2:-}" extra=""
	if [ -n "$srv" ]; then
		extra='
    mirror_type: "srv",'
	fi
	cat <<EOF
FreeBSD: { enabled: no }

pfSense-core: {
    url: "$url/$CORE",$extra
    signature_type: "fingerprints",
    fingerprints: "/usr/local/share/pfSense/keys/pkg",
    enabled: yes
}

pfSense: {
    url: "$url/$MAIN",$extra
    signature_type: "fingerprints",
    fingerprints: "/usr/local/share/pfSense/keys/pkg",
    enabled: yes
}
EOF
}

# --- build -----------------------------------------------------------------
BUILT=()
for VER in "${VERSIONS[@]}"; do
	case "$VER" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) die "invalid version format: $VER (example: 2.9.0)" ;;
	esac

	VTAG="${VER//./_}"
	CORE="pfSense_v${VTAG}_amd64-core"
	MAIN="pfSense_v${VTAG}_amd64-pfSense_v${VTAG}"

	if [ "$NET_OK" = 1 ]; then
		code="$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 20 \
			"$PKG_HOST/$CORE/meta.conf" 2>/dev/null || true)"
		[ "$code" = "200" ] || die "$VER is not on the server (see --list)"
	elif [ ! -f "$MIRRORDIR/$VER/$CORE/packagesite.pkg" ]; then
		die "no internet connection and no mirror of $VER in $MIRRORDIR"
	fi

	info "mirroring pfSense CE $VER"
	# Always the full repository: pkg can pull in packages beyond the declared
	# dependencies, and a partial mirror leaves the installation incomplete.
	MIRROR_ARGS=("$MIRRORDIR" "$VER" "--full" "--jobs" "$JOBS" "--host" "$PKG_HOST")
	"$PY" "$LIB/mirror-repo.py" "${MIRROR_ARGS[@]}" || die "mirroring failed"

	ABI="$("$PY" -c 'import json,sys;print(json.loads(open(sys.argv[1]).readline())["abi"])' \
		"$MIRRORDIR/$VER/$CORE/packagesite.yaml")"
	ALTABI="$("$PY" -c 'import json,sys;print(json.loads(open(sys.argv[1]).readline())["arch"])' \
		"$MIRRORDIR/$VER/$CORE/packagesite.yaml")"
	PKG_MAJOR="$(printf '%s' "$ABI" | cut -d: -f2)"

	if [ "$PKG_MAJOR" -gt "$INST_MAJOR" ]; then
		die "$VER packages are FreeBSD $PKG_MAJOR but the installer is FreeBSD $INST_MAJOR.
     An older kernel cannot run newer binaries, so the installation would
     crash at the pfSense-system step. Download a current installer:
     https://shop.netgate.com/products/netgate-installer"
	fi
	if [ "$PKG_MAJOR" -lt "$INST_MAJOR" ]; then
		warn "packages are FreeBSD $PKG_MAJOR, installer is FreeBSD $INST_MAJOR (backward compatible)"
	fi

	for CONSOLE in "${CONSOLE_LIST[@]}"; do
		info "building media: $VER ($CONSOLE) | ABI=$ABI"
		OV="$WORK/ov-$VER-$CONSOLE"
		rm -rf "$OV"
		mkdir -p "$OV/offline/repos" "$OV/usr/local/sbin" \
		         "$OV/$INST/backend" "$OV/$INST/cli" "$OV/boot"

		# Careful: with a single repo, cli/pfSense-repo-setup sends the
		# contents of .name to the daemon, while the backend looks the conf
		# file up by ID. They must match, hence .name = ID = 0000.
		R="$OV/offline/repos/pfSense_Installer-repo-0000"
		printf '%s' "0000"                      > "$R.name"
		printf '%s' "Offline - pfSense CE $VER" > "$R.descr"
		printf '%s' "pfSense Community Edition" > "$R.version"
		printf '%s' "1"                         > "$R.release"
		printf '%s' "$ABI"                      > "$R.abi"
		printf '%s' "$ALTABI"                   > "$R.altabi"
		: > "$R.default"
		gen_repo_conf "file:///offline/pkg"             > "$R.conf"
		gen_repo_conf "pkg+https://pkg.pfsense.org" srv > "$OV/offline/repos-online.conf"
		printf '%s\n' "$VER" > "$OV/offline/OFFLINE"

		cat > "$OV/usr/local/sbin/pfSense-repoc-static" <<'STUB'
#!/bin/sh
# Offline replacement for repoc: instead of contacting Netgate, copies the
# repo definitions shipped on the media into the directory given with -d.
STAGE="/offline/repos"
DIR=""; WANT_E=0; WANT_T=0; WANT_V=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	-d)  DIR="$2"; shift 2; continue ;;
	-d*) DIR="${1#-d}"; shift; continue ;;
	-*)  case "$1" in *e*) WANT_E=1 ;; esac
	     case "$1" in *t*) WANT_T=1 ;; esac
	     case "$1" in *v*) WANT_V=1 ;; esac
	     shift; continue ;;
	*)   shift; continue ;;
	esac
done
if [ "${WANT_V}" = 1 ]; then
	echo "pfSense-repoc version: offline"
	exit 0
fi
if [ "${WANT_E}" = 1 ]; then
	# No Plus subscription -> the installer takes the CE path.
	if [ "${WANT_T}" = 1 ]; then
		echo "Messages:"
		echo "Offline installer - pfSense CE."
	fi
	exit 0
fi
if [ -n "${DIR}" ]; then
	# Do not overwrite existing files: at the end of the installation the
	# repo URL is switched to the official one and a later repoc call must
	# not undo that.
	/bin/mkdir -p "${DIR}/pkg/repos" || exit 1
	for _f in "${STAGE}"/*; do
		_t="${DIR}/pkg/repos/$(basename "${_f}")"
		[ -e "${_t}" ] || /bin/cp -f "${_f}" "${_t}" || exit 1
	done
fi
exit 0
STUB

		cat > "$OV/$INST/backend/pfSense-connectivity-check" <<'STUB'
#!/bin/sh
# Offline installation: NTP and Netgate reachability checks are not needed.
exit 0
STUB

		cat > "$OV/$INST/cli/pfSense-netconfig" <<'STUB'
#!/bin/sh
# Offline installation: no network configuration is done. The installer
# daemon expects the WAN-ASSIGNED and CONNECTIVITY-CHECK states, so only
# those two steps are fed.
INSTALL_INC_PATH="/usr/local/libexec/installer"
. "${INSTALL_INC_PATH}/common/pfSense-common"

IFACE="$(json_read "$(get_info)" '.nics[0].name')"
if [ -z "${IFACE}" ] || [ "${IFACE}" = "null" ]; then
	IFACE="$(/sbin/ifconfig -l | ${AWK} '{print $1}')"
fi
if [ -z "${IFACE}" ]; then
	"${BSDDIALOG}" --backtitle "$(get_title)" --title ' Offline Installer ' \
	    --msgbox '\nNo network interface found.\n' 0 0
	exit 1
fi
"${CURL}" ${CURLFLAGS} -d "wan=${IFACE}" "${INSTALLER_URL}/nic-assign" >/dev/null 2>&1 || exit 1
"${CURL}" ${CURLFLAGS} "${INSTALLER_URL}/connectivity-check"           >/dev/null 2>&1 || exit 1
exit 0
STUB

		"$PY" "$LIB/patch-install.py" \
			"$SRCX/$INST/backend/pfSense-install" \
			"$OV/$INST/backend/pfSense-install" || die "patching pfSense-install failed"
		"$PY" "$LIB/patch-reposetup.py" \
			"$SRCX/$INST/backend/pfSense-repo-setup" \
			"$OV/$INST/backend/pfSense-repo-setup" || die "patching pfSense-repo-setup failed"

		chmod 755 "$OV/usr/local/sbin/pfSense-repoc-static" \
		          "$OV/$INST/backend/pfSense-connectivity-check" \
		          "$OV/$INST/backend/pfSense-install" \
		          "$OV/$INST/backend/pfSense-repo-setup" \
		          "$OV/$INST/cli/pfSense-netconfig"

		MAPS=(-map "$OV/offline" /offline
		      -map "$MIRRORDIR/$VER/$CORE" "/offline/pkg/$CORE"
		      -map "$MIRRORDIR/$VER/$MAIN" "/offline/pkg/$MAIN"
		      -map "$OV/usr/local/sbin/pfSense-repoc-static" /usr/local/sbin/pfSense-repoc-static
		      -map "$OV/$INST/backend/pfSense-connectivity-check" "/$INST/backend/pfSense-connectivity-check"
		      -map "$OV/$INST/backend/pfSense-install"            "/$INST/backend/pfSense-install"
		      -map "$OV/$INST/backend/pfSense-repo-setup"         "/$INST/backend/pfSense-repo-setup"
		      -map "$OV/$INST/cli/pfSense-netconfig"              "/$INST/cli/pfSense-netconfig")

		SUFFIX=""
		if [ "$CONSOLE" = "serial" ]; then
			cp "$SRCX/boot/loader.conf" "$OV/boot/loader.conf"
			cat >> "$OV/boot/loader.conf" <<'EOF'

# Serial console variant
boot_serial="YES"
console="comconsole,vidconsole"
comconsole_speed="115200"
hint.uart.0.flags="0x10"
EOF
			printf -- '-S115200 -h' > "$OV/boot.config"
			MAPS+=(-map "$OV/boot/loader.conf" /boot/loader.conf
			       -map "$OV/boot.config" /boot.config)
			SUFFIX="-serial"
		fi

		ISO_OUT="$OUTDIR/pfSense-CE-offline${SUFFIX}-${VER}-amd64.iso"
		rm -f "$ISO_OUT"
		if ! "$XORRISO" -indev "$INSTALLER" -outdev "$ISO_OUT" \
			-boot_image any discard \
			-overwrite on -joliet on \
			"${MAPS[@]}" \
			-append_partition 2 0xef "$BOOTDIR/eltorito_img2_uefi.img" \
			-boot_image any appended_part_as=gpt \
			-boot_image any cat_path=/boot/boot.catalog \
			-boot_image any bin_path=/boot/cdboot \
			-boot_image any platform_id=0x00 \
			-boot_image any emul_type=no_emulation \
			-boot_image any load_size=2048 \
			-boot_image any boot_info_table=off \
			-boot_image any next \
			-boot_image any efi_path=--interval:appended_partition_2:all:: \
			-boot_image any emul_type=no_emulation \
			-boot_image any partition_table=on \
			-commit >"$WORK/_xorriso.log" 2>&1
		then
			tail -20 "$WORK/_xorriso.log" >&2
			die "could not build the ISO"
		fi
		[ -s "$ISO_OUT" ] || die "ISO was not created: $ISO_OUT"
		BUILT+=("$ISO_OUT")
		printf '   -> %s (%s)\n' "$(basename "$ISO_OUT")" "$(human "$(fsize "$ISO_OUT")")"

		if [ "$WANT_MEMSTICK" = 1 ]; then
			IMG_OUT="$OUTDIR/pfSense-CE-offline-memstick${SUFFIX}-${VER}-amd64.img"
			if bash "$LIB/build-memstick.sh" "$ISO_OUT" "$IMG_OUT"; then
				BUILT+=("$IMG_OUT")
			else
				warn "could not build the memstick image; the ISO is ready"
			fi
		fi
	done
done

# --- summary ---------------------------------------------------------------
info "SHA256 checksums"
(
	cd "$OUTDIR" || exit 1
	: > SHA256SUMS
	for f in *.iso *.img; do
		[ -e "$f" ] || continue
		sha256 "$f" >> SHA256SUMS
	done
	cat SHA256SUMS
)

# --- mirror cache ----------------------------------------------------------
MIRROR_KB="$(dir_kb "$MIRRORDIR")"
if [ "${MIRROR_KB:-0}" -gt 0 ]; then
	case "$CACHE_ACTION" in
	clean)
		info "deleting mirror cache ($(human_kb "$MIRROR_KB"))"
		rm -rf "${MIRRORDIR:?}"/*
		;;
	keep)
		info "mirror cache kept ($(human_kb "$MIRROR_KB")): $MIRRORDIR"
		;;
	*)
		if [ -t 0 ] && [ -t 1 ]; then
			printf '\n\033[36m==\033[0m The mirror cache uses %s: %s\n' \
				"$(human_kb "$MIRROR_KB")" "$MIRRORDIR"
			printf '   Keeping it makes later builds much faster.\n'
			printf '   Delete it? [y/N] '
			answer=""
			read -r answer || true
			case "$answer" in
			[yY]|[yY][eE][sS])
				info "deleting"
				rm -rf "${MIRRORDIR:?}"/*
				;;
			*)
				info "kept: $MIRRORDIR"
				;;
			esac
		else
			info "mirror cache kept ($(human_kb "$MIRROR_KB")): $MIRRORDIR"
			printf '   To delete it: rm -rf %s/*   (or use --clean-cache)\n' "$MIRRORDIR"
		fi
		;;
	esac
fi

rm -rf "$WORK"/ov-* "$WORK/_isolist.txt" "$WORK/_xorriso.log" 2>/dev/null || true

info "done — ${#BUILT[@]} file(s) built in $OUTDIR"
echo "   Writing to a USB stick:"
echo "     linux   : sudo dd if=<img> of=/dev/sdX bs=4M status=progress conv=fsync"
echo "     macos   : sudo dd if=<img> of=/dev/rdiskN bs=4m"
echo "     windows : Rufus (DD mode) or balenaEtcher"
