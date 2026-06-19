# PipeBWrite Artifact

This checkout contains the runnable benchmark harness and pinned local
dependencies for the PipeBWrite artifact. The wrapper scripts use the paths and
device configured in `scripts/ae_common.sh`.

## Quick Start

From a clean working directory, clone the kernel and artifact repositories as
sibling directories:

```bash
git clone https://github.com/PipeBWrite/linux.git
git clone https://github.com/PipeBWrite/ae_artifact.git ae_artifact
cd ae_artifact
```

## Layout

- `scripts/`: top-level checks, setup, full-suite runner, and per-benchmark wrappers.
- `repos/`: benchmark repositories and pinned runtime inputs, including
  `YCSB-cpp`, `fio_test`, `command_test`, `log_bench`, and Kafka.
- `results/`: timestamped run outputs created by the scripts.
- `output/`: generated `.dat` files and rendered figures.

## Preparation

These steps assume Ubuntu 24.04. The artifact does not vendor a JDK; install
OpenJDK 17 from the system package manager or set `AE_JAVA_HOME` to another JDK
17 installation.

Install host packages:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake pkg-config git curl \
  flex bison libssl-dev libelf-dev dwarves cpio \
  openjdk-17-jdk-headless maven \
  librocksdb-dev libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev liburing-dev \
  fio jq ripgrep sysstat bc xfsprogs e2fsprogs util-linux gnuplot-nox
```

Build and install the PBW kernel from the sibling `linux` checkout. The scripts
derive the artifact root from their own location, then default `LINUX_DIR` to a
sibling `../linux` directory and finally to `$HOME/linux`; set `LINUX_DIR` only
if you use a different layout. The kernel tree includes
`arch/x86/configs/pbw_ae_defconfig`, generated from the known-good AE `.config`.

```bash
cd ae_artifact
export LINUX_DIR="${LINUX_DIR:-$(cd ../linux && pwd)}"
make -C "$LINUX_DIR" pbw_ae_defconfig
make -C "$LINUX_DIR" olddefconfig
make -C "$LINUX_DIR" -j"$(nproc)"
sudo make -C "$LINUX_DIR" modules_install
sudo make -C "$LINUX_DIR" install
sudo reboot
```

After reboot, select the installed `6.9.0-dsamod+` kernel if your bootloader
does not choose it automatically, then verify:

```bash
uname -r
test -f "$LINUX_DIR/arch/x86/boot/bzImage"
test -d /sys/fs/dsa_emu
test -f /sys/kernel/stats/stats
```

Build the workload artifacts that are intentionally not tracked by git:

```bash
make -C repos/YCSB-cpp -j"$(nproc)" \
  BIND_ROCKSDB=1 \
  ROCKSDB_LIB="$(pkg-config --variable=libdir rocksdb)/librocksdb.a -luring -lgflags -lsnappy -lz -lbz2 -llz4 -lzstd -lrt -ldl"

(cd repos/log_bench/java-logger-benchmark && \
  mvn -pl jmh-benchmarks -am -DskipTests package dependency:copy-dependencies)
```

The YCSB command above creates `repos/YCSB-cpp/ycsb` and links RocksDB from the
installed static library reported by `pkg-config rocksdb` (we use RocksDB 10.2.1).
The Log4j command creates `repos/log_bench/java-logger-benchmark/jmh-benchmarks/target/dependency`.

Finally verify the prepared environment:

```bash
scripts/check_env.sh
```

`check_env.sh` should report the prepared binaries, `repos/YCSB-cpp/ycsb`,
Log4j's `jmh-benchmarks/target/dependency`, the Kafka scripts, passwordless
`sudo`, the disposable block device, and the PBW sysfs surfaces
(`/sys/fs/dsa_emu` and `/sys/kernel/stats/stats`).

## Preflight

**The benchmark device is destructive.** By default the scripts use
`/dev/nvme0n1` mounted at `/mnt/pmem`; change `scripts/ae_common.sh` only if the
review host uses a different disposable device.

```bash
scripts/check_env.sh
scripts/envsetup.sh
```

`check_env.sh` verifies the required local repositories, Java runtime, kernel
sysfs surfaces, and benchmark device. `envsetup.sh` records host state and
applies the shared CPU/sysfs setup used by the benchmark wrappers.

## Full Run

Expected wall-clock time for a complete `scripts/run_all.sh` run is roughly
8-10 hours on the AE host.

```bash
scripts/run_all.sh
```

The full suite runs RocksDB, Kafka, command-line tools, FIO, Log4j and ablation tests, and
plots figures in the paper.

The top-level status file is written to `results/full_ae_<timestamp>/FULL_AE.md`,
with exact output paths in `results/full_ae_<timestamp>/manifest.env`.

## Final Figures

After `scripts/run_all.sh` completes, the final rendered figures are under
`output/figures/`. The generated figure input `.dat` files are under
`output/raw_data/`, and the full-suite manifest records these paths as
`output_figures_dir` and `output_raw_data_dir`.

Paper figure mapping:

| Paper figure | Content | Rendered output |
|---|---|---|
| Figure 7 | RocksDB | `output/figures/RocksDB/formal_1_throughput.pdf`, `output/figures/RocksDB/formal_2_update_lat.pdf` |
| Figure 8 | Kafka | `output/figures/Kafka/producer_combined.pdf` |
| Figure 9 | command-line tools | `output/figures/Cmdline tools/cli.pdf` |
| Figure 10 | FIO avg/p99 latency | `output/figures/microbench_bw_and_lat/formal_avg_{1,40,80}t.pdf`, `output/figures/microbench_bw_and_lat/formal_p99_{1,40,80}t.pdf` |
| Figure 11 | Log4j | `output/figures/Log/log_formal.pdf` |
| Figure 12 | FIO throughput | `output/figures/microbench_bw_and_lat/formal_tp_{1,40,80}t.pdf` |
| Figure 13 | FIO ablation | `output/figures/ablation_combined.pdf` |

## Result Tables

- RocksDB/YCSB: `results/rocksdb_ycsb_*/summary.md`
- Kafka: `repos/fio_test/kafka_script/logs/<run>/summary.md`
- command-line tools: `results/command_tools_*/summary.md`
- FIO synthetic: `repos/fio_test/out/summary.md`
- FIO ablation: `repos/fio_test/ablation/summary.md`
- Log4j: `results/log4j_throughput_*/summary.txt`
- StreamCache suite status: `results/scache_suite_*/SCACHE.md`
