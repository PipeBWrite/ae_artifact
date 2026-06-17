#!/bin/bash

# set +x

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <iothread> <producer> <io_cpu> <producer_cpu>"
    exit 1
fi

IOTHREAD=$1
PRODUCER=$2
IO_CPU=$3
PRODUCER_CPU=$4

sed \
    -e "s|exec taskset -c [^ ]* \$base_dir/kafka-run-class.sh|exec taskset -c $IO_CPU \$base_dir/kafka-run-class.sh|g" \
    -e "s|exec \$base_dir/kafka-run-class.sh|exec taskset -c $IO_CPU \$base_dir/kafka-run-class.sh|g" \
    "$START_FILE" > "$START_FILE_TMP"

sed  \
    -e "s|exec taskset -c [^ ]* \$(dirname \$0)/kafka-run-class.sh org.apache.kafka.tools.ProducerPerformance \"\$@\"|exec taskset -c $PRODUCER_CPU \$(dirname \$0)/kafka-run-class.sh org.apache.kafka.tools.ProducerPerformance \"\$@\"|g" \
    -e "s|exec taskset -c \$(dirname \$0)/kafka-run-class.sh org.apache.kafka.tools.ProducerPerformance \"\$@\"|exec taskset -c $PRODUCER_CPU \$(dirname \$0)/kafka-run-class.sh org.apache.kafka.tools.ProducerPerformance \"\$@\"|g" \
    "$TEST_FILE" > "$TEST_FILE_TMP"

sed  "s/^num.io.threads=.*/num.io.threads=$IOTHREAD/" "$CONFIG_FILE" > "$CONFIG_FILE_TMP"
if [[ -n "${KAFKA_METADATA_LOG_DIR:-}" ]]; then
  echo "metadata.log.dir=${KAFKA_METADATA_LOG_DIR}" >> "$CONFIG_FILE_TMP"
fi

chmod +x "$START_FILE_TMP" "$TEST_FILE_TMP"

echo "Generated config file: $START_FILE_TMP" "$TEST_FILE_TMP" "$CONFIG_FILE_TMP"
