#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${COMMAND_DATASET_DIR:-$SCRIPT_DIR/generate_dir}"
FILE_COUNT="${COMMAND_DATASET_FILES:-10}"
FILE_SIZE="${COMMAND_DATASET_FILE_SIZE:-300M}"

mkdir -p "$OUT_DIR"
for i in $(seq 1 "$FILE_COUNT"); do
    dd if=/dev/urandom of="$OUT_DIR/file_$i" bs="$FILE_SIZE" count=1 status=none
done
echo "generate done: $FILE_COUNT files x $FILE_SIZE in $OUT_DIR"
