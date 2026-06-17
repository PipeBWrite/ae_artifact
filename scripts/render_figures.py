#!/usr/bin/env python3
"""Generate figure-specific DAT files and render gnuplot figures."""

from __future__ import annotations

import argparse
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


WORKLOADS = ["A", "B", "F"]
FIO_THREADS = [1, 40, 80]
FIO_METRICS = ["bw", "lat_avg", "lat_p99"]
LOG_FILES = {"figure_manifest.txt", "figure_render.log"}


def to_float(value: str) -> float | None:
    try:
        parsed = float(value)
    except ValueError:
        return None
    if math.isnan(parsed) or math.isinf(parsed):
        return None
    return parsed


def dat_value(value: float | None, digits: int = 6) -> str:
    if value is None:
        return "NaN"
    return f"{value:.{digits}f}"


def fmt_k(value: float, digits: int) -> str:
    return f"{value / 1000.0:.{digits}f}K" if abs(value) >= 1000 else f"{value:.{digits}f}"


def fmt_us(value: float) -> str:
    return f"{value:.2f}{{/Symbol m}}s"


def read_rows(path: Path) -> list[list[str]]:
    rows: list[list[str]] = []
    if not path.exists():
        return rows
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rows.append(line.split())
    return rows


def has_nan_data(path: Path) -> bool:
    for row in read_rows(path):
        if any(cell.lower() == "nan" for cell in row):
            return True
    return False


def write_text(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def copy_dat(src: Path, dst: Path, generated: list[Path], skipped: list[str]) -> None:
    if not src.exists():
        skipped.append(f"{dst}: missing source {src}")
        return
    if has_nan_data(src):
        skipped.append(f"{dst}: source contains NaN ({src})")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    generated.append(dst)


def reset_generated_outputs(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in ["raw_data", "figures"]:
        path = output_dir / name
        if path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True, exist_ok=True)
    for name in LOG_FILES:
        path = output_dir / name
        if path.exists():
            path.unlink()


def copy_gnuplot_scripts(source_dir: Path, scripts_dir: Path) -> list[Path]:
    copied: list[Path] = []
    scripts_dir.mkdir(parents=True, exist_ok=True)
    if source_dir.resolve() == scripts_dir.resolve():
        return copied
    for src in sorted(source_dir.rglob("*.gnuplot")):
        rel = src.relative_to(source_dir)
        dst = scripts_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        copied.append(dst)
    return copied


def generate_command_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    copy_dat(dat_dir / "command" / "elapsed.dat", raw_dir / "Cmdline tools" / "data.dat", generated, skipped)


def read_fs_metric(path: Path) -> dict[str, list[float]]:
    result: dict[str, list[float]] = {}
    for row in read_rows(path):
        if len(row) < 4:
            continue
        values = [to_float(cell) for cell in row[1:4]]
        if any(value is None for value in values):
            continue
        result[row[0].lower()] = [value for value in values if value is not None]
    return result


def generate_kafka_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    latency_path = dat_dir / "kafka" / "avg_latency.dat"
    throughput_path = dat_dir / "kafka" / "bw.dat"
    latency = read_fs_metric(latency_path)
    throughput = read_fs_metric(throughput_path)
    if set(latency) != {"ext4", "xfs"}:
        skipped.append(f"Kafka/producer_absolute.dat: incomplete source {latency_path}")
        return
    if set(throughput) != {"ext4", "xfs"}:
        skipped.append(f"Kafka/producer_absolute.dat: incomplete source {throughput_path}")
        return

    def row(label: str, values: list[float]) -> str:
        return f"{label:<6}{values[0]:<12.2f}{values[1]:<13.2f}{values[2]:.2f}"

    lines = [
        "# Metric FS Baseline StreamCache PipeBWrite",
        "# Latency (us)",
        row("ext4", latency["ext4"]),
        row("XFS", latency["xfs"]),
        "",
        "",
        "# Throughput (MB/s)",
        row("ext4", throughput["ext4"]),
        row("XFS", throughput["xfs"]),
    ]
    dst = raw_dir / "Kafka" / "producer_absolute.dat"
    write_text(dst, lines)
    generated.append(dst)


def ycsb_rows(path: Path) -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    for row in read_rows(path):
        if len(row) < 8:
            continue
        values = [to_float(cell) for cell in row[1:8]]
        if any(value is None for value in values):
            continue
        raw, ext4, xfs, ext4_sc, xfs_sc, ext4_pbw, xfs_pbw = values
        out[row[0]] = {
            "raw": raw,
            "ext4": ext4,
            "xfs": xfs,
            "ext4_sc": ext4_sc,
            "xfs_sc": xfs_sc,
            "ext4_pbw": ext4_pbw,
            "xfs_pbw": xfs_pbw,
        }
    return out


def generate_ycsb_metric(src: Path, ext4_dst: Path, xfs_dst: Path, generated: list[Path], skipped: list[str]) -> None:
    rows = ycsb_rows(src)
    if any(workload not in rows for workload in WORKLOADS):
        skipped.append(f"{ext4_dst.name}/{xfs_dst.name}: incomplete source {src}")
        return

    ext4_lines = [
        "# ext4 variants normalized to ext4 raw",
        "# Workload  ext4_raw  ext4  ext4-SC  ext4-PBW  ext4-SC_raw  ext4-PBW_raw",
    ]
    xfs_lines = [
        "# xfs variants normalized to xfs raw",
        "# Workload  xfs_raw  xfs  xfs-SC  xfs-PBW  xfs-SC_raw  xfs-PBW_raw",
    ]
    for workload in WORKLOADS:
        vals = rows[workload]
        raw = vals["raw"]
        xfs_ratio = vals["xfs"]
        if raw == 0 or xfs_ratio == 0:
            skipped.append(f"{ext4_dst.name}/{xfs_dst.name}: zero baseline in {src}")
            return
        ext4_sc_raw = raw * vals["ext4_sc"]
        ext4_pbw_raw = raw * vals["ext4_pbw"]
        xfs_raw = raw * xfs_ratio
        xfs_sc_raw = raw * vals["xfs_sc"]
        xfs_pbw_raw = raw * vals["xfs_pbw"]
        ext4_lines.append(
            f"{workload:<10} {raw:.2f}  {vals['ext4']:.6f}  {vals['ext4_sc']:.6f}  "
            f"{vals['ext4_pbw']:.6f}  {ext4_sc_raw:.2f}  {ext4_pbw_raw:.2f}"
        )
        xfs_lines.append(
            f"{workload:<10} {xfs_raw:.2f}  1.000000  {vals['xfs_sc'] / xfs_ratio:.6f}  "
            f"{vals['xfs_pbw'] / xfs_ratio:.6f}  {xfs_sc_raw:.2f}  {xfs_pbw_raw:.2f}"
        )
    write_text(ext4_dst, ext4_lines)
    write_text(xfs_dst, xfs_lines)
    generated.extend([ext4_dst, xfs_dst])


def generate_rocksdb_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    rocks = raw_dir / "RocksDB"
    generate_ycsb_metric(
        dat_dir / "ycsb" / "throughput.dat",
        rocks / "formal_1_throughput_ext4.dat",
        rocks / "formal_1_throughput_xfs.dat",
        generated,
        skipped,
    )
    generate_ycsb_metric(
        dat_dir / "ycsb" / "update_avg_lat.dat",
        rocks / "formal_2_update_lat_ext4.dat",
        rocks / "formal_2_update_lat_xfs.dat",
        generated,
        skipped,
    )


def generate_fio_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    target = raw_dir / "microbench_bw_and_lat"
    for metric in FIO_METRICS:
        for threads in FIO_THREADS:
            name = f"{metric}_{threads}t_ext4.dat"
            copy_dat(dat_dir / "fio" / name, target / name, generated, skipped)


def generate_log4j_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    copy_dat(dat_dir / "log4j" / "ext4.dat", raw_dir / "Log" / "log_ext4.dat", generated, skipped)
    copy_dat(dat_dir / "log4j" / "xfs.dat", raw_dir / "Log" / "log_xfs.dat", generated, skipped)


ABLATION_BLOCKS = [("64", 0.0), ("4k", 6.6), ("64k", 13.2)]
ABLATION_STEPS = [
    ("Baseline", 0.0),
    ("Pipeline", 1.2),
    ("+Alloc", 2.4),
    ("+Zeroing", 3.6),
    ("+Batching", 4.8),
]
STEP_ALIASES = {
    "baseline": "Baseline",
    "Baseline": "Baseline",
    "noopt": "Pipeline",
    "Pipeline": "Pipeline",
    "+adaptivealloc": "+Alloc",
    "+Alloc": "+Alloc",
    "+nozeroing": "+Zeroing",
    "+Zeroing": "+Zeroing",
    "+mergingbatching": "+Batching",
    "+batching": "+Batching",
    "+Batching": "+Batching",
}


def read_ablation_components(path: Path) -> dict[str, tuple[float, float, float, float]] | None:
    if not path.exists():
        return None
    out: dict[str, tuple[float, float, float, float]] = {}
    for row in read_rows(path):
        if row[0].lower() == "step" or len(row) < 5:
            continue
        step = STEP_ALIASES.get(row[0])
        values = tuple(to_float(cell) for cell in row[1:5])
        if step is None or any(value is None for value in values):
            return None
        out[step] = values  # type: ignore[assignment]
    if any(step not in out for step, _ in ABLATION_STEPS):
        return None
    return out


def normalized_ablation(data: dict[str, tuple[float, float, float, float]]) -> dict[str, tuple[float, float, float, float]] | None:
    baseline_total = sum(data["Baseline"])
    if baseline_total <= 0:
        return None
    return {step: tuple(value / baseline_total for value in values) for step, values in data.items()}


def generate_ablation_dat(dat_dir: Path, raw_dir: Path, generated: list[Path], skipped: list[str]) -> None:
    root = dat_dir / "fio_ablation"
    lines = ['# BS Step "O-List" Submission Other "Background"']
    for block, block_y in ABLATION_BLOCKS:
        per_fs: dict[str, dict[str, tuple[float, float, float, float]]] = {}
        for fs in ["ext4", "xfs"]:
            src = root / f"{fs}_{block}_1t_t.dat"
            data = read_ablation_components(src)
            if data is None:
                skipped.append(f"ablation_1t.dat: missing or nonnumeric source {src}")
                return
            normalized = normalized_ablation(data)
            if normalized is None:
                skipped.append(f"ablation_1t.dat: invalid baseline in {src}")
                return
            per_fs[fs] = normalized
        for step, offset in ABLATION_STEPS:
            ext4 = per_fs["ext4"][step]
            xfs = per_fs["xfs"][step]
            values = "\t".join(dat_value(value, 12) for value in (*ext4, *xfs))
            lines.append(f"{block_y + offset:g}\t{block}\t{step}\t{values}")
        lines.append("")
    dst = raw_dir / "ablation_1t.dat"
    write_text(dst, lines)
    generated.append(dst)


def generate_figure_dat(dat_dir: Path, raw_dir: Path) -> tuple[list[Path], list[str]]:
    generated: list[Path] = []
    skipped: list[str] = []
    generate_command_dat(dat_dir, raw_dir, generated, skipped)
    generate_kafka_dat(dat_dir, raw_dir, generated, skipped)
    generate_rocksdb_dat(dat_dir, raw_dir, generated, skipped)
    generate_fio_dat(dat_dir, raw_dir, generated, skipped)
    generate_log4j_dat(dat_dir, raw_dir, generated, skipped)
    generate_ablation_dat(dat_dir, raw_dir, generated, skipped)
    return generated, skipped


def raw_column(path: Path, count: int) -> list[float] | None:
    values: list[float] = []
    for row in read_rows(path):
        if len(row) < 2:
            continue
        value = to_float(row[1])
        if value is None:
            return None
        values.append(value)
    return values if len(values) == count else None


def replace_raw_label_lines(script: Path, labels: list[str]) -> bool:
    if not script.exists():
        return False
    lines = script.read_text(encoding="utf-8", errors="replace").splitlines()
    label_idx = 0
    out: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        is_raw_label = (
            label_idx < len(labels)
            and re.match(r"set label [123] ", stripped) is not None
            and " screen " not in stripped
            and 'font "Helvetica,17"' in stripped
        )
        if is_raw_label:
            line = re.sub(r'"[^"]*"', f'"{labels[label_idx]}"', line, count=1)
            label_idx += 1
        out.append(line)
    if label_idx != len(labels):
        return False
    script.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    return True


def patch_raw_labels(scripts_dir: Path, raw_dir: Path) -> tuple[list[Path], list[str]]:
    patched: list[Path] = []
    skipped: list[str] = []

    rocks_raw = raw_dir / "RocksDB"
    rocks_scripts = scripts_dir / "RocksDB"
    throughput_ext4 = raw_column(rocks_raw / "formal_1_throughput_ext4.dat", 3)
    throughput_xfs = raw_column(rocks_raw / "formal_1_throughput_xfs.dat", 3)
    throughput_script = rocks_scripts / "formal_1_throughput.gnuplot"
    if throughput_ext4 and throughput_xfs:
        labels = [fmt_k(value, 2) for value in throughput_ext4 + throughput_xfs]
        if replace_raw_label_lines(throughput_script, labels):
            patched.append(throughput_script)
        else:
            skipped.append(f"{throughput_script}: could not patch raw value labels")
    else:
        skipped.append(f"{throughput_script}: missing raw throughput DAT values")

    latency_ext4 = raw_column(rocks_raw / "formal_2_update_lat_ext4.dat", 3)
    latency_xfs = raw_column(rocks_raw / "formal_2_update_lat_xfs.dat", 3)
    latency_script = rocks_scripts / "formal_2_update_lat.gnuplot"
    if latency_ext4 and latency_xfs:
        labels = [fmt_us(value) for value in latency_ext4 + latency_xfs]
        if replace_raw_label_lines(latency_script, labels):
            patched.append(latency_script)
        else:
            skipped.append(f"{latency_script}: could not patch raw value labels")
    else:
        skipped.append(f"{latency_script}: missing raw latency DAT values")

    log_raw = raw_dir / "Log"
    log_ext4 = raw_column(log_raw / "log_ext4.dat", 2)
    log_xfs = raw_column(log_raw / "log_xfs.dat", 2)
    log_script = scripts_dir / "Log" / "log.gnuplot"
    if log_ext4 and log_xfs:
        labels = [fmt_k(value, 1) for value in log_ext4 + log_xfs]
        if replace_raw_label_lines(log_script, labels):
            patched.append(log_script)
        else:
            skipped.append(f"{log_script}: could not patch raw value labels")
    else:
        skipped.append(f"{log_script}: missing raw Log4j DAT values")

    return patched, skipped


def rel_for_gnuplot(target: Path, base: Path) -> str:
    return os.path.relpath(target, base).replace(os.sep, "/")


def patch_script_io_paths(scripts_dir: Path, raw_dir: Path, figures_dir: Path) -> list[Path]:
    patched: list[Path] = []
    for script in sorted(scripts_dir.rglob("*.gnuplot")):
        rel_parent = script.parent.relative_to(scripts_dir)
        text = script.read_text(encoding="utf-8", errors="replace")

        def dat_repl(match: re.Match[str]) -> str:
            quote, ref = match.group(1), match.group(2)
            target = raw_dir / rel_parent / Path(ref).name
            return f"{quote}{rel_for_gnuplot(target, script.parent)}{quote}"

        def output_repl(match: re.Match[str]) -> str:
            quote, ref = match.group(1), match.group(2)
            target = figures_dir / rel_parent / Path(ref).name
            target.parent.mkdir(parents=True, exist_ok=True)
            return f"set output {quote}{rel_for_gnuplot(target, script.parent)}{quote}"

        new_text = re.sub(r"(['\"])([^'\"]+\.dat)\1", dat_repl, text)
        new_text = re.sub(r"set\s+output\s+(['\"])([^'\"]+)\1", output_repl, new_text)
        if new_text != text:
            script.write_text(new_text.rstrip() + "\n", encoding="utf-8")
            patched.append(script)
    return patched


def required_dat_files(script: Path) -> list[Path]:
    text = script.read_text(encoding="utf-8", errors="replace")
    refs = sorted(set(re.findall(r"['\"]([^'\"]+\.dat)['\"]", text)))
    return [script.parent / ref for ref in refs]


def output_files(script: Path) -> list[Path]:
    text = script.read_text(encoding="utf-8", errors="replace")
    refs = re.findall(r"set\s+output\s+['\"]([^'\"]+)['\"]", text)
    return [script.parent / ref for ref in refs]


def render_scripts(scripts_dir: Path, output_dir: Path) -> tuple[list[Path], list[str], list[str]]:
    rendered: list[Path] = []
    skipped: list[str] = []
    errors: list[str] = []
    gnuplot = shutil.which("gnuplot")
    scripts = sorted(scripts_dir.rglob("*.gnuplot"))
    if not scripts:
        errors.append(f"no .gnuplot scripts found under {scripts_dir}")
        return rendered, skipped, errors
    if gnuplot is None:
        skipped.extend(f"{script}: gnuplot executable not found" for script in scripts)
        return rendered, skipped, errors

    log_path = output_dir / "figure_render.log"
    with log_path.open("w", encoding="utf-8") as log:
        for script in scripts:
            needed = required_dat_files(script)
            missing = [path for path in needed if not path.exists()]
            nan_inputs = [path for path in needed if path.exists() and has_nan_data(path)]
            if missing:
                skipped.append(f"{script.relative_to(output_dir)}: missing {', '.join(rel(p, output_dir) for p in missing)}")
                continue
            if nan_inputs:
                skipped.append(f"{script.relative_to(output_dir)}: NaN in {', '.join(rel(p, output_dir) for p in nan_inputs)}")
                continue

            for output in output_files(script):
                output.parent.mkdir(parents=True, exist_ok=True)

            log.write(f"### {script.relative_to(output_dir)}\n")
            proc = subprocess.run(
                [gnuplot, script.name],
                cwd=script.parent,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            log.write(proc.stdout)
            log.write(f"rc={proc.returncode}\n\n")
            if proc.returncode != 0:
                errors.append(f"{script.relative_to(output_dir)}: gnuplot rc={proc.returncode}")
                continue
            rendered.extend(path for path in output_files(script) if path.exists())
    return rendered, skipped, errors


def rel(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def write_manifest(
    output_dir: Path,
    dat_dir: Path,
    copied_scripts: list[Path],
    generated_dat: list[Path],
    patched_paths: list[Path],
    patched_scripts: list[Path],
    rendered: list[Path],
    skipped: list[str],
    errors: list[str],
) -> None:
    lines = [
        "# Figure render manifest",
        f"source_dat_dir={dat_dir}",
        "",
        "[copied_scripts]",
    ]
    lines.extend(rel(path, output_dir) for path in copied_scripts)
    lines.extend(["", "[generated_dat]"])
    lines.extend(rel(path, output_dir) for path in generated_dat)
    lines.extend(["", "[patched_paths]"])
    lines.extend(rel(path, output_dir) for path in patched_paths)
    lines.extend(["", "[patched_scripts]"])
    lines.extend(rel(path, output_dir) for path in patched_scripts)
    lines.extend(["", "[rendered_outputs]"])
    lines.extend(rel(path, output_dir) for path in rendered)
    lines.extend(["", "[skipped]"])
    lines.extend(skipped)
    lines.extend(["", "[errors]"])
    lines.extend(errors)
    write_text(output_dir / "figure_manifest.txt", lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dat-dir", type=Path, required=True, help="Full-run DAT directory, usually results/full_ae_*/dat")
    parser.add_argument("--output-dir", type=Path, required=False, help="Destination root containing scripts/, raw_data/, and figures/")
    parser.add_argument("--figures-dir", type=Path, default=None, help=argparse.SUPPRESS)
    parser.add_argument(
        "--source-scripts",
        type=Path,
        default=None,
        help="Optional source tree to sync .gnuplot scripts from before rendering",
    )
    args = parser.parse_args()

    dat_dir = args.dat_dir.resolve()
    output_arg = args.output_dir or args.figures_dir
    if output_arg is None:
        print("missing output directory: pass --output-dir", file=sys.stderr)
        return 1
    output_dir = output_arg.resolve()
    scripts_dir = output_dir / "scripts"
    raw_dir = output_dir / "raw_data"
    figures_dir = output_dir / "figures"
    if not dat_dir.exists():
        print(f"missing DAT directory: {dat_dir}", file=sys.stderr)
        return 1

    reset_generated_outputs(output_dir)
    copied_scripts: list[Path] = []
    errors: list[str] = []
    source_scripts = (args.source_scripts or scripts_dir).expanduser().resolve()
    if not source_scripts.exists():
        errors.append(f"source scripts directory does not exist: {source_scripts}")
    else:
        copied_scripts = copy_gnuplot_scripts(source_scripts, scripts_dir)

    generated_dat, skipped = generate_figure_dat(dat_dir, raw_dir)
    patched_scripts, label_skips = patch_raw_labels(scripts_dir, raw_dir)
    skipped.extend(label_skips)
    patched_paths = patch_script_io_paths(scripts_dir, raw_dir, figures_dir)
    rendered, render_skips, render_errors = render_scripts(scripts_dir, output_dir)
    skipped.extend(render_skips)
    errors.extend(render_errors)
    write_manifest(output_dir, dat_dir, copied_scripts, generated_dat, patched_paths, patched_scripts, rendered, skipped, errors)

    print(f"generated {len(generated_dat)} figure DAT files under {raw_dir}")
    print(f"patched {len(patched_scripts)} gnuplot label files under {scripts_dir}")
    print(f"patched {len(patched_paths)} gnuplot data/output paths under {scripts_dir}")
    print(f"rendered {len(rendered)} figure outputs under {figures_dir}")
    if skipped:
        print(f"skipped {len(skipped)} items; see {output_dir / 'figure_manifest.txt'}")
    if errors:
        print(f"errors {len(errors)}; see {output_dir / 'figure_manifest.txt'}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
