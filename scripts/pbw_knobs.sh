#!/usr/bin/env bash
# Common PBW knob baseline.

_pbw_w() {
	local val="$1" path="$2"
	[[ -e "$path" ]] || return 0
	printf '%s\n' "$val" | sudo tee "$path" >/dev/null 2>&1 || true
}

pbw_reset_knobs() {
	# background workers / NUMA placement -> idle
	_pbw_w 0   /sys/fs/dsa_emu/num_threads
	_pbw_w 0   /sys/fs/dsa_emu/dsa_emu_thread_numa
	_pbw_w 0   /sys/fs/dsa_emu/enable_bdp
	_pbw_w 0   /sys/fs/dsa_emu/force_node
	_pbw_w 0   /sys/fs/dsa_emu/force_node_nid
	_pbw_w 0   /sys/fs/dsa_emu/prefetch
	_pbw_w 0   /sys/fs/dsa_emu/no_zero_alloc
	_pbw_w 0   /sys/fs/dsa_emu/disable_batching
	# ext4 de-stall / batching -> off
	_pbw_w 0   /sys/fs/dsa_emu/fg_bwb_all
	_pbw_w 0   /sys/fs/dsa_emu/bg_batch_handle
	# bg-fsync pacing -> off, default flush threshold
	_pbw_w off    /sys/fs/dsa_emu/debug_bg_fsync
	_pbw_w 65536  /sys/fs/dsa_emu/debug_dirty_threshold
	# folio pool order / sync-fallback threshold -> kernel defaults
	_pbw_w 4   /sys/fs/dsa_emu/folio_pool_order_max
	_pbw_w 100 /sys/fs/dsa_emu/fg_alloc_threshold
	_pbw_w 0   /sys/fs/dsa_emu/sync_fallback_threshold
	_pbw_w 0   /sys/fs/dsa_emu/backoff_threshold_ns
	_pbw_w on  /sys/fs/dsa_emu/sfr_drain
	# stats bg gating off; StreamCache pool off
	_pbw_w 0:0 /sys/kernel/stats/bg_allowed_dev_name
	_pbw_w 0   /sys/fs/sc_memory/enabled
}
