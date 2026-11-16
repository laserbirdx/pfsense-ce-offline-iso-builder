#!/usr/bin/env bash
# Dependency detection, automatic installation and environment helpers.
#
# Sourced by the main script. Public API:
#   detect_platform          fills in PLATFORM / PKGMGR / SUDO
#   net_check <url>          0 if the URL is reachable (curl, python or /dev/tcp)
#   ensure_tools <tool...>   installs missing tools, explains and fails otherwise
#   tool_path <tool>         prints the full path of the binary found
#   open_url <url>           opens a URL in the desktop browser if possible
#   download_dirs_uniq       the user's download directories, one per line
#
# Tool names are abstract: curl python3 xorriso sevenzip qemu
# The real package name is picked per package manager.

AUTO_INSTALL="${AUTO_INSTALL:-1}"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/pfsense-ce-offline-iso-builder"
PORTABLE_PY="$CACHE_ROOT/python/bin/python3"

# shellcheck disable=SC2034  # PLATFORM/PKGMGR/SUDO/CAN_PRIV are used by the caller
detect_platform() {
	case "$(uname -s 2>/dev/null)" in
	Darwin)               PLATFORM=macos ;;
	MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
	Linux)                PLATFORM=linux ;;
	FreeBSD)              PLATFORM=freebsd ;;
	*)                    PLATFORM=unknown ;;
	esac

	PKGMGR=""
	local m
	for m in brew port pacman apt-get dnf microdnf yum zypper apk xbps-install pkg; do
		if command -v "$m" >/dev/null 2>&1; then
			PKGMGR="$m"
			break
		fi
	done

	# Use sudo/doas when not root (not needed for Homebrew or MSYS2 pacman).
	SUDO=""
	CAN_PRIV=1
	if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && \
	   [ "$PKGMGR" != "brew" ] && \
	   ! { [ "$PLATFORM" = windows ] && [ "$PKGMGR" = pacman ]; }; then
		if command -v sudo >/dev/null 2>&1; then
			SUDO="sudo"
		elif command -v doas >/dev/null 2>&1; then
			SUDO="doas"
		else
			CAN_PRIV=0
		fi
	fi
}

# ------------------------------------------------------------ validation
# Verifies a candidate Python binary is a real Python >= 3.6 with the required
# standard library modules (rejects Python 2 and Windows Store alias stubs).
_valid_python3() {
	local bin="$1"
	[ -n "$bin" ] && [ -x "$bin" ] || return 1
	case "$bin" in
	*WindowsApps*|*windowsapps*) return 1 ;;
	esac
	"$bin" - <<'PY' >/dev/null 2>&1
import sys, json, hashlib, socket, subprocess, tarfile, urllib.request
from concurrent.futures import ThreadPoolExecutor
sys.exit(0 if sys.version_info >= (3, 6) and hasattr(hashlib, "blake2b") else 1)
PY
}

# Verifies a candidate 7-Zip binary actually supports reading ISO9660 images
# (rejects 7zr and stripped 7za builds without IsoHandler).
_valid_sevenzip() {
	local bin="$1"
	[ -n "$bin" ] && [ -x "$bin" ] || return 1
	"$bin" i 2>/dev/null | grep -qiE '(^|[[:space:]])Iso([[:space:]]|$)'
}

# Prints all executable matches for <name> across PATH, one per line.
_all_in_path() {
	local name="$1" dir old_ifs="$IFS"
	IFS=:
	for dir in $PATH; do
		[ -n "$dir" ] || dir="."
		if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
			printf '%s\n' "$dir/$name"
		fi
		if [ "${PLATFORM:-}" = windows ] && [ -f "$dir/$name.exe" ] && [ -x "$dir/$name.exe" ]; then
			printf '%s\n' "$dir/$name.exe"
		fi
	done
	IFS="$old_ifs"
}

# --------------------------------------------------------------- network
# net_check <url> -> 0 if an HTTP(S) request to the URL gets any response.
# Works before dependencies are installed: tries curl, wget, a validated
# python3, then a raw TCP connection through bash's /dev/tcp.
net_check() {
	local url="$1" host port rest
	if command -v curl >/dev/null 2>&1; then
		curl -s -o /dev/null --connect-timeout 8 --max-time 15 "$url" 2>/dev/null && return 0
		return 1
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q --spider -T 15 "$url" 2>/dev/null && return 0
		return 1
	fi
	local py
	if py="$(tool_path python3 2>/dev/null)"; then
		"$py" - "$url" <<'PY' 2>/dev/null && return 0
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(sys.argv[1], timeout=15)
except urllib.error.HTTPError:
    pass            # the server answered; that is enough
sys.exit(0)
PY
		return 1
	fi
	rest="${url#*://}"; host="${rest%%/*}"
	case "$url" in https://*) port=443 ;; *) port=80 ;; esac
	case "$host" in *:*) port="${host##*:}"; host="${host%%:*}" ;; esac
	( exec 3<>"/dev/tcp/$host/$port" ) 2>/dev/null
}

# --------------------------------------------------------------- packages
# Abstract tool -> package name for the current package manager
pkg_name_for() {
	local tool="$1"

	# MSYS2 also uses pacman, but package names differ from Arch.
	if [ "${PLATFORM:-}" = windows ] && [ "$PKGMGR" = pacman ]; then
		case "$tool" in
		curl)     echo "curl" ;;
		python3)  echo "python" ;;
		xorriso)  echo "xorriso" ;;
		sevenzip) echo "p7zip" ;;
		qemu)     echo "mingw-w64-x86_64-qemu" ;;
		qemu-img) echo "mingw-w64-x86_64-qemu" ;;
		*)        echo "$tool" ;;
		esac
		return
	fi

	case "$PKGMGR:$tool" in
	*:curl)                       echo "curl" ;;

	brew:python3)                 echo "python3" ;;
	pacman:python3)               echo "python" ;;
	xbps-install:python3)         echo "python3" ;;
	pkg:python3)                  echo "python3" ;;
	*:python3)                    echo "python3" ;;

	pacman:xorriso)               echo "libisoburn" ;;
	*:xorriso)                    echo "xorriso" ;;

	apt-get:sevenzip)             echo "p7zip-full" ;;
	dnf:sevenzip|microdnf:sevenzip|yum:sevenzip) echo "p7zip p7zip-plugins" ;;
	pacman:sevenzip)              echo "7zip" ;;
	apk:sevenzip)                 echo "7zip" ;;
	xbps-install:sevenzip)        echo "7zip" ;;
	pkg:sevenzip)                 echo "7-zip" ;;
	brew:sevenzip)                echo "sevenzip" ;;
	port:sevenzip)                echo "p7zip" ;;
	*:sevenzip)                   echo "p7zip" ;;

	apt-get:qemu)                 echo "qemu-system-x86 qemu-utils" ;;
	apt-get:qemu-img)             echo "qemu-utils" ;;
	dnf:qemu|microdnf:qemu|yum:qemu) echo "qemu-system-x86 qemu-img" ;;
	dnf:qemu-img|microdnf:qemu-img|yum:qemu-img) echo "qemu-img" ;;
	pacman:qemu)                  echo "qemu-base" ;;
	pacman:qemu-img)              echo "qemu-img" ;;
	zypper:qemu)                  echo "qemu-x86 qemu-tools" ;;
	zypper:qemu-img)              echo "qemu-tools" ;;
	apk:qemu)                     echo "qemu-system-x86_64 qemu-img" ;;
	apk:qemu-img)                 echo "qemu-img" ;;
	xbps-install:qemu|xbps-install:qemu-img) echo "qemu" ;;
	pkg:qemu)                     echo "qemu" ;;
	pkg:qemu-img)                 echo "qemu-tools" ;;
	*:qemu|*:qemu-img)            echo "qemu" ;;

	*)                            echo "$tool" ;;
	esac
}

# Fallback package names when distros rename packages across releases.
pkg_fallback_for() {
	local tool="$1"
	if [ "${PLATFORM:-}" = windows ] && [ "$PKGMGR" = pacman ]; then
		return 0
	fi
	case "$PKGMGR:$tool" in
	apt-get:sevenzip)                            echo "7zip" ;;
	pacman:sevenzip|apk:sevenzip|xbps-install:sevenzip|pkg:sevenzip) echo "p7zip" ;;
	dnf:sevenzip|microdnf:sevenzip|yum:sevenzip) echo "7zip" ;;
	esac
}

# Abstract tool -> binary names to look for (first valid match wins)
tool_binaries() {
	case "$1" in
	curl)     echo "curl" ;;
	python3)  echo "python3 python" ;;
	xorriso)  echo "xorriso" ;;
	sevenzip) echo "7z 7zz 7za" ;;
	qemu)     echo "qemu-system-x86_64 qemu-system-x86_64.exe" ;;
	qemu-img) echo "qemu-img qemu-img.exe" ;;
	*)        echo "$1" ;;
	esac
}

tool_path() {
	local tool="$1" b cand
	case "$tool" in
	python3)
		# On MSYS2/Cygwin prefer the POSIX /usr/bin python over Win32 python.
		if [ "${PLATFORM:-}" = windows ]; then
			for cand in /usr/bin/python3 /usr/bin/python3.exe /usr/bin/python /usr/bin/python.exe; do
				if _valid_python3 "$cand"; then
					printf '%s\n' "$cand"
					return 0
				fi
			done
		fi
		for b in $(tool_binaries python3); do
			while IFS= read -r cand; do
				[ -n "$cand" ] || continue
				if _valid_python3 "$cand"; then
					printf '%s\n' "$cand"
					return 0
				fi
			done < <(_all_in_path "$b")
		done
		if _valid_python3 "$PORTABLE_PY"; then
			printf '%s\n' "$PORTABLE_PY"
			return 0
		fi
		return 1
		;;
	sevenzip)
		for b in $(tool_binaries sevenzip); do
			while IFS= read -r cand; do
				[ -n "$cand" ] || continue
				if _valid_sevenzip "$cand"; then
					printf '%s\n' "$cand"
					return 0
				fi
			done < <(_all_in_path "$b")
		done
		return 1
		;;
	*)
		for b in $(tool_binaries "$tool"); do
			if command -v "$b" >/dev/null 2>&1; then
				command -v "$b"
				return 0
			fi
		done
		return 1
		;;
	esac
}

have_tool() { tool_path "$1" >/dev/null 2>&1; }

install_hint() {
	local tool="$1" pkgs
	pkgs="$(pkg_name_for "$tool")"
	case "$PKGMGR" in
	brew)         echo "brew install $pkgs" ;;
	port)         echo "sudo port install $pkgs" ;;
	apt-get)      echo "sudo apt-get install -y $pkgs" ;;
	dnf)          echo "sudo dnf install -y $pkgs" ;;
	microdnf)     echo "sudo microdnf install -y $pkgs" ;;
	yum)          echo "sudo yum install -y $pkgs" ;;
	pacman)       echo "${SUDO:+$SUDO }pacman -S --noconfirm $pkgs" ;;
	zypper)       echo "sudo zypper install -y $pkgs" ;;
	apk)          echo "sudo apk add $pkgs" ;;
	xbps-install) echo "sudo xbps-install -Sy $pkgs" ;;
	pkg)          echo "sudo pkg install -y $pkgs" ;;
	*)            echo "(no package manager found) install $tool" ;;
	esac
}

_pkgmgr_refreshed=0
refresh_index() {
	[ "$_pkgmgr_refreshed" = 1 ] && return 0
	_pkgmgr_refreshed=1
	case "$PKGMGR" in
	apt-get)      $SUDO apt-get update -qq >/dev/null 2>&1 || true ;;
	brew)         brew update >/dev/null 2>&1 || true ;;
	xbps-install) $SUDO xbps-install -S >/dev/null 2>&1 || true ;;
	esac
	return 0
}

_run_pkgmgr_install() {
	local pkgs="$1" log="$2" rc=1
	# shellcheck disable=SC2086
	case "$PKGMGR" in
	brew)         brew install $pkgs >"$log" 2>&1 && rc=0 ;;
	port)         $SUDO port install $pkgs >"$log" 2>&1 && rc=0 ;;
	apt-get)      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >"$log" 2>&1 && rc=0 ;;
	dnf)          $SUDO dnf install -y -q $pkgs >"$log" 2>&1 && rc=0 ;;
	microdnf)     $SUDO microdnf install -y $pkgs >"$log" 2>&1 && rc=0 ;;
	yum)          $SUDO yum install -y -q $pkgs >"$log" 2>&1 && rc=0 ;;
	pacman)       $SUDO pacman -S --noconfirm --needed $pkgs >"$log" 2>&1 && rc=0 ;;
	zypper)       $SUDO zypper --non-interactive install $pkgs >"$log" 2>&1 && rc=0 ;;
	apk)          $SUDO apk add --quiet $pkgs >"$log" 2>&1 && rc=0 ;;
	xbps-install) $SUDO xbps-install -y $pkgs >"$log" 2>&1 && rc=0 ;;
	pkg)          $SUDO env ASSUME_ALWAYS_YES=yes pkg install -y $pkgs >"$log" 2>&1 && rc=0 ;;
	esac
	return "$rc"
}

install_tool() {
	local tool="$1" pkgs alt log rc=1
	[ -n "$PKGMGR" ] && [ "${CAN_PRIV:-1}" = "1" ] || return 1
	pkgs="$(pkg_name_for "$tool")"
	alt="$(pkg_fallback_for "$tool")"
	printf '   installing: %s (%s)\n' "$tool" "$pkgs" >&2
	refresh_index
	log="$(mktemp "${TMPDIR:-/tmp}/pfdeps.XXXXXX" 2>/dev/null || echo "/tmp/pfdeps.$$")"
	if _run_pkgmgr_install "$pkgs" "$log"; then
		rc=0
	elif [ -n "$alt" ]; then
		printf '   retrying: %s (%s)\n' "$tool" "$alt" >&2
		if _run_pkgmgr_install "$alt" "$log"; then
			rc=0
		fi
	fi
	if [ "$rc" != 0 ] && [ -s "$log" ]; then
		tail -5 "$log" | sed 's/^/     /' >&2
	fi
	rm -f "$log"
	return "$rc"
}

# Downloads a self-contained portable CPython 3 into ~/.cache when the system
# has no Python 3 and package-manager installation is unavailable (e.g. no
# root/sudo privileges or an unsupported Linux distribution).
install_portable_python3() {
	case "${PLATFORM:-}" in
	linux|macos) ;;
	*) return 1 ;;
	esac
	command -v tar >/dev/null 2>&1 || return 1

	local arch triple api_url dl_url tmp_tgz tmp_dir
	case "$(uname -m 2>/dev/null)" in
	x86_64|amd64)  arch="x86_64" ;;
	aarch64|arm64) arch="aarch64" ;;
	armv7*)        arch="armv7" ;;
	ppc64le|riscv64|s390x) arch="$(uname -m)" ;;
	*)             return 1 ;;
	esac

	if [ "$PLATFORM" = macos ]; then
		triple="${arch}-apple-darwin"
	elif [ "$arch" = armv7 ]; then
		triple="armv7-unknown-linux-gnueabihf"
	elif [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; then
		triple="${arch}-unknown-linux-musl"
	else
		triple="${arch}-unknown-linux-gnu"
	fi

	printf '   fetching portable Python 3 for %s (no root required)\n' "$triple" >&2
	api_url="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
	if command -v curl >/dev/null 2>&1; then
		dl_url="$(curl -fsSL --max-time 30 "$api_url" 2>/dev/null \
			| grep -oE "https://github\.com/astral-sh/python-build-standalone/releases/download/[^\"]+/cpython-3\.[0-9]+\.[0-9]+[^\"]*-${triple}-install_only_stripped\.tar\.gz" \
			| head -1 || true)"
	elif command -v wget >/dev/null 2>&1; then
		dl_url="$(wget -q -T 30 -O - "$api_url" 2>/dev/null \
			| grep -oE "https://github\.com/astral-sh/python-build-standalone/releases/download/[^\"]+/cpython-3\.[0-9]+\.[0-9]+[^\"]*-${triple}-install_only_stripped\.tar\.gz" \
			| head -1 || true)"
	fi
	[ -n "$dl_url" ] || return 1

	mkdir -p "$CACHE_ROOT" || return 1
	tmp_tgz="$CACHE_ROOT/_py.tar.gz"
	tmp_dir="$CACHE_ROOT/_py.tmp"
	rm -rf "$tmp_tgz" "$tmp_dir"
	mkdir -p "$tmp_dir" || return 1

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --max-time 300 -o "$tmp_tgz" "$dl_url" || { rm -rf "$tmp_tgz" "$tmp_dir"; return 1; }
	else
		wget -q -T 300 -O "$tmp_tgz" "$dl_url" || { rm -rf "$tmp_tgz" "$tmp_dir"; return 1; }
	fi

	if ! tar -xzf "$tmp_tgz" -C "$tmp_dir" 2>/dev/null || [ ! -x "$tmp_dir/python/bin/python3" ]; then
		rm -rf "$tmp_tgz" "$tmp_dir"
		return 1
	fi
	rm -rf "$tmp_tgz" "$CACHE_ROOT/python"
	mv "$tmp_dir/python" "$CACHE_ROOT/python"
	rmdir "$tmp_dir" 2>/dev/null || true
	_valid_python3 "$PORTABLE_PY"
}

# ensure_tools curl python3 xorriso sevenzip
# Tries to install whatever is missing; if that fails, says what to do.
ensure_tools() {
	local tool missing=()
	for tool in "$@"; do
		have_tool "$tool" || missing+=("$tool")
	done
	[ ${#missing[@]} -eq 0 ] && return 0

	# On macOS with no package manager at all, try to install Homebrew.
	if [ -z "$PKGMGR" ] && [ "$PLATFORM" = macos ] && [ "$AUTO_INSTALL" = 1 ]; then
		printf '== Homebrew not found, installing it (official install script)\n' >&2
		if command -v curl >/dev/null 2>&1 && \
		   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null; then
			local _p
			for _p in /opt/homebrew/bin /usr/local/bin; do
				if [ -x "$_p/brew" ]; then PATH="$_p:$PATH"; export PATH; fi
			done
			detect_platform
		fi
	fi

	if [ "$AUTO_INSTALL" != "1" ]; then
		printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
		for tool in "${missing[@]}"; do
			printf '   %s\n' "$(install_hint "$tool")" >&2
		done
		return 1
	fi

	printf '== installing missing dependencies: %s\n' "${missing[*]}" >&2
	if [ -n "$PKGMGR" ] && [ "${CAN_PRIV:-1}" = "1" ] && [ -n "$SUDO" ]; then
		printf '   (you may be asked for your %s password)\n' "$SUDO" >&2
	fi

	local failed=()
	for tool in "${missing[@]}"; do
		if install_tool "$tool" && have_tool "$tool"; then
			continue
		fi
		if [ "$tool" = "python3" ] && install_portable_python3 && have_tool python3; then
			continue
		fi
		failed+=("$tool")
	done

	if [ ${#failed[@]} -gt 0 ]; then
		printf 'Could not install: %s\n' "${failed[*]}" >&2
		if [ "${CAN_PRIV:-1}" = "0" ] && [ -n "$PKGMGR" ]; then
			printf 'No root/sudo privileges detected. Run as root or install manually:\n' >&2
		else
			printf 'Install manually:\n' >&2
		fi
		for tool in "${failed[@]}"; do
			printf '   %s\n' "$(install_hint "$tool")" >&2
		done
		return 1
	fi
	return 0
}

# --------------------------------------------------------------- browser
# Is there a desktop session? (do not try to open a browser over SSH/headless)
has_display() {
	case "$PLATFORM" in
	macos)   [ -z "${SSH_CONNECTION:-}" ] ;;
	windows) return 0 ;;
	*)       [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] ;;
	esac
}

# open_url <url> -> 0 if opened, 1 otherwise
open_url() {
	local url="$1" opener
	has_display || return 1
	case "$PLATFORM" in
	macos)
		if command -v open >/dev/null 2>&1 && open "$url" >/dev/null 2>&1; then
			return 0
		fi
		;;
	windows)
		for opener in wslview explorer.exe powershell.exe cmd.exe; do
			command -v "$opener" >/dev/null 2>&1 || continue
			case "$opener" in
			wslview)        wslview "$url" >/dev/null 2>&1 && return 0 ;;
			explorer.exe)   explorer.exe "$url" >/dev/null 2>&1 && return 0 ;;
			powershell.exe) powershell.exe -NoProfile -Command "Start-Process '$url'" \
			                    >/dev/null 2>&1 && return 0 ;;
			cmd.exe)        cmd.exe /c start "" "$url" >/dev/null 2>&1 && return 0 ;;
			esac
		done
		;;
	*)
		# Inside WSL this looks like Linux, but wslview opens the Windows browser.
		for opener in xdg-open gio sensible-browser x-www-browser wslview; do
			command -v "$opener" >/dev/null 2>&1 || continue
			case "$opener" in
			gio) gio open "$url" >/dev/null 2>&1 && return 0 ;;
			*)   "$opener" "$url" >/dev/null 2>&1 && return 0 ;;
			esac
		done
		;;
	esac
	return 1
}

# --------------------------------------------------------------- downloads
# The user's download directories, one per line (paths may contain spaces).
download_dirs() {
	local d
	if command -v xdg-user-dir >/dev/null 2>&1; then
		d="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
		if [ -n "$d" ] && [ -d "$d" ]; then printf '%s\n' "$d"; fi
	fi
	for d in "$HOME/Downloads" "$HOME/Desktop"; do
		if [ -d "$d" ]; then printf '%s\n' "$d"; fi
	done
	# The Windows user's Downloads folder, seen from WSL / MSYS2
	for d in /mnt/c/Users/*/Downloads /c/Users/*/Downloads; do
		if [ -d "$d" ]; then printf '%s\n' "$d"; fi
	done
}

download_dirs_uniq() {
	download_dirs | awk '!seen[$0]++'
}
