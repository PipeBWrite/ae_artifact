#!/usr/bin/env python3

import json
import math
import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


VARIANTS = ("orig_x1", "async_x1", "scache_x1")
VARIANT_LABELS = {
    "orig_x1": "orig_{x1}",
    "async_x1": "async_{x1}",
    "scache_x1": "scache_{x1}",
}
FORMAL_BLOCKS = (("64B", "64"), ("4KB", "4k"), ("64KB", "64k"))
FORMAL_THREADS = (1, 40, 80)
FORMAL_FILESYSTEMS = ("ext4", "xfs")
LAT_KEYS = (
    ("avg", None),
    ("p99", "99.000000"),
    ("p999", "99.900000"),
    ("p9999", "99.990000"),
)


def to_float(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        if value.strip().upper() == "N/A":
            return None
        try:
            return float(value)
        except ValueError:
            return None
    return None


def gnu_num(value: float | None) -> str:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "NaN"
    return f"{value:.6f}"


def block_to_bytes(block: str) -> int:
    block = block.strip()
    m = re.fullmatch(r"(\d+)([KkMmGg])?", block)
    if not m:
        return 0
    num = int(m.group(1))
    suf = (m.group(2) or "").lower()
    if suf == "k":
        return num * 1024
    if suf == "m":
        return num * 1024 * 1024
    if suf == "g":
        return num * 1024 * 1024 * 1024
    return num


def safe_name(*parts: str) -> str:
    out = "__".join(parts)
    return re.sub(r"[^A-Za-z0-9_.=-]+", "_", out)


@dataclass(frozen=True)
class RunMeta:
    fs: str
    smt: int
    rw: str
    threads: int
    size: str
    block: str
    runtime: str
    direct: str
    fdatasync: str
    misc: str
    variant: str
    run: int | None

    @property
    def group_key(self) -> tuple[str, int, str, str, str, str, str, str, str, int, str]:
        return (
            self.fs,
            self.smt,
            self.rw,
            self.size,
            self.block,
            self.runtime,
            self.direct,
            self.fdatasync,
            self.misc,
            self.threads,
            self.variant,
        )


def parse_suffix_tokens(stem: str) -> RunMeta | None:
    # suffix format from fio_pmem_1t.sh:
    # fs.smtX.rw.threads.size.block.runtime.direct.fdatasync.misc.variant[.runN]
    parts = stem.split(".")
    if len(parts) not in (11, 12):
        return None
    fs, smt_tok, rw, threads, size, block, runtime, direct, fdatasync, misc, variant = parts[:11]
    run = None
    if len(parts) == 12:
        run_tok = parts[11]
        if not run_tok.startswith("run"):
            return None
        try:
            run = int(run_tok[3:])
        except ValueError:
            return None
    if not smt_tok.startswith("smt"):
        return None
    try:
        smt = int(smt_tok[3:])
        threads_i = int(threads)
    except ValueError:
        return None
    if variant not in VARIANTS:
        return None
    return RunMeta(
        fs=fs,
        smt=smt,
        rw=rw,
        threads=threads_i,
        size=size,
        block=block,
        runtime=runtime,
        direct=direct,
        fdatasync=fdatasync,
        misc=misc,
        variant=variant,
        run=run,
    )


def parse_fio_filename(path: Path) -> RunMeta | None:
    name = path.name
    if not (name.startswith("fio_") and name.endswith(".json")):
        return None
    return parse_suffix_tokens(name[len("fio_") : -len(".json")])


def parse_stats_filename(path: Path) -> RunMeta | None:
    name = path.name
    if not name.startswith("stats."):
        return None
    return parse_suffix_tokens(name[len("stats.") :])


def parse_cpu_filename(path: Path) -> RunMeta | None:
    name = path.name
    if not (name.startswith("cpu.") and name.endswith(".summary")):
        return None
    return parse_suffix_tokens(name[len("cpu.") : -len(".summary")])


def parse_fio_json(path: Path) -> dict[str, float | None] | None:
    try:
        with path.open() as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        print(f"warning: skipping invalid fio json: {path.name}")
        return None
    jobs = data.get("jobs") or []
    if not jobs:
        return {
            "bw_kib_s": None,
            "bw_mib_s": None,
            "bw_gb_s": None,
            "p99_ns": None,
            "p999_ns": None,
            "p9999_ns": None,
        }
    job = jobs[0]
    write = job.get("write") or {}
    clat = write.get("clat_ns") or {}
    pct = clat.get("percentile") or {}
    bw_kib = to_float(write.get("bw"))
    bw_bytes = to_float(write.get("bw_bytes"))
    if bw_bytes is None and bw_kib is not None:
        bw_bytes = bw_kib * 1024.0
    out = {
        "bw_kib_s": bw_kib,
        "bw_mib_s": (bw_kib / 1024.0) if bw_kib is not None else None,
        "bw_gb_s": (bw_bytes / 1_000_000_000.0) if bw_bytes is not None else None,
        "avg_ns": to_float(clat.get("mean")),
    }
    for label, fio_key in LAT_KEYS:
        if label == "avg":
            continue
        out[f"{label}_ns"] = to_float(pct.get(fio_key))
    return out


STAT_LINE_RE = re.compile(r"^==>\s+([A-Za-z0-9_]+):\s*([0-9]+)(?:,\s*([A-Za-z0-9_]+):\s*([0-9]+))?\s*$")


def parse_stats_file(path: Path) -> dict[str, int]:
    vals: dict[str, int] = {}
    with path.open() as f:
        for line in f:
            m = STAT_LINE_RE.match(line.strip())
            if not m:
                continue
            k1, v1, k2, v2 = m.groups()
            vals[k1] = int(v1)
            if k2 and v2:
                vals[k2] = int(v2)
    return vals


def parse_cpu_summary(path: Path) -> dict[str, float | None]:
    vals: dict[str, float | None] = {}
    with path.open() as f:
        for line in f:
            line = line.strip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k] = to_float(v)
    return vals


def mean_or_none(values: list[float | None]) -> float | None:
    nums = [v for v in values if v is not None]
    if not nums:
        return None
    return sum(nums) / len(nums)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def rel_data_path(gp_script_path: Path, data_path: Path) -> str:
    return str(data_path.relative_to(gp_script_path.parent.parent.parent))


def cleanup_generated_files(dir_path: Path, patterns: tuple[str, ...]) -> None:
    if not dir_path.exists():
        return
    for pat in patterns:
        for p in dir_path.glob(pat):
            if p.is_file():
                p.unlink()


def write_formal_dat_files(root: Path, plot_records: list[dict[str, Any]]) -> None:
    """Write the AE FIO summary DAT files from current run outputs.

    This keeps the top-level FIO summary tied to the current run outputs.
    """
    out_dir = root / "out"
    out_dir.mkdir(exist_ok=True)
    cleanup_generated_files(out_dir, ("bw_*t_*.dat", "lat_avg_*t_*.dat", "lat_p99_*t_*.dat"))

    by_dims: dict[tuple[str, str, int, str, int], dict[str, dict[str, Any]]] = defaultdict(dict)
    for r in plot_records:
        if r["smt"] != 0 or r["rw"] != "write":
            continue
        by_dims[(r["fs"], r["size"], r["smt"], r["block"], r["threads"])][r["variant"]] = r

    specs = (
        ("lat_avg", "avg_ns", "Average Latency", "us", 1000.0),
        ("lat_p99", "p99_ns", "P99 Latency", "us", 1000.0),
        ("bw", "bw_gb_s", "Bandwidth", "GB/s", 1.0),
    )

    for metric_name, field, title, unit, divisor in specs:
        for threads in FORMAL_THREADS:
            for fs in FORMAL_FILESYSTEMS:
                fs_label = "XFS" if fs == "xfs" else "ext4"
                lines = [
                    f"# {fs_label} {title} vs Block Size ({threads}t) -- NORMALIZED to {fs_label}",
                    f"# Columns: blksize  {fs_label}  {fs_label}SC  {fs_label}PBW  abs_baseline({unit})",
                ]

                for block_label, block_key in FORMAL_BLOCKS:
                    variants = by_dims.get((fs, "128G", 0, block_key, threads), {})
                    orig = variants.get("orig_x1", {}).get(field)
                    scache = variants.get("scache_x1", {}).get(field)
                    async_ = variants.get("async_x1", {}).get(field)

                    abs_orig = (orig / divisor) if orig is not None else None
                    scache_ratio = (scache / orig) if scache is not None and orig else None
                    async_ratio = (async_ / orig) if async_ is not None and orig else None
                    lines.append(
                        "{:<6} {:<7} {:<8} {:<8} {}".format(
                            block_label,
                            "1.00",
                            gnu_num(scache_ratio),
                            gnu_num(async_ratio),
                            gnu_num(abs_orig),
                        )
                    )

                write_text(out_dir / f"{metric_name}_{threads}t_{fs}.dat", "\n".join(lines) + "\n")


def main() -> int:
    root = Path(".").resolve()
    process_root = root / "process"
    # User note mentions "processed"; create it too for compatibility.
    (root / "processed").mkdir(exist_ok=True)
    for d in (
        process_root / "data" / "lat",
        process_root / "data" / "bw",
        process_root / "data" / "olist",
        process_root / "plot" / "lat",
        process_root / "plot" / "bw",
        process_root / "plot" / "olist",
    ):
        d.mkdir(parents=True, exist_ok=True)

    # Clear previously generated artifacts so renamed files don't coexist with stale ones.
    cleanup_generated_files(process_root / "data" / "lat", ("*.dat",))
    cleanup_generated_files(process_root / "data" / "bw", ("*.dat",))
    cleanup_generated_files(process_root / "data" / "olist", ("*.dat",))
    cleanup_generated_files(process_root / "plot" / "lat", ("*.gp", "*.png"))
    cleanup_generated_files(process_root / "plot" / "bw", ("*.gp", "*.png"))
    cleanup_generated_files(process_root / "plot" / "olist", ("*.gp", "*.png"))

    grouped: dict[tuple[str, int, str, str, str, str, str, str, str, int, str], dict[str, Any]] = defaultdict(
        lambda: {
            "fio_runs": [],
            "cpu_runs": [],
            "stats_sums": defaultdict(int),
            "stats_seen": False,
            "runs": set(),
        }
    )

    # Walk subdirectories (smt*/fs/) to find output files
    all_files = sorted(p for p in root.rglob("*") if p.is_file())
    for path in all_files:
        fio_meta = parse_fio_filename(path)
        if fio_meta:
            rec = grouped[fio_meta.group_key]
            fio_vals = parse_fio_json(path)
            if fio_vals is not None:
                rec["fio_runs"].append(fio_vals)
            rec["runs"].add(fio_meta.run if fio_meta.run is not None else 0)
            continue

        stats_meta = parse_stats_filename(path)
        if stats_meta:
            stats_vals = parse_stats_file(path)
            rec = grouped[stats_meta.group_key]
            rec["stats_seen"] = True
            for k, v in stats_vals.items():
                rec["stats_sums"][k] += v
            rec["runs"].add(stats_meta.run if stats_meta.run is not None else 0)
            continue

        cpu_meta = parse_cpu_filename(path)
        if cpu_meta:
            rec = grouped[cpu_meta.group_key]
            rec["cpu_runs"].append(parse_cpu_summary(path))
            rec["runs"].add(cpu_meta.run if cpu_meta.run is not None else 0)
            continue

    records: list[dict[str, Any]] = []
    for key, rec in grouped.items():
        (
            fs,
            smt,
            rw,
            size,
            block,
            runtime,
            direct,
            fdatasync,
            misc,
            threads,
            variant,
        ) = key
        fio_runs = rec["fio_runs"]
        cpu_runs = rec["cpu_runs"]
        stats_sums = rec["stats_sums"]

        row: dict[str, Any] = {
            "fs": fs,
            "smt": smt,
            "rw": rw,
            "size": size,
            "block": block,
            "runtime": runtime,
            "direct": direct,
            "fdatasync": fdatasync,
            "misc": misc,
            "threads": threads,
            "variant": variant,
            "nr_runs_seen": len(rec["runs"]),
            "nr_fio_runs": len(fio_runs),
            "nr_cpu_runs": len(cpu_runs),
        }

        for k in ("bw_kib_s", "bw_mib_s", "bw_gb_s", "avg_ns", "p99_ns", "p999_ns", "p9999_ns"):
            row[k] = mean_or_none([to_float(fr.get(k)) for fr in fio_runs])

        row["cpu_avg_total_pct"] = mean_or_none([to_float(cr.get("avg_total_pct")) for cr in cpu_runs])
        row["cpu_avg_sys_pct"] = mean_or_none([to_float(cr.get("avg_sys_pct")) for cr in cpu_runs])

        for stat in (
            "fg_search_add_olist_time",
            "fg_search_add_olist_count",
            "fg_submit_time",
            "fg_submit_count",
        ):
            row[stat] = stats_sums.get(stat, 0)

        olist_t = row["fg_search_add_olist_time"]
        olist_c = row["fg_search_add_olist_count"]
        submit_t = row["fg_submit_time"]
        submit_c = row["fg_submit_count"]
        row["olist_avg_ns"] = (olist_t / olist_c) if olist_c else None
        row["submit_avg_ns"] = (submit_t / submit_c) if submit_c else None

        records.append(row)

    # Restrict to write runs for requested plots.
    plot_records = [r for r in records if r["rw"] == "write"]
    write_formal_dat_files(root, plot_records)

    # Master preprocessed datasets.
    agg_path = process_root / "data" / "aggregated_fio_stats.dat"
    with agg_path.open("w") as f:
        f.write(
            "# fs smt rw threads size block runtime direct fdatasync misc variant "
            "nr_fio_runs nr_cpu_runs bw_kib_s bw_mib_s avg_ns p99_ns p999_ns p9999_ns cpu_avg_total_pct cpu_avg_sys_pct "
            "fg_search_add_olist_time fg_search_add_olist_count olist_avg_ns fg_submit_time fg_submit_count submit_avg_ns\n"
        )
        for r in sorted(
            plot_records,
            key=lambda x: (
                x["fs"],
                x["smt"],
                block_to_bytes(x["block"]),
                x["threads"],
                x["variant"],
            ),
        ):
            cols = [
                r["fs"],
                str(r["smt"]),
                r["rw"],
                str(r["threads"]),
                r["size"],
                r["block"],
                r["runtime"],
                r["direct"],
                r["fdatasync"],
                r["misc"],
                r["variant"],
                str(r["nr_fio_runs"]),
                str(r["nr_cpu_runs"]),
                gnu_num(r["bw_kib_s"]),
                gnu_num(r["bw_mib_s"]),
                gnu_num(r["avg_ns"]),
                gnu_num(r["p99_ns"]),
                gnu_num(r["p999_ns"]),
                gnu_num(r["p9999_ns"]),
                gnu_num(r["cpu_avg_total_pct"]),
                gnu_num(r["cpu_avg_sys_pct"]),
                str(r["fg_search_add_olist_time"]),
                str(r["fg_search_add_olist_count"]),
                gnu_num(r["olist_avg_ns"]),
                str(r["fg_submit_time"]),
                str(r["fg_submit_count"]),
                gnu_num(r["submit_avg_ns"]),
            ]
            f.write(" ".join(cols) + "\n")

    # Index by dimensions.
    by_dims: dict[tuple[str, str, int, str, int], dict[str, dict[str, Any]]] = defaultdict(dict)
    for r in plot_records:
        by_dims[(r["fs"], r["size"], r["smt"], r["block"], r["threads"])][r["variant"]] = r

    fs_size_smt_blocks = sorted(
        {(r["fs"], r["size"], r["smt"], r["block"]) for r in plot_records},
        key=lambda x: (x[0], x[2], block_to_bytes(x[3]), x[1]),
    )

    generated_gp_paths: list[Path] = []

    for fs, size, smt, block in fs_size_smt_blocks:
        rows = []
        thread_values = sorted(
            {t for (fs2, size2, smt2, block2, t) in by_dims if (fs2, size2, smt2, block2) == (fs, size, smt, block)}
        )
        for t in thread_values:
            variants = by_dims.get((fs, size, smt, block, t), {})
            rows.append((t, variants))

        base = safe_name(fs, f"size-{size}", f"smt{smt}", f"bs-{block}")

        # Latency data/scripts (avg/p99/p999/p9999)
        for lat_label, lat_col in (
            ("avg", "avg_ns"),
            ("p99", "p99_ns"),
            ("p999", "p999_ns"),
            ("p9999", "p9999_ns"),
        ):
            lat_dat = process_root / "data" / "lat" / f"lat__{base}__{lat_label}.dat"
            with lat_dat.open("w") as f:
                f.write("# thread orig_x1 async_x1 scache_x1\n")
                for t, variants in rows:
                    vals = [variants.get(v, {}).get(lat_col) if v in variants else None for v in VARIANTS]
                    f.write(f"{t} {gnu_num(vals[0])} {gnu_num(vals[1])} {gnu_num(vals[2])}\n")

            lat_png = process_root / "plot" / "lat" / f"lat__{base}__{lat_label}.png"
            lat_gp = process_root / "plot" / "lat" / f"lat__{base}__{lat_label}.gp"
            data_rel = rel_data_path(lat_gp, lat_dat)
            png_rel = lat_png.name
            lat_title = "Average Latency" if lat_label == "avg" else f"Latency {lat_label}"
            write_text(
                lat_gp,
                "\n".join(
                    [
                        "set terminal pngcairo size 1280,720 enhanced font 'Sans,16'",
                        f"set output '{png_rel}'",
                        "set datafile commentschars '#'",
                        "set style data histograms",
                        "set style histogram clustered gap 1",
                        "set style fill solid 0.9 border -1",
                        "set boxwidth 0.9",
                        "set grid ytics",
                        "set key outside",
                        f"set title '{lat_title} ({fs}, {block}, SMT={smt}, size={size})'",
                        "set xlabel 'Threads'",
                        "set ylabel 'Latency (ns)'",
                        f"plot '../../{data_rel}' using 2:xtic(1) title '{VARIANT_LABELS['orig_x1']}', \\",
                        f"     '../../{data_rel}' using 3 title '{VARIANT_LABELS['async_x1']}', \\",
                        f"     '../../{data_rel}' using 4 title '{VARIANT_LABELS['scache_x1']}'",
                        "",
                    ]
                ),
            )
            generated_gp_paths.append(lat_gp)

        # Bandwidth data/scripts (vs thread + vs CPU util)
        bw_dat = process_root / "data" / "bw" / f"bw__{base}.dat"
        with bw_dat.open("w") as f:
            f.write("# thread bw_orig_x1_mib bw_async_x1_mib bw_scache_x1_mib cpu_orig_x1_pct cpu_async_x1_pct cpu_scache_x1_pct\n")
            for t, variants in rows:
                bw_values = []
                for v in VARIANTS:
                    bw_values.append(variants.get(v, {}).get("bw_mib_s") if v in variants else None)
                cpu_values = []
                for v in VARIANTS:
                    cpu_values.append(variants.get(v, {}).get("cpu_avg_total_pct") if v in variants else None)
                f.write(
                    f"{t} {gnu_num(bw_values[0])} {gnu_num(bw_values[1])} {gnu_num(bw_values[2])} "
                    f"{gnu_num(cpu_values[0])} {gnu_num(cpu_values[1])} {gnu_num(cpu_values[2])}\n"
                )

        bw_png = process_root / "plot" / "bw" / f"bw__{base}__vs_threads.png"
        bw_gp = process_root / "plot" / "bw" / f"bw__{base}__vs_threads.gp"
        bw_data_rel = rel_data_path(bw_gp, bw_dat)
        write_text(
            bw_gp,
            "\n".join(
                [
                    "set terminal pngcairo size 1280,720 enhanced font 'Sans,16'",
                    f"set output '{bw_png.name}'",
                    "set datafile commentschars '#'",
                    "set style data histograms",
                    "set style histogram clustered gap 1",
                    "set style fill solid 0.9 border -1",
                    "set boxwidth 0.9",
                    "set grid ytics",
                    "set key outside",
                    f"set title 'FIO Bandwidth vs Threads ({fs}, {block}, SMT={smt}, size={size})'",
                    "set xlabel 'Threads'",
                    "set ylabel 'Bandwidth (MiB/s)'",
                    f"plot '../../{bw_data_rel}' using 2:xtic(1) title '{VARIANT_LABELS['orig_x1']}', \\",
                    f"     '../../{bw_data_rel}' using 3 title '{VARIANT_LABELS['async_x1']}', \\",
                    f"     '../../{bw_data_rel}' using 4 title '{VARIANT_LABELS['scache_x1']}'",
                    "",
                ]
            ),
        )
        generated_gp_paths.append(bw_gp)

        bw_cpu_png = process_root / "plot" / "bw" / f"bw__{base}__vs_cpu.png"
        bw_cpu_gp = process_root / "plot" / "bw" / f"bw__{base}__vs_cpu.gp"
        # Sort each series by its own CPU-util column so the line progresses monotonically on X.
        sort_o1 = f"< sort -g -k5,5 ../../{bw_data_rel}"
        sort_a1 = f"< sort -g -k6,6 ../../{bw_data_rel}"
        sort_s1 = f"< sort -g -k7,7 ../../{bw_data_rel}"
        write_text(
            bw_cpu_gp,
            "\n".join(
                [
                    "set terminal pngcairo size 1280,720 enhanced font 'Sans,16'",
                    f"set output '{bw_cpu_png.name}'",
                    "set datafile commentschars '#'",
                    "set grid",
                    "set key outside",
                    f"set title 'FIO Bandwidth vs CPU Utilization ({fs}, {block}, SMT={smt}, size={size})'",
                    "set xlabel 'CPU Utilization avg_{total}_{pct} (%)'",
                    "set ylabel 'Bandwidth (MiB/s)'",
                    "set pointsize 1.3",
                    f"plot '{sort_o1}' using 5:2 with linespoints lw 2 pt 7 title '{VARIANT_LABELS['orig_x1']}', \\",
                    f"     '{sort_a1}' using 6:3 with linespoints lw 2 pt 9 title '{VARIANT_LABELS['async_x1']}', \\",
                    f"     '{sort_s1}' using 7:4 with linespoints lw 2 pt 11 title '{VARIANT_LABELS['scache_x1']}'",
                    "",
                ]
            ),
        )
        generated_gp_paths.append(bw_cpu_gp)

    # Olist/submit plots: requested per FS + block. Include both SMT0/SMT1 in one figure.
    olist_groups = sorted(
        {(r["fs"], r["size"], r["block"]) for r in plot_records if r["variant"] == "async_x1"},
        key=lambda x: (x[0], block_to_bytes(x[2]), x[1]),
    )
    for fs, size, block in olist_groups:
        thread_values = sorted(
            {
                r["threads"]
                for r in plot_records
                if r["fs"] == fs and r["size"] == size and r["block"] == block and r["variant"] == "async_x1"
            }
        )
        base = safe_name(fs, f"size-{size}", f"bs-{block}")
        olist_dat = process_root / "data" / "olist" / f"olist__{base}.dat"
        series_has_data = {
            (0, "olist"): False,
            (0, "submit"): False,
            (1, "olist"): False,
            (1, "submit"): False,
        }
        with olist_dat.open("w") as f:
            f.write("# thread smt0_olist_avg_ns smt0_submit_avg_ns smt1_olist_avg_ns smt1_submit_avg_ns\n")
            for t in thread_values:
                def lookup(smt: int, field: str) -> float | None:
                    v = by_dims.get((fs, size, smt, block, t), {}).get("async_x1")
                    if not v:
                        return None
                    return v.get(field)

                s0_olist = lookup(0, "olist_avg_ns")
                s0_submit = lookup(0, "submit_avg_ns")
                s1_olist = lookup(1, "olist_avg_ns")
                s1_submit = lookup(1, "submit_avg_ns")
                if s0_olist is not None:
                    series_has_data[(0, "olist")] = True
                if s0_submit is not None:
                    series_has_data[(0, "submit")] = True
                if s1_olist is not None:
                    series_has_data[(1, "olist")] = True
                if s1_submit is not None:
                    series_has_data[(1, "submit")] = True

                f.write(
                    f"{t} {gnu_num(s0_olist)} {gnu_num(s0_submit)} "
                    f"{gnu_num(s1_olist)} {gnu_num(s1_submit)}\n"
                )

        olist_data_rel = rel_data_path(process_root / "plot" / "olist" / "dummy.gp", olist_dat)

        # Also generate separate plots per metric and SMT (requested).
        per_smt_specs = [
            (0, "olist", 2, "Average Olist Search Time", "olist"),
            (0, "submit", 3, "Average Submission Time", "submit"),
            (1, "olist", 4, "Average Olist Search Time", "olist"),
            (1, "submit", 5, "Average Submission Time", "submit"),
        ]
        for smt, metric_tag, col, title_prefix, legend_tag in per_smt_specs:
            if not series_has_data.get((smt, metric_tag), False):
                continue
            gp_path = process_root / "plot" / "olist" / f"olist__{base}__smt{smt}__{metric_tag}.gp"
            png_path = process_root / "plot" / "olist" / f"olist__{base}__smt{smt}__{metric_tag}.png"
            write_text(
                gp_path,
                "\n".join(
                    [
                        "set terminal pngcairo size 1280,720 enhanced font 'Sans,16'",
                        f"set output '{png_path.name}'",
                        "set datafile commentschars '#'",
                        "set grid",
                        "set key outside",
                        f"set title '{title_prefix} ({fs}, {block}, size={size}, SMT={smt})'",
                        "set xlabel 'Threads'",
                        "set ylabel 'Average Time (ns)'",
                        "set pointsize 1.2",
                        f"plot '../../{olist_data_rel}' using 1:{col} with linespoints lw 2 pt 7 title 'smt{smt} {legend_tag}'",
                        "",
                    ]
                ),
            )
            generated_gp_paths.append(gp_path)

    # Runner script for all generated gnuplot files.
    runner = process_root / "plot" / "run_all_gnuplot.sh"
    runner_lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'cd "$(dirname "$0")"',
        "shopt -s nullglob",
        "for d in lat bw olist; do",
        "  for gp in \"$d\"/*.gp; do",
        "    echo \"gnuplot $gp\"",
        "    (cd \"$d\" && gnuplot \"$(basename \"$gp\")\")",
        "  done",
        "done",
        "",
    ]
    write_text(runner, "\n".join(runner_lines))
    runner.chmod(0o755)

    # Simple manifest.
    manifest = process_root / "data" / "manifest.dat"
    with manifest.open("w") as f:
        f.write("# generated datasets/scripts summary\n")
        f.write(f"lat_plots {len(list((process_root / 'plot' / 'lat').glob('*.gp')))}\n")
        f.write(f"bw_plots {len(list((process_root / 'plot' / 'bw').glob('*.gp')))}\n")
        f.write(f"olist_plots {len(list((process_root / 'plot' / 'olist').glob('*.gp')))}\n")
        f.write(f"aggregated_rows {len(plot_records)}\n")

    print(f"Wrote aggregated data: {agg_path}")
    print(f"Wrote gnuplot scripts: {len(generated_gp_paths)}")
    print(f"Runner: {runner}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
