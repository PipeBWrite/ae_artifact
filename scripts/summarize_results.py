#!/usr/bin/env python3
"""Generate compact Markdown summary tables for benchmark outputs."""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean


MODE_LABELS = {
    "orig": "orig",
    "async": "PBW",
    "scache": "StreamCache",
    "streamcache": "StreamCache",
}


def clean_float(value: str | float | None) -> float | None:
    if value is None:
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if math.isnan(num) or math.isinf(num):
        return None
    return num


def fmt_num(value: float | None, digits: int = 2) -> str:
    value = clean_float(value)
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def fmt_ratio(value: float | None) -> str:
    value = clean_float(value)
    if value is None:
        return "-"
    return f"{value:.2f}x"


def ratio(numerator: float | None, denominator: float | None) -> float | None:
    numerator = clean_float(numerator)
    denominator = clean_float(denominator)
    if numerator is None or denominator is None or denominator == 0:
        return None
    return numerator / denominator


def positive_or_missing(value: float | None) -> float | None:
    value = clean_float(value)
    if value is None or value <= 0:
        return None
    return value


def average(values: list[float]) -> float | None:
    values = [v for v in (clean_float(v) for v in values) if v is not None]
    if not values:
        return None
    return mean(values)


def md_escape(value: object) -> str:
    text = str(value)
    return text.replace("|", "\\|")


def md_table(headers: list[str], rows: list[list[object]]) -> str:
    if not rows:
        return "_No parsed rows._\n"
    lines = [
        "| " + " | ".join(md_escape(h) for h in headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(md_escape(v) for v in row) + " |")
    return "\n".join(lines) + "\n"


def write_markdown(output_path: Path, title: str, sections: list[tuple[str, str]]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    parts = [f"# {title}", ""]
    for heading, body in sections:
        parts.extend([f"## {heading}", "", body.rstrip(), ""])
    output_path.write_text("\n".join(parts), encoding="utf-8")


def sort_key_for_block(block: str) -> tuple[int, str]:
    match = re.fullmatch(r"(\d+)([KMG]?B?)", block, flags=re.IGNORECASE)
    if not match:
        return (10**18, block)
    size = int(match.group(1))
    suffix = match.group(2).upper()
    mult = {"": 1, "B": 1, "KB": 1024, "K": 1024, "MB": 1024**2, "M": 1024**2, "GB": 1024**3, "G": 1024**3}
    return (size * mult.get(suffix, 1), block)


def summarize_command(input_dir: Path, output_path: Path) -> None:
    metrics_path = input_dir / "metrics.csv"
    if not metrics_path.exists():
        write_markdown(output_path, "Command-Line Tools Summary", [("Status", f"`{metrics_path}` not found.")])
        return

    grouped: dict[tuple[str, str, str, str], dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    failures: list[str] = []
    with metrics_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for rec in reader:
            fs = rec.get("fs", "")
            mode = rec.get("mode", "")
            source = rec.get("source", "")
            operation = rec.get("operation", "")
            cache_mode = rec.get("cache_mode", "")
            elapsed = clean_float(rec.get("elapsed_s"))
            rc = rec.get("rc", "")
            key = (fs, source, operation, cache_mode)
            if rc != "0":
                failures.append(f"{fs}/{mode}/{source}/{operation}/{cache_mode}: rc={rc}")
                continue
            if elapsed is not None:
                grouped[key][mode].append(elapsed)

    rows: list[list[object]] = []
    for fs, source, operation, cache_mode in sorted(grouped):
        modes = grouped[(fs, source, operation, cache_mode)]
        orig = average(modes.get("orig", []))
        pbw = average(modes.get("async", []))
        scache = average(modes.get("scache", []))
        rows.append([
            fs,
            source,
            operation,
            cache_mode,
            fmt_num(orig),
            fmt_num(pbw),
            fmt_ratio(ratio(orig, pbw)),
            fmt_num(scache),
            fmt_ratio(ratio(orig, scache)),
        ])

    notes = [
        "Elapsed-time speedup is computed as `orig_seconds / mode_seconds`, so higher is better.",
        f"Raw CSV: `{metrics_path.name}`",
    ]
    if failures:
        notes.append(f"Failed rows ignored: {len(failures)}")

    write_markdown(
        output_path,
        "Command-Line Tools Summary",
        [
            ("Elapsed Time", md_table(
                ["FS", "Source", "Operation", "Cache", "orig s", "PBW s", "PBW speedup", "StreamCache s", "StreamCache speedup"],
                rows,
            )),
            ("Notes", "\n".join(f"- {note}" for note in notes)),
        ],
    )


def parse_ycsb_summary(summary_path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    header_re = re.compile(r"Workload '([^']+)' \(fs=([^,]+), threads=([^)]+)\) Averages")
    metric_re = re.compile(r"^\s*(Minimum Throughput|Maximum Throughput|Average Throughput|Average System CPU Usage)\s+([0-9.]+)")
    with summary_path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            header = header_re.search(line)
            if header:
                current = {
                    "workload": header.group(1),
                    "fs": header.group(2),
                    "threads": header.group(3),
                }
                rows.append(current)
                continue
            metric = metric_re.search(line)
            if current is None or not metric:
                continue
            key = metric.group(1).lower().replace(" ", "_")
            current[key] = clean_float(metric.group(2))
    return rows


def summarize_ycsb(input_dir: Path, output_path: Path) -> None:
    data: dict[tuple[str, str, str], dict[str, dict[str, object]]] = defaultdict(dict)
    cpu_present = False
    for mode_dir in sorted(input_dir.iterdir() if input_dir.exists() else []):
        if not mode_dir.is_dir():
            continue
        mode = normalize_mode(mode_dir.name)
        summary_path = mode_dir / "summary.log"
        if not summary_path.exists():
            continue
        for rec in parse_ycsb_summary(summary_path):
            key = (str(rec["fs"]), str(rec["workload"]), str(rec["threads"]))
            data[key][mode] = rec
            cpu_present = cpu_present or rec.get("average_system_cpu_usage") is not None

    throughput_rows: list[list[object]] = []
    cpu_rows: list[list[object]] = []
    for fs, workload, threads in sorted(data, key=lambda k: (k[0], k[1], int(k[2]) if str(k[2]).isdigit() else k[2])):
        modes = data[(fs, workload, threads)]
        orig = modes.get("orig", {}).get("average_throughput")
        pbw = modes.get("async", {}).get("average_throughput")
        scache = modes.get("scache", modes.get("streamcache", {})).get("average_throughput")
        throughput_rows.append([
            fs,
            workload,
            threads,
            fmt_num(orig),
            fmt_num(pbw),
            fmt_ratio(ratio(pbw, orig)),
            fmt_num(scache),
            fmt_ratio(ratio(scache, orig)),
        ])
        if cpu_present:
            cpu_rows.append([
                fs,
                workload,
                threads,
                fmt_num(modes.get("orig", {}).get("average_system_cpu_usage")),
                fmt_num(modes.get("async", {}).get("average_system_cpu_usage")),
                fmt_num(modes.get("scache", modes.get("streamcache", {})).get("average_system_cpu_usage")),
            ])

    sections = [
        ("Average Throughput", md_table(
            ["FS", "Workload", "Threads", "orig ops/s", "PBW ops/s", "PBW/orig", "StreamCache ops/s", "StreamCache/orig"],
            throughput_rows,
        )),
        ("Notes", "Ratios are throughput ratios, so higher is better."),
    ]
    if cpu_present:
        sections.insert(1, ("Average System CPU", md_table(["FS", "Workload", "Threads", "orig %", "PBW %", "StreamCache %"], cpu_rows)))
    write_markdown(output_path, "RocksDB/YCSB Summary", sections)


def normalize_mode(name: str) -> str:
    lower = name.lower()
    if lower in ("orig", "sync", "baseline") or lower.endswith("_orig"):
        return "orig"
    if lower in ("async", "pbw") or lower.endswith("_async"):
        return "async"
    if lower in ("scache", "streamcache") or lower.endswith("_scache") or lower.endswith("_streamcache"):
        return "scache"
    return lower


def infer_mode(path: Path, root: Path) -> str:
    root_mode = normalize_mode(root.name)
    if root_mode in ("orig", "async", "scache"):
        return root_mode
    for part in path.relative_to(root).parts:
        mode = normalize_mode(part)
        if mode in ("orig", "async", "scache"):
            return mode
    return normalize_mode(path.parent.name)


def infer_fs(path: Path, root: Path) -> str:
    for part in reversed(path.relative_to(root).parts):
        if part in ("ext4", "xfs"):
            return part
    return "all"


def summarize_log4j(input_dir: Path, output_path: Path) -> None:
    values: dict[tuple[str, str, str], dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    units: dict[tuple[str, str, str], str] = {}

    for summary_path in sorted(input_dir.rglob("all_runs_summary.tsv") if input_dir.exists() else []):
        mode = infer_mode(summary_path, input_dir)
        fs = infer_fs(summary_path, input_dir)
        with summary_path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 6:
                    continue
                _, benchmark, logging_type, score, _, unit = parts[:6]
                score_f = clean_float(score)
                if score_f is None:
                    continue
                key = (fs, benchmark, logging_type)
                values[key][mode].append(score_f)
                units[key] = unit

    rows: list[list[object]] = []
    for fs, benchmark, logging_type in sorted(values):
        modes = values[(fs, benchmark, logging_type)]
        orig = average(modes.get("orig", []))
        pbw = average(modes.get("async", []))
        scache = average(modes.get("scache", []))
        rows.append([
            fs,
            benchmark,
            logging_type,
            fmt_num(orig),
            fmt_num(pbw),
            fmt_ratio(ratio(pbw, orig)),
            fmt_num(scache),
            fmt_ratio(ratio(scache, orig)),
            units.get((fs, benchmark, logging_type), "ops/s"),
        ])

    write_markdown(
        output_path,
        "Log4j Summary",
        [
            ("Average JMH Score", md_table(
                ["FS", "Benchmark", "LoggingType", "orig", "PBW", "PBW/orig", "StreamCache", "StreamCache/orig", "Unit"],
                rows,
            )),
            ("Notes", "Ratios are throughput-score ratios, so higher is better."),
        ],
    )


def parse_fio_dat(path: Path) -> tuple[str | None, list[tuple[str, float | None, float | None, float | None, float | None]]]:
    unit: str | None = None
    rows: list[tuple[str, float | None, float | None, float | None, float | None]] = []
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("#"):
                unit_match = re.search(r"abs_baseline\(([^)]+)\)", stripped)
                if unit_match:
                    unit = unit_match.group(1)
                continue
            parts = stripped.split()
            if len(parts) < 5:
                continue
            block = parts[0]
            baseline = clean_float(parts[1])
            scache = clean_float(parts[2])
            pbw = clean_float(parts[3])
            abs_baseline = clean_float(parts[4])
            rows.append((block, baseline, scache, pbw, abs_baseline))
    return unit, rows


def summarize_fio(input_dir: Path, output_path: Path) -> None:
    metric_specs = {
        "bw": ("Bandwidth", "higher is better"),
        "lat_avg": ("Average Latency", "lower is better"),
        "lat_p99": ("P99 Latency", "lower is better"),
    }
    parsed: dict[str, list[list[object]]] = defaultdict(list)
    units: dict[str, str] = {}
    pattern = re.compile(r"^(bw|lat_avg|lat_p99)_(\d+)t_(ext4|xfs)\.dat$")

    for path in sorted(input_dir.glob("*.dat") if input_dir.exists() else []):
        match = pattern.match(path.name)
        if not match:
            continue
        metric, threads, fs = match.groups()
        unit, rows = parse_fio_dat(path)
        units[metric] = unit or units.get(metric, "")
        for block, _, scache, pbw, abs_baseline in rows:
            parsed[metric].append([
                fs,
                threads,
                block,
                fmt_num(abs_baseline),
                fmt_ratio(positive_or_missing(pbw)),
                fmt_ratio(positive_or_missing(scache)),
            ])

    sections: list[tuple[str, str]] = []
    for metric, (title, direction) in metric_specs.items():
        rows = sorted(
            parsed.get(metric, []),
            key=lambda r: (str(r[0]), int(r[1]), sort_key_for_block(str(r[2]))),
        )
        unit = units.get(metric, "")
        sections.append((
            title,
            md_table(
                ["FS", "Threads", "Block", f"orig abs ({unit})", "PBW/orig", "StreamCache/orig"],
                rows,
            ) + f"\nRatios are normalized to orig; {direction}.",
        ))

    write_markdown(output_path, "FIO Synthetic Summary", sections)


def summarize_fio_ablation(input_dir: Path, output_path: Path) -> None:
    rows: list[list[object]] = []
    pattern = re.compile(r"^(ext4|xfs)_(64|4k|64k)_(\d+)t_t\.dat$")
    block_labels = {"64": "64B", "4k": "4KB", "64k": "64KB"}
    step_order = {
        "Baseline": 0,
        "Pipeline": 1,
        "+Alloc": 2,
        "+Zeroing": 3,
        "+batching": 4,
    }
    for path in sorted(input_dir.glob("*_t.dat") if input_dir.exists() else []):
        match = pattern.match(path.name)
        if not match:
            continue
        fs, block_raw, threads = match.groups()
        with path.open(encoding="utf-8", errors="replace") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            for rec in reader:
                rows.append([
                    fs,
                    block_labels.get(block_raw, block_raw),
                    threads,
                    rec.get("Step", "-"),
                    fmt_num(clean_float(rec.get("FG_OList"))),
                    fmt_num(clean_float(rec.get("FG_Submission"))),
                    fmt_num(clean_float(rec.get("FG_Other"))),
                    fmt_num(clean_float(rec.get("BG_Time"))),
                ])

    rows.sort(key=lambda r: (
        str(r[0]),
        sort_key_for_block(str(r[1])),
        int(r[2]),
        step_order.get(str(r[3]), 99),
        str(r[3]),
    ))
    write_markdown(
        output_path,
        "FIO Ablation Summary",
        [
            ("Ablation Components", md_table(
                ["FS", "Block", "Threads", "Step", "FG_OList", "FG_Submission", "FG_Other", "BG_Time"],
                rows,
            )),
            ("Notes", "Values are copied from the ablation `_t.dat` files generated by `gen_ablation.py`; current kernels use TSC cycles from `rdtsc()` as the timer unit."),
        ],
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["command", "ycsb", "log4j", "fio", "fio-ablation"])
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    if args.kind == "command":
        summarize_command(args.input, args.output)
    elif args.kind == "ycsb":
        summarize_ycsb(args.input, args.output)
    elif args.kind == "log4j":
        summarize_log4j(args.input, args.output)
    elif args.kind == "fio":
        summarize_fio(args.input, args.output)
    elif args.kind == "fio-ablation":
        summarize_fio_ablation(args.input, args.output)
    else:
        raise AssertionError(args.kind)


if __name__ == "__main__":
    main()
