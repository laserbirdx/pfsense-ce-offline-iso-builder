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

# shellcheck disable=SC2034  # PLATFORM/PKGMGR/SUDO are used by the caller
detect_platform() {
	case "$(uname -s 2>/dev/null)" in
	Darwin)               PLATFORM=macos ;;
	MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
	Linux)                PLATFORM=linux ;;
	*)                    PLATFORM=unknown ;;
	esac

	PKGMGR=""
	local m
	for m in brew port pacman apt-get dnf yum zypper apk; do
		if command -v "$m" >/dev/null 2>&1; then
			PKGMGR="$m"
			break
		fi
	done

	# Use sudo when not root and sudo exists (not for Homebrew/MacPorts).
	SUDO=""
	if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && \
	   [ "$PKGMGR" != "brew" ] && [ "$PKGMGR" != "port" ]; then
		if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
	fi
}

# --------------------------------------------------------------- network
# net_check <url> -> 0 if an HTTP(S) request to the URL gets any response.
# Works before dependencies are installed: tries curl, then python, then a
# raw TCP connection through bash's /dev/tcp.
net_check() {
	local url="$1" host port rest
	if command -v curl >/dev/null 2>&1; then
		curl -s -o /dev/null --connect-timeout 8 --max-time 15 "$url" 2>/dev/null && return 0
		return 1
	fi
	local py
	for py in python3 python; do
		if command -v "$py" >/dev/null 2>&1; then
			"$py" - "$url" <<'PY' 2>/dev/null && return 0
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=15)
except urllib.error.HTTPError:
    pass            # the server answered; that is enough
sys.exit(0)
PY
			return 1
		fi
	done
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
		*)        echo "$tool" ;;
		esac
		return
	fi

	case "$PKGMGR:$tool" in
	*:curl)                 echo "curl" ;;

	brew:python3)           echo "python3" ;;
	pacman:python3)         echo "python" ;;
	*:python3)              echo "python3" ;;

	pacman:xorriso)         echo "libisoburn" ;;
	*:xorriso)              echo "xorriso" ;;

	apt-get:sevenzip)       echo "p7zip-full" ;;
	dnf:sevenzip|yum:sevenzip) echo "p7zip p7zip-plugins" ;;
	brew:sevenzip)          echo "sevenzip" ;;
	port:sevenzip)          echo "p7zip" ;;
	*:sevenzip)             echo "p7zip" ;;

	apt-get:qemu)           echo "qemu-system-x86 qemu-utils" ;;
	dnf:qemu|yum:qemu)      echo "qemu-system-x86 qemu-img" ;;
	pacman:qemu)            echo "qemu-base" ;;
	zypper:qemu)            echo "qemu-x86 qemu-tools" ;;
	apk:qemu)               echo "qemu-system-x86_64 qemu-img" ;;
	*:qemu)                 echo "qemu" ;;

	*)                      echo "$tool" ;;
	esac
}

# Abstract tool -> binary names to look for (first match wins)
tool_binaries() {
	case "$1" in
	curl)     echo "curl" ;;
	python3)  echo "python3 python" ;;
	xorriso)  echo "xorriso" ;;
	sevenzip) echo "7z 7zz 7za 7zr" ;;
	qemu)     echo "qemu-system-x86_64 qemu-system-x86_64.exe" ;;
	qemu-img) echo "qemu-img qemu-img.exe" ;;
	*)        echo "$1" ;;
	esac
}

tool_path() {
	local b
	for b in $(tool_binaries "$1"); do
		if command -v "$b" >/dev/null 2>&1; then
			command -v "$b"
			return 0
		fi
	done
	return 1
}

have_tool() { tool_path "$1" >/dev/null 2>&1; }

install_hint() {
	local tool="$1" pkgs
	pkgs="$(pkg_name_for "$tool")"
	case "$PKGMGR" in
	brew)    echo "brew install $pkgs" ;;
	port)    echo "sudo port install $pkgs" ;;
	apt-get) echo "sudo apt-get install -y $pkgs" ;;
	dnf)     echo "sudo dnf install -y $pkgs" ;;
	yum)     echo "sudo yum install -y $pkgs" ;;
	pacman)  echo "sudo pacman -S --noconfirm $pkgs" ;;
	zypper)  echo "sudo zypper install -y $pkgs" ;;
	apk)     echo "sudo apk add $pkgs" ;;
	*)       echo "(no package manager found) install $tool" ;;
	esac
}

_pkgmgr_refreshed=0
refresh_index() {
	[ "$_pkgmgr_refreshed" = 1 ] && return 0
	_pkgmgr_refreshed=1
	case "$PKGMGR" in
	apt-get) $SUDO apt-get update -qq >/dev/null 2>&1 || true ;;
	brew)    brew update >/dev/null 2>&1 || true ;;
	esac
	return 0
}

install_tool() {
	local tool="$1" pkgs rc=1
	pkgs="$(pkg_name_for "$tool")"
	printf '   installing: %s (%s)\n' "$tool" "$pkgs" >&2
	refresh_index
	# shellcheck disable=SC2086
	case "$PKGMGR" in
	brew)    brew install $pkgs >/dev/null 2>&1 && rc=0 ;;
	port)    $SUDO port install $pkgs >/dev/null 2>&1 && rc=0 ;;
	apt-get) $SUDO apt-get install -y -qq $pkgs >/dev/null 2>&1 && rc=0 ;;
	dnf)     $SUDO dnf install -y -q $pkgs >/dev/null 2>&1 && rc=0 ;;
	yum)     $SUDO yum install -y -q $pkgs >/dev/null 2>&1 && rc=0 ;;
	pacman)  $SUDO pacman -S --noconfirm --needed $pkgs >/dev/null 2>&1 && rc=0 ;;
	zypper)  $SUDO zypper --non-interactive install $pkgs >/dev/null 2>&1 && rc=0 ;;
	apk)     $SUDO apk add --quiet $pkgs >/dev/null 2>&1 && rc=0 ;;
	esac
	return "$rc"
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

	if [ "$AUTO_INSTALL" != "1" ] || [ -z "$PKGMGR" ]; then
		printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
		for tool in "${missing[@]}"; do
			printf '   %s\n' "$(install_hint "$tool")" >&2
		done
		return 1
	fi

	printf '== installing missing dependencies: %s\n' "${missing[*]}" >&2
	if [ -n "$SUDO" ]; then
		printf '   (you may be asked for your sudo password)\n' >&2
	fi

	local failed=()
	for tool in "${missing[@]}"; do
		if install_tool "$tool" && have_tool "$tool"; then
			continue
		fi
		failed+=("$tool")
	done

	if [ ${#failed[@]} -gt 0 ]; then
		printf 'Could not install: %s\n' "${failed[*]}" >&2
		printf 'Install manually:\n' >&2
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
