#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--help|-h)
			cat <<'EOF'
Usage: scripts/envsetup.sh

Prepares host-level settings without formatting or mounting the test device:
  - verifies copied repositories and PBW sysfs surfaces
  - records host/kernel/device state under results/envsetup_*
  - sets stats/thread initialization
  - disables SMT
  - sets CPU governor to performance when cpupower is available

Benchmark wrappers still configure their own mode-specific PBW/StreamCache
knobs before each run.
EOF
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

preflight_repos
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin

write_sysfs() {
	local value="$1"
	local path="$2"
	if [[ -e "$path" ]]; then
		local current=""
		current="$(sudo -n cat "$path" 2>/dev/null | head -n 1 || true)"
		if [[ "$current" == "$value" ]]; then
			return
		fi
		printf '%s\n' "$value" | sudo -n tee "$path" >/dev/null 2>/dev/null || true
	fi
}

ts="$(timestamp_utc)"
out_dir="$AE_RESULTS_DIR/envsetup_$ts"
mkdir -p "$out_dir"
ln -sfn "$out_dir" "$AE_RESULTS_DIR/envsetup_latest"

{
	printf 'AE_ROOT=%s\n' "$AE_ROOT"
	printf 'LINUX_DIR=%s\n' "$LINUX_DIR"
	printf 'FIO_TEST_DIR=%s\n' "$FIO_TEST_DIR"
	printf 'YCSB_CPP_DIR=%s\n' "$YCSB_CPP_DIR"
	printf 'COMMAND_TEST_DIR=%s\n' "$COMMAND_TEST_DIR"
	printf 'LOG_BENCH_DIR=%s\n' "$AE_ROOT/repos/log_bench"
	printf 'AE_DEVICE=%s\n' "$AE_DEVICE"
	printf 'AE_DEVICE_MAJMIN=%s\n' "$AE_DEVICE_MAJMIN"
	printf 'AE_MOUNT=%s\n' "$AE_MOUNT"
	printf 'smt_enabled=%s\n' 0
} > "$out_dir/env.env"

uname -a > "$out_dir/uname.txt"
lscpu > "$out_dir/lscpu.txt" 2>&1 || true
lsblk -o NAME,PATH,MAJ:MIN,SIZE,FSTYPE,MOUNTPOINTS,RO,MODEL > "$out_dir/lsblk.txt" 2>&1 || true
findmnt > "$out_dir/findmnt.txt" 2>&1 || true
cat /proc/cmdline > "$out_dir/proc_cmdline.txt" 2>&1 || true

log "initializing kernel stats and default sysfs state"
write_sysfs 1 /sys/kernel/stats/thread_init
write_sysfs "$AE_DEVICE_MAJMIN" /sys/kernel/stats/stats_allowed_dev_name
write_sysfs 0 /sys/kernel/stats/stats
write_sysfs 0 /sys/kernel/stats/bg_allowed_dev_name

pbw_reset_knobs

log "disabling SMT"
write_sysfs 0 /sys/fs/dsa_emu/smt_on
printf 'off\n' | sudo -n tee /sys/devices/system/cpu/smt/control >/dev/null 2>/dev/null || true

if [[ -x "$LINUX_DIR/tools/power/cpupower/cpupower" ]]; then
	log "setting CPU governor to performance with copied kernel cpupower"
	(
		cd "$LINUX_DIR/tools/power/cpupower"
		sudo -n env LD_LIBRARY_PATH="$PWD" ./cpupower frequency-set -g performance
	) > "$out_dir/cpupower.log" 2>&1 || true
elif command -v cpupower >/dev/null 2>&1; then
	log "setting CPU governor to performance with system cpupower"
	sudo -n cpupower frequency-set -g performance > "$out_dir/cpupower.log" 2>&1 || true
else
	log "cpupower not found; skipping CPU governor setup"
fi

sudo -n sysctl "vm.dirty_ratio=$DIRTY_RATIO" > "$out_dir/sysctl_dirty_ratio.log" 2>&1 || true
sudo -n sysctl "vm.dirty_background_ratio=$DIRTY_BACKGROUND_RATIO" >> "$out_dir/sysctl_dirty_ratio.log" 2>&1 || true

sudo -n cat /sys/kernel/stats/stats > "$out_dir/stats_after.txt" 2>/dev/null || true
log "envsetup complete: $out_dir"
