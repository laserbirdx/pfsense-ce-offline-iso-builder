#!/usr/bin/env bash
# Disk space estimation and check.
#
# Public API:
#   free_kb <path>             free KiB on the file system holding <path>
#   dir_kb <path>              KiB used by a directory (0 if missing)
#   human_kb <kib>             human-readable size
#   check_space <out> <mirror> <n_versions> <n_isos> <n_memsticks> \
#               <installer_bytes> <full_mirror 0|1>
#
# All paths may contain spaces.

# Walk up to the nearest existing directory.
_existing_dir() {
	local p="$1"
	while [ ! -d "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
		p="$(dirname "$p")"
	done
	printf '%s\n' "$p"
}

# df -Pk gives the same column layout on GNU and BSD. Mount points with spaces
# only affect the last column; we read column 4 (available).
free_kb() {
	local p
	p="$(_existing_dir "$1")"
	df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4+0}'
}

dir_kb() {
	if [ ! -d "$1" ]; then echo 0; return; fi
	du -sk "$1" 2>/dev/null | awk '{print $1+0}'
}

human_kb() {
	awk -v k="$1" 'BEGIN {
		split("KiB MiB GiB TiB", u, " ")
		i = 1
		while (k >= 1024 && i < 4) { k /= 1024; i++ }
		printf "%.1f%s", k, u[i]
	}'
}

# Are both paths on the same file system?
same_fs() {
	local a b da db
	a="$(_existing_dir "$1")"
	b="$(_existing_dir "$2")"
	da="$(df -Pk "$a" 2>/dev/null | awk 'NR==2 {print $1}')"
	db="$(df -Pk "$b" 2>/dev/null | awk 'NR==2 {print $1}')"
	[ -n "$da" ] && [ "$da" = "$db" ]
}

# Rough estimate in KiB; runs before any repository metadata is downloaded.
estimate_kb() {
	local nver="$1" niso="$2" nmem="$3" inst_bytes="$4" full="$5"
	local per_mirror_kb inst_kb
	if [ "$full" = 1 ]; then
		per_mirror_kb=$((1600 * 1024))   # ~1.6 GB full repository
	else
		per_mirror_kb=$((550 * 1024))    # ~550 MB dependency closure
	fi
	inst_kb=$(( inst_bytes / 1024 ))

	MIRROR_EST_KB=$(( nver * per_mirror_kb ))
	# ISO = installer + that version's mirror
	ISO_EST_KB=$(( niso * (inst_kb + per_mirror_kb) ))
	# memstick = ISO + 1 GB headroom
	MEM_EST_KB=$(( nmem * (inst_kb + per_mirror_kb + 1024 * 1024) ))
	# working area: extracted scripts + boot images
	WORK_EST_KB=$(( 64 * 1024 ))
	OUT_EST_KB=$(( ISO_EST_KB + MEM_EST_KB + WORK_EST_KB ))
}

# 0 = enough space, 1 = not enough
check_space() {
	local outdir="$1" mirrordir="$2"
	local nver="$3" niso="$4" nmem="$5" inst_bytes="$6" full="$7"

	estimate_kb "$nver" "$niso" "$nmem" "$inst_bytes" "$full"

	local have_mirror_kb need_mirror_kb
	have_mirror_kb="$(dir_kb "$mirrordir")"
	need_mirror_kb=$(( MIRROR_EST_KB - have_mirror_kb ))
	if [ "$need_mirror_kb" -lt 0 ]; then need_mirror_kb=0; fi

	printf '== disk space\n'
	printf '   mirror : ~%s needed (%s already present)  -> %s\n' \
		"$(human_kb "$MIRROR_EST_KB")" "$(human_kb "$have_mirror_kb")" "$mirrordir"
	printf '   output : ~%s needed                       -> %s\n' \
		"$(human_kb "$OUT_EST_KB")" "$outdir"

	local short=0
	if same_fs "$outdir" "$mirrordir"; then
		local need free
		need=$(( need_mirror_kb + OUT_EST_KB ))
		free="$(free_kb "$outdir")"
		printf '   free   : %s (same disk, ~%s needed in total)\n' \
			"$(human_kb "${free:-0}")" "$(human_kb "$need")"
		if [ "${free:-0}" -lt "$need" ]; then short=1; fi
	else
		local fo fm
		fo="$(free_kb "$outdir")"; fm="$(free_kb "$mirrordir")"
		printf '   free   : output %s | mirror %s\n' \
			"$(human_kb "${fo:-0}")" "$(human_kb "${fm:-0}")"
		if [ "${fo:-0}" -lt "$OUT_EST_KB" ]; then short=1; fi
		if [ "${fm:-0}" -lt "$need_mirror_kb" ]; then short=1; fi
	fi

	if [ "$short" != 0 ]; then
		printf '\nNot enough disk space.\n' >&2
		printf 'Options:\n' >&2
		printf '   write to another disk with -o / -M\n' >&2
		printf '   skip this check with --skip-space-check\n' >&2
		return 1
	fi
	return 0
}
