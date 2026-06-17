# set +x

source "${BENCH_DIR}"/utils.sh
bash $BENCH_DIR/kafka_script/init_origin.sh

init_pmem
if [[ -n "${KAFKA_METADATA_LOG_DIR:-}" ]]; then
  sudo rm -rf "${KAFKA_METADATA_LOG_DIR}"
  sudo mkdir -p "${KAFKA_METADATA_LOG_DIR}"
  sudo chown -R "${RUN_USER:-$USER}" "${KAFKA_METADATA_LOG_DIR}"
fi
sudo mkdir /mnt/pmem/kafka-logs
sudo chown -R "${RUN_USER:-$USER}" /mnt/pmem/kafka-logs
sudo chmod -R 755 /mnt/pmem/kafka-logs

pushd $kafka_DIR
KAFKA_CLUSTER_ID="$($kafka_DIR/bin/kafka-storage.sh random-uuid)"
$kafka_DIR/bin/kafka-storage.sh format --standalone -t $KAFKA_CLUSTER_ID -c "$CONFIG_FILE_TMP"

"$START_FILE_TMP" "$CONFIG_FILE_TMP" > "$BENCH_DIR/kafka_script/kafka-info.log" 2>&1 &

sleep 5s

echo "------ Kafka started, you can check $BENCH_DIR/kafka_script/kafka-info.log for further information ------"
$kafka_DIR/bin/kafka-topics.sh \
    --create --topic test-topic \
    --bootstrap-server localhost:9092 \
    --partitions "${KAFKA_PARTITIONS:-4}" --replication-factor 1

echo "------ Topic created successfully ------"
