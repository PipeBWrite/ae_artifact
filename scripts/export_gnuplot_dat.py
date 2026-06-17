#!/usr/bin/env python3
"""Export prompt-style gnuplot .dat files from raw result directories."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import shlex
from collections import defaultdict
from pathlib import Path
from statistics import mean


WORKLOAD_ORDER = ["A", "B", "F"]
BLOCK_ORDER = [("64B", "64"), ("4KB", "4k"), ("64KB", "64k")]
THREAD_ORDER = [1, 40, 80]
FS_ORDER = ["ext4", "xfs"]


def num(value: object) -> float | None:
    try:
        out = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if math.isnan(out) or math.isinf(out):
        return None
    return out


def avg(values: list[float]) -> float | None:
    clean = [v for v in (num(v) for v in values) if v is not None]
    return mean(clean) if clean else None


def dat_value(value: float | None, digits: int = 2) -> str:
    value = num(value)
    if value is None:
        return "NaN"
    return f"{value:.{digits}f}"


def ratio(value: float | None, baseline: float | None) -> float | None:
    value = num(value)
    baseline = num(baseline)
    if value is None or baseline in (None, 0):
        return None
    return value / baseline


def write_dat(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def parse_manifest(path: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    if not path.exists():
        return result
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        try:
            token = shlex.split(raw, comments=False, posix=True)[0]
        except ValueError:
            token = raw
        key, value = token.split("=", 1)
        if key.endswith("_root") or key.endswith("_dir"):
            result[key] = Path(value)
    return result


def parse_ycsb_summary(path: Path, mode: str) -> dict[tuple[str, str], dict[str, float]]:
    out: dict[tuple[str, str], dict[str, float]] = defaultdict(dict)
    if not path.exists():
        return out
    current: tuple[str, str] | None = None
    header_re = re.compile(r"Workload '([^']+)' \(fs=([^,]+),")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        header = header_re.search(line)
        if header:
            current = (header.group(2), header.group(1).upper())
            continue
        if current is None:
            continue
        vals = re.findall(r"[-+]?[0-9]+(?:\.[0-9]+)?", line)
        if not vals:
            continue
        value = float(vals[-1])
        if line.startswith("Average Throughput"):
            out[current][f"{mode}_throughput"] = value
        elif re.match(r"^READ\s+AvgLat\s+", line):
            out[current][f"{mode}_read_avg_lat"] = value
        elif re.match(r"^READ\s+P99\s+", line):
            out[current][f"{mode}_read_p99_lat"] = value
        elif re.match(r"^UPDATE\s+AvgLat\s+", line):
            out[current][f"{mode}_update_avg_lat"] = value
        elif re.match(r"^UPDATE\s+P99\s+", line):
            out[current][f"{mode}_update_p99_lat"] = value
    return out


def merge_metric_dicts(dicts: list[dict[tuple[str, str], dict[str, float]]]) -> dict[tuple[str, str], dict[str, float]]:
    merged: dict[tuple[str, str], dict[str, float]] = defaultdict(dict)
    for dct in dicts:
        for key, vals in dct.items():
            merged[key].update(vals)
    return merged


def export_ycsb(out_dir: Path, ycsb_root: Path | None, scache_suite: Path | None) -> list[Path]:
    parts = []
    if ycsb_root:
        parts.append(parse_ycsb_summary(ycsb_root / "orig" / "summary.log", "orig"))
        parts.append(parse_ycsb_summary(ycsb_root / "async" / "summary.log", "async"))
    if scache_suite:
        parts.append(parse_ycsb_summary(scache_suite / "ycsb" / "summary.log", "scache"))
    data = merge_metric_dicts(parts)
    written: list[Path] = []

    specs = [
        ("throughput", "Normalized throughput (ops/sec), normalized to ext4 baseline"),
        ("read_avg_lat", "Normalized READ average latency (us), normalized to ext4 baseline"),
        ("update_avg_lat", "Normalized UPDATE average latency (us), normalized to ext4 baseline"),
        ("read_p99_lat", "Normalized READ p99 latency (us), normalized to ext4 baseline"),
        ("update_p99_lat", "Normalized UPDATE p99 latency (us), normalized to ext4 baseline"),
    ]
    for metric, title in specs:
        lines = [
            f"# {title}",
            "# Workload    ext4_base_raw  ext4  XFS   ext4-SC   XFS-SC   ext4-PBW   XFS-PBW",
        ]
        for workload in WORKLOAD_ORDER:
            baseline = data.get(("ext4", workload), {}).get(f"orig_{metric}")
            row = [
                workload,
                dat_value(baseline),
                dat_value(ratio(data.get(("ext4", workload), {}).get(f"orig_{metric}"), baseline)),
                dat_value(ratio(data.get(("xfs", workload), {}).get(f"orig_{metric}"), baseline)),
                dat_value(ratio(data.get(("ext4", workload), {}).get(f"scache_{metric}"), baseline)),
                dat_value(ratio(data.get(("xfs", workload), {}).get(f"scache_{metric}"), baseline)),
                dat_value(ratio(data.get(("ext4", workload), {}).get(f"async_{metric}"), baseline)),
                dat_value(ratio(data.get(("xfs", workload), {}).get(f"async_{metric}"), baseline)),
            ]
            lines.append("{:<12}{:<15}{:<6}{:<6}{:<10}{:<9}{:<11}{}".format(*row))
        path = out_dir / "ycsb" / f"{metric}.dat"
        write_dat(path, lines)
        written.append(path)
    return written


def parse_command_orig_async(path: Path | None) -> dict[tuple[str, str, str], dict[str, float]]:
    data: dict[tuple[str, str, str], dict[str, float]] = defaultdict(dict)
    if not path:
        return data
    metrics = path / "metrics.csv"
    if not metrics.exists():
        return data
    with metrics.open(newline="", encoding="utf-8") as fh:
        for rec in csv.DictReader(fh):
            if rec.get("rc") != "0":
                continue
            fs = rec.get("fs", "")
            source = rec.get("source", "")
            op = rec.get("operation", "")
            mode = rec.get("mode", "")
            value = num(rec.get("elapsed_s"))
            if fs and source and op and mode and value is not None:
                data[(fs, source, op)][mode] = value
    return data


def parse_command_scache(path: Path | None) -> dict[tuple[str, str, str], dict[str, float]]:
    data: dict[tuple[str, str, str], dict[str, float]] = defaultdict(dict)
    if not path:
        return data
    command_dir = path / "command"
    if not command_dir.exists():
        return data
    for file in command_dir.glob("result_*.scache.log"):
        text = file.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"(cp|tar) time is : ([0-9.]+)s", text)
        if not match:
            continue
        op = match.group(1)
        value = float(match.group(2))
        fs = "ext4" if "_ext4." in file.name else "xfs" if "_xfs." in file.name else ""
        source = "linux" if "result_linux_" in file.name else "large3g" if "result_generate_dir_" in file.name else ""
        if fs and source:
            data[(fs, source, op)]["scache"] = value
    return data


def export_command(out_dir: Path, command_root: Path | None, scache_suite: Path | None) -> list[Path]:
    data = parse_command_orig_async(command_root)
    for key, vals in parse_command_scache(scache_suite).items():
        data[key].update(vals)
    rows = [
        ("cp-M", "linux", "cp"),
        ("tar-M", "linux", "tar"),
        ("cp-L", "large3g", "cp"),
        ("tar-L", "large3g", "tar"),
    ]
    lines = [
        "# Command-line tool elapsed time (seconds); lower is better",
        "# Workload    ext4        ext4-SC     ext4-PBW    xfs         xfs-SC      xfs-PBW",
    ]
    for label, source, op in rows:
        row = [
            label,
            dat_value(data.get(("ext4", source, op), {}).get("orig"), 6),
            dat_value(data.get(("ext4", source, op), {}).get("scache"), 6),
            dat_value(data.get(("ext4", source, op), {}).get("async"), 6),
            dat_value(data.get(("xfs", source, op), {}).get("orig"), 6),
            dat_value(data.get(("xfs", source, op), {}).get("scache"), 6),
            dat_value(data.get(("xfs", source, op), {}).get("async"), 6),
        ]
        lines.append("{:<12}{:<12}{:<12}{:<12}{:<12}{:<12}{}".format(*row))
    path = out_dir / "command" / "elapsed.dat"
    write_dat(path, lines)
    return [path]


def parse_log4j_json(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    return raw if isinstance(raw, list) else [raw]


def export_log4j(out_dir: Path, log4j_root: Path | None, scache_suite: Path | None) -> list[Path]:
    data: dict[tuple[str, str], dict[str, float]] = defaultdict(dict)
    if log4j_root:
        for fs in FS_ORDER:
            for file in log4j_root.glob(f"*/*/{fs}/run_1_results.json"):
                mode = file.parts[-3]
                for obj in parse_log4j_json(file):
                    bench = str(obj.get("benchmark", "")).split(".")[-1]
                    score = num(obj.get("primaryMetric", {}).get("score"))  # type: ignore[union-attr]
                    if bench and score is not None:
                        data[(fs, bench)][mode] = score
    if scache_suite:
        for fs in FS_ORDER:
            file = scache_suite / "log4j" / fs / "run_1_results.json"
            for obj in parse_log4j_json(file):
                bench = str(obj.get("benchmark", "")).split(".")[-1]
                score = num(obj.get("primaryMetric", {}).get("score"))  # type: ignore[union-attr]
                if bench and score is not None:
                    data[(fs, bench)]["scache"] = score

    written: list[Path] = []
    for fs in FS_ORDER:
        lines = [
            f"# {fs} variants normalized to {fs} raw",
            f"# Workload  {fs}_raw  {fs}  {fs}-SC  {fs}-PBW  {fs}-SC_raw  {fs}-PBW_raw",
        ]
        for label, bench in [("heavy", "logHeavy"), ("complex", "logComplex")]:
            vals = data.get((fs, bench), {})
            orig = vals.get("orig")
            scache = vals.get("scache")
            async_ = vals.get("async")
            row = [
                label,
                dat_value(orig),
                dat_value(ratio(orig, orig), 6),
                dat_value(ratio(scache, orig), 6),
                dat_value(ratio(async_, orig), 6),
                dat_value(scache),
                dat_value(async_),
            ]
            lines.append("{:<10} {:<11} {:<7} {:<10} {:<10} {:<14} {}".format(*row))
        path = out_dir / "log4j" / f"{fs}.dat"
        write_dat(path, lines)
        written.append(path)
    return written


FIO_RE = re.compile(
    r"fio_(ext4|xfs)\.smt0\.write\.(\d+)\.128G\.(64|4k|64k)\.30\.0\.0\.100\.(orig|async|scache)_x1\.run(\d+)\.json$"
)


def parse_fio_roots(*roots: Path | None) -> dict[tuple[str, int, str, str], dict[str, float]]:
    buckets: dict[tuple[str, int, str, str], dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for root in roots:
        if not root or not root.exists():
            continue
        for file in root.rglob("*.json"):
            match = FIO_RE.match(file.name)
            if not match:
                continue
            fs, threads_s, block, mode, _ = match.groups()
            payload = json.loads(file.read_text(encoding="utf-8"))
            write = payload["jobs"][0]["write"]
            lat = write.get("lat_ns") or write.get("clat_ns")
            key = (fs, int(threads_s), block, mode)
            buckets[key]["bw"].append(float(write["bw_bytes"]) / 1e9)
            buckets[key]["lat_avg"].append(float(lat["mean"]) / 1000.0)
            buckets[key]["lat_p99"].append(float(write["clat_ns"]["percentile"]["99.000000"]) / 1000.0)
    return {key: {metric: avg(vals) for metric, vals in metrics.items()} for key, metrics in buckets.items()}


def export_fio(out_dir: Path, fio_root: Path | None, scache_fio_root: Path | None) -> list[Path]:
    data = parse_fio_roots(fio_root, scache_fio_root)
    specs = [
        ("lat_avg", "Average Latency", "us"),
        ("lat_p99", "P99 Latency", "us"),
        ("bw", "Bandwidth", "GB/s"),
    ]
    written: list[Path] = []
    for metric, title, unit in specs:
        for threads in THREAD_ORDER:
            for fs in FS_ORDER:
                fs_label = "XFS" if fs == "xfs" else "ext4"
                lines = [
                    f"# {fs_label} {title} vs Block Size ({threads}t) -- NORMALIZED to {fs_label}",
                    f"# Columns: blksize  {fs_label}  {fs_label}SC  {fs_label}PBW  abs_baseline({unit})",
                ]
                for block_label, block_key in BLOCK_ORDER:
                    orig = data.get((fs, threads, block_key, "orig"), {}).get(metric)
                    scache = data.get((fs, threads, block_key, "scache"), {}).get(metric)
                    async_ = data.get((fs, threads, block_key, "async"), {}).get(metric)
                    row = [
                        block_label,
                        "1.00",
                        dat_value(ratio(scache, orig)),
                        dat_value(ratio(async_, orig)),
                        dat_value(orig),
                    ]
                    lines.append("{:<6} {:<7} {:<8} {:<8} {}".format(*row))
                path = out_dir / "fio" / f"{metric}_{threads}t_{fs}.dat"
                write_dat(path, lines)
                written.append(path)
    return written


def parse_arrow_values(cell: str) -> tuple[float | None, float | None, float | None]:
    vals = [part.strip() for part in cell.split("->")]
    vals += ["N/A"] * (3 - len(vals))
    return tuple(num(v) for v in vals[:3])  # type: ignore[return-value]


def parse_kafka_summary(root: Path | None) -> dict[str, dict[str, dict[str, float]]]:
    data: dict[str, dict[str, dict[str, float]]] = defaultdict(lambda: defaultdict(dict))
    if not root:
        return data
    summary = root / "summary.md"
    if not summary.exists():
        return data
    for raw in summary.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not (line.startswith("ext4") or line.startswith("xfs")):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 8:
            continue
        fs = parts[0]
        for metric_name, cell in [
            ("bw", parts[4]),
            ("avg_latency", parts[5]),
            ("p99_latency", parts[6]),
            ("p999_latency", parts[7]),
        ]:
            orig, async_, scache = parse_arrow_values(cell)
            for mode, value in [("orig", orig), ("async", async_), ("scache", scache)]:
                if value is not None:
                    data[fs][mode][metric_name] = value
    return data


def export_kafka(out_dir: Path, kafka_root: Path | None, scache_kafka_root: Path | None) -> list[Path]:
    data = parse_kafka_summary(kafka_root)
    for fs, modes in parse_kafka_summary(scache_kafka_root).items():
        for mode, metrics in modes.items():
            data[fs][mode].update(metrics)
    specs = [
        ("bw", "Throughput", "MB/s"),
        ("avg_latency", "Average latency", "us"),
        ("p99_latency", "p99 latency", "us"),
        ("p999_latency", "p99.9 latency", "us"),
    ]
    written: list[Path] = []
    for metric, title, unit in specs:
        lines = [
            f"# Kafka {title} ({unit})",
            "# FS Baseline StreamCache PipeBWrite",
        ]
        for fs in FS_ORDER:
            row = [
                fs,
                dat_value(data.get(fs, {}).get("orig", {}).get(metric)),
                dat_value(data.get(fs, {}).get("scache", {}).get(metric)),
                dat_value(data.get(fs, {}).get("async", {}).get(metric)),
            ]
            lines.append("{:<6}{:<12}{:<13}{}".format(*row))
        path = out_dir / "kafka" / f"{metric}.dat"
        write_dat(path, lines)
        written.append(path)
    return written


def export_fio_ablation(out_dir: Path, ablation_dir: Path | None) -> list[Path]:
    if not ablation_dir or not ablation_dir.exists():
        return []
    dest_dir = out_dir / "fio_ablation"
    dest_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for src in sorted(ablation_dir.glob("*.dat")):
        dest = dest_dir / src.name
        shutil.copyfile(src, dest)
        written.append(dest)
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    manifest = parse_manifest(args.manifest)
    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    written: list[Path] = []
    written += export_ycsb(out_dir, manifest.get("ycsb_root"), manifest.get("scache_suite_root"))
    written += export_command(out_dir, manifest.get("command_root"), manifest.get("scache_suite_root"))
    written += export_log4j(out_dir, manifest.get("log4j_root"), manifest.get("scache_suite_root"))
    written += export_fio(out_dir, manifest.get("fio_root"), manifest.get("scache_fio_root"))
    written += export_kafka(out_dir, manifest.get("kafka_root"), manifest.get("scache_kafka_root"))
    written += export_fio_ablation(out_dir, manifest.get("fio_ablation_dir"))

    manifest_lines = ["# Generated .dat files"]
    manifest_lines.extend(str(path.relative_to(out_dir)) for path in sorted(written))
    write_dat(out_dir / "manifest.dat", manifest_lines)
    print(f"wrote {len(written)} dat files under {out_dir}")


if __name__ == "__main__":
    main()
