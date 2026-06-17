#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <tag>"
    exit 1
fi

source ./fio_config
_tag=$1
mkdir -p ./results/$_tag

if [[ -f ./results/latest.txt ]]; then
	rm ./results/latest.txt
fi
echo $_tag > ./results/latest.txt
echo "$(date)        $_tag" >> ./results/hist.txt

if [[ -d tmp_result ]]; then
	sudo cp -a tmp_result/* ./results/$_tag/
	sudo rm -rf tmp_result
fi
cp fio_config ./results/$_tag
detect_runtime_var >> ./results/$_tag/fio_config

sudo cp *.py *.sh fio_config ./results/$_tag

source ./fio_config
if [[ -n "$debug_custom_bin" ]]; then
	sudo cp $debug_custom_bin ./results/$_tag
fi

source ./utils.sh

export LINUX_DIR="${LINUX_DIR:-$HOME/linux}"
export BENCH_DIR=`pwd`

name "$LINUX_DIR" "linux" > ./results/$_tag/linux
name "$BENCH_DIR" "bench" > ./results/$_tag/bench

sudo chown -R "${RUN_USER:-${SUDO_USER:-$USER}}" ./results/$_tag

# Check the inum and replace the inum in tag
test_ino=$(stat -c %i /mnt/pmem/bench.0.0)

sed -i "s/test_ino=.*/test_ino=$test_ino/" ./results/$_tag/fio_process_tbl.sh
sed -i "s/test_ino=.*/test_ino=$test_ino/" ./results/$_tag/fio_process_stats.sh

mv *.typ ./results/$_tag
