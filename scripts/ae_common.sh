#!/usr/bin/env bash

set -euo pipefail

# --- Top-level infrastructure configuration (the only place paths/device are set) ---
AE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE_ROOT="$(cd "$AE_SCRIPT_DIR/.." && pwd)"

if [[ -z "${LINUX_DIR:-}" ]]; then
	if [[ -d "$AE_ROOT/../linux" ]]; then
		LINUX_DIR="$(cd "$AE_ROOT/../linux" && pwd)"
	else
		LINUX_DIR="$HOME/linux"
	fi
fi
FIO_TEST_DIR="$AE_ROOT/repos/fio_test"
YCSB_CPP_DIR="$AE_ROOT/repos/YCSB-cpp"
COMMAND_TEST_DIR="$AE_ROOT/repos/command_test"
KAFKA_HOME="${KAFKA_HOME:-$AE_ROOT/repos/kafka_2.13-4.0.0}"
if [[ -n "${AE_JAVA_HOME:-}" ]]; then
	JAVA_HOME="$AE_JAVA_HOME"
elif [[ -n "${JAVA_HOME:-}" ]]; then
	JAVA_HOME="$JAVA_HOME"
else
	JAVA_BIN="$(command -v java 2>/dev/null || true)"
	if [[ -n "$JAVA_BIN" ]]; then
		JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")"
	else
		JAVA_HOME=""
	fi
fi
JAVA_CMD="${AE_JAVA_CMD:-${JAVA_HOME:+$JAVA_HOME/bin/java}}"

AE_DEVICE="${AE_DEVICE:-/dev/nvme0n1}"
AE_MOUNT="${AE_MOUNT:-/mnt/pmem}"
AE_RESULTS_DIR="${AE_RESULTS_DIR:-$AE_ROOT/results}"
export AE_DEVICE AE_MOUNT AE_RESULTS_DIR LINUX_DIR KAFKA_HOME JAVA_HOME JAVA_CMD
if [[ -n "$JAVA_HOME" ]]; then
	export PATH="$JAVA_HOME/bin:$PATH"
fi

# --- Common test configuration ---
DIRTY_RATIO=99
DIRTY_BACKGROUND_RATIO=99

PBW_KNOBS_LIB="$AE_SCRIPT_DIR/pbw_knobs.sh"
export PBW_KNOBS_LIB
# shellcheck source=pbw_knobs.sh
[[ -f "$PBW_KNOBS_LIB" ]] && source "$PBW_KNOBS_LIB"

log() {
	printf '[ae] %s\n' "$*"
}

die() {
	printf '[ae] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_dir() {
	[[ -d "$1" ]] || die "missing directory: $1"
}

require_file() {
	[[ -f "$1" ]] || die "missing file: $1"
}

device_majmin() {
	lsblk -rno PATH,MAJ:MIN 2>/dev/null | awk -v dev="$AE_DEVICE" '$1 == dev { print $2; found=1; exit } END { exit found ? 0 : 1 }'
}

device_exists() {
	[[ -b "$AE_DEVICE" ]] || lsblk -rno PATH 2>/dev/null | awk -v dev="$AE_DEVICE" '$1 == dev { found=1; exit } END { exit found ? 0 : 1 }'
}

export_device_majmin() {
	local majmin
	majmin="$(device_majmin)"
	[[ -n "$majmin" ]] || die "cannot resolve major:minor for AE_DEVICE=$AE_DEVICE"
	export AE_DEVICE_MAJMIN="$majmin"
}

require_passwordless_sudo() {
	sudo -n true >/dev/null 2>&1 || die "passwordless sudo is required for full runs"
}

confirm_disposable_device() {
	log "destructive run on configured device $AE_DEVICE (mount $AE_MOUNT) -- must be disposable"
}

run_envsetup() {
	"$AE_SCRIPT_DIR/envsetup.sh"
}

preflight_repos() {
	require_dir "$LINUX_DIR"
	require_dir "$FIO_TEST_DIR"
	require_dir "$YCSB_CPP_DIR"
	require_dir "$COMMAND_TEST_DIR"
	require_dir "$KAFKA_HOME"
	[[ -n "$JAVA_HOME" ]] || die "JAVA_HOME is unset and java was not found; install OpenJDK 17 or set AE_JAVA_HOME"
	require_dir "$JAVA_HOME"
	require_file "$JAVA_CMD"
}

preflight_kernel_surfaces() {
	[[ -d /sys/fs/dsa_emu ]] || die "missing /sys/fs/dsa_emu; boot the PBW kernel first"
	[[ -f /sys/kernel/stats/stats ]] || die "missing /sys/kernel/stats/stats; stats module is not available"
	[[ -d /sys/fs/sc_memory ]] || log "warning: /sys/fs/sc_memory missing; StreamCache mode will be unavailable"
}

preflight_device() {
	device_exists || die "AE_DEVICE is not visible as a block device: $AE_DEVICE"
	mkdir -p "$AE_RESULTS_DIR"
}

timestamp_utc() {
	date -u +%Y%m%dT%H%M%SZ
}
