#!/usr/bin/env bash

# Shared command-tools sysfs setup. Keep non-worker configuration here so
# BW/PBW/StreamCache command-line runs do not drift.

COMMAND_TOOLS_READ_AHEAD_SYSFS="${COMMAND_TOOLS_READ_AHEAD_SYSFS:-}"
COMMAND_TOOLS_ORIG_READ_AHEAD_KB="${COMMAND_TOOLS_ORIG_READ_AHEAD_KB:-}"
COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB="${COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB:-}"

command_tools_write_sysfs() {
	local value="$1"
	local path="$2"
	if [[ -e "$path" ]]; then
		local current=""
		current="$(sudo cat "$path" 2>/dev/null | head -n 1 || true)"
		if [[ "$current" == "$value" ]]; then
			return 0
		fi
		printf '%s\n' "$value" | sudo tee "$path" >/dev/null
	fi
}

command_tools_set_readahead() {
	local device="$1"
	local read_ahead_kb="$2"
	local out_file="$3"
	local label="${4:-command-tools}"
	local dev_name

	dev_name="$(basename "$device")"
	COMMAND_TOOLS_READ_AHEAD_SYSFS="/sys/class/block/$dev_name/queue/read_ahead_kb"
	if [[ ! -e "$COMMAND_TOOLS_READ_AHEAD_SYSFS" ]]; then
		printf 'missing read-ahead control: %s\n' "$COMMAND_TOOLS_READ_AHEAD_SYSFS" >&2
		return 1
	fi

	COMMAND_TOOLS_ORIG_READ_AHEAD_KB="$(cat "$COMMAND_TOOLS_READ_AHEAD_SYSFS")"
	printf '%s\n' "$read_ahead_kb" | sudo tee "$COMMAND_TOOLS_READ_AHEAD_SYSFS" >/dev/null
	COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB="$(cat "$COMMAND_TOOLS_READ_AHEAD_SYSFS")"
	printf '%s read_ahead_kb: %s -> %s (%s)\n' \
		"$label" "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" "$COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB" "$COMMAND_TOOLS_READ_AHEAD_SYSFS"
	printf 'path=%s\norig_read_ahead_kb=%s\nactive_read_ahead_kb=%s\n' \
		"$COMMAND_TOOLS_READ_AHEAD_SYSFS" "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" "$COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB" >"$out_file"
}

command_tools_restore_readahead() {
	if [[ -n "$COMMAND_TOOLS_READ_AHEAD_SYSFS" && -n "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" && -e "$COMMAND_TOOLS_READ_AHEAD_SYSFS" ]]; then
		printf '%s\n' "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" | sudo tee "$COMMAND_TOOLS_READ_AHEAD_SYSFS" >/dev/null 2>&1 || true
	fi
}

command_tools_configure_common() {
	local stat_dev="$1"

	command_tools_write_sysfs "$stat_dev" /sys/kernel/stats/stats_allowed_dev_name
	command_tools_write_sysfs 0 /sys/kernel/stats/stats
	command_tools_write_sysfs 0 /sys/fs/sc_memory/enabled
	command_tools_write_sysfs -1 /sys/fs/dsa_emu/dsa_emu_thread_numa
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/enable_bdp
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/force_node
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/force_node_nid
	command_tools_write_sysfs 0 /proc/sys/kernel/numa_balancing
	command_tools_write_sysfs 2 /sys/fs/dsa_emu/fpool_lock_wait_count
}

command_tools_configure_orig() {
	local stat_dev="$1"

	command_tools_configure_common "$stat_dev"
	command_tools_write_sysfs 0 /sys/kernel/stats/bg_allowed_dev_name
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/num_threads
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/prefetch
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
	command_tools_write_sysfs 1 /sys/kernel/stats/thread_init
}

command_tools_configure_pbw() {
	local stat_dev="$1"

	command_tools_configure_common "$stat_dev"
	command_tools_write_sysfs "$stat_dev" /sys/kernel/stats/bg_allowed_dev_name
	command_tools_write_sysfs 16 /sys/fs/dsa_emu/num_threads
	command_tools_write_sysfs 1 /sys/fs/dsa_emu/prefetch
	command_tools_write_sysfs 40 /sys/fs/dsa_emu/fg_alloc_threshold
	command_tools_write_sysfs 2 /sys/fs/dsa_emu/force_node
	command_tools_write_sysfs 2 /sys/fs/dsa_emu/no_zero_alloc
	command_tools_write_sysfs 1 /sys/kernel/stats/thread_init
}

command_tools_configure_scache() {
	local stat_dev="$1"
	local bg_dev="$2"
	local nr_regions="$3"

	command_tools_configure_common "$stat_dev"
	command_tools_write_sysfs "$bg_dev" /sys/kernel/stats/bg_allowed_dev_name
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/prefetch
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
	command_tools_write_sysfs 0 /sys/fs/dsa_emu/num_threads
	command_tools_write_sysfs "$nr_regions" /sys/fs/sc_memory/nr_regions
	command_tools_write_sysfs 1 /sys/fs/sc_memory/enabled
	command_tools_write_sysfs 1 /sys/kernel/stats/thread_init
}

command_tools_configure_mode() {
	local mode="$1"
	local stat_dev="$2"

	case "$mode" in
		orig)
			command_tools_configure_orig "$stat_dev"
			;;
		async|pbw)
			command_tools_configure_pbw "$stat_dev"
			;;
		*)
			printf 'unknown command-tools mode: %s\n' "$mode" >&2
			return 1
			;;
	esac
}
