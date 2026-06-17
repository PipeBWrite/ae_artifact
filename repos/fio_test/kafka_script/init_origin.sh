#!/bin/bash

echo 0 | sudo tee /sys/fs/dsa_emu/prefetch
echo 0 | sudo tee /sys/fs/dsa_emu/no_zero_alloc
echo 0 | sudo tee /sys/fs/dsa_emu/force_node

echo "0:0" | sudo tee /sys/kernel/stats/bg_allowed_dev_name
echo "${stats_use_blkname:-259:0}" | sudo tee /sys/kernel/stats/stats_allowed_dev_name

echo 0 | sudo tee /sys/kernel/stats/stats
