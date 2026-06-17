#!/usr/bin/env python3
"""
Generate .dat and .gnuplot files for ablation experiment results.

Preferred result directories are stable symlinks written by
scripts/run_fio_ablation.sh:
  ae_fio_ablation_baseline -> "Baseline" (orig_x1)
  ae_fio_ablation_pipeline -> "Pipeline"
  ae_fio_ablation_alloc    -> "+Alloc"
  ae_fio_ablation_zeroing  -> "+Zeroing"
  ae_fio_ablation_batching -> "+batching"

For each (fs, block_size, thread_count), generates:
  - A .dat file with rows: FG_OList, FG_Submission, FG_Other, BG_Time
    and columns: Baseline, Pipeline, +Alloc, +Zeroing, +batching
  - All values are per-perform_write call in the raw stats timer unit
    (TSC cycles for current kernels)
  - A .gnuplot file for stacked bar chart visualization
"""

import os
import glob
import math
import shutil
import subprocess

RESULTS_DIR = "results"
OUTPUT_DIR = "ablation"

ABLATION_STEPS = [
    (("ae_fio_ablation_pipeline",), "Pipeline"),
    (("ae_fio_ablation_alloc",), "+Alloc"),
    (("ae_fio_ablation_zeroing",), "+Zeroing"),
    (("ae_fio_ablation_batching",), "+batching"),
]

BASELINE_DIRS = ("ae_fio_ablation_baseline",)

FILESYSTEMS = ["ext4", "xfs"]
BLOCK_SIZES = ["64", "4k", "64k"]
THREAD_COUNTS = ["1"]

COMPONENT_NAMES = ["FG_OList", "FG_Submission", "FG_Other", "BG_Time"]
UNIT_LABEL = "TSC cycles/write"
DISPLAY_STEP_LABELS = ["Baseline", "Pipeline", "+Alloc", "+Zeroing", "+Batching"]
DATA_STEP_LABELS = [
    "baseline",
    "noopt",
    "+adaptivealloc",
    "+nozeroing",
    "+mergingbatching",
]


def parse_stats_file(path):
    """Parse a stats file, return dict of field_name -> int value."""
    fields = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("==>"):
                continue
            line = line[4:]  # strip "==> "
            for part in line.split(", "):
                if ": " not in part:
                    continue
                key, val = part.split(": ", 1)
                fields[key.strip()] = int(val.strip())
    return fields


def get_write_totals(fields):
    """Return (write_time, write_count), accepting current and legacy stat names."""
    if "perform_write_4k_count" in fields:
        write_count = fields.get("perform_write_4k_count", 0)
        write_time = fields.get("perform_write_4k_time", 0)
    else:
        write_count = fields.get("perform_write_count", 0)
        write_time = fields.get("perform_write_time", 0)
    if write_count <= 0:
        return None
    return write_time, write_count


def sum_fields(fields, *names):
    return sum(fields.get(name, 0) for name in names)


def compute_breakdown(fields):
    """Compute per-write breakdown in raw timer units."""
    totals = get_write_totals(fields)
    if totals is None:
        return None
    write_time, write_count = totals

    # Current kernels may only expose aggregate perform_write stats. When the
    # detailed timers are absent, keep the total by assigning it to FG_Other.
    fg_olist_time = fields.get(
        "fg_search_add_olist_time",
        sum_fields(fields, "fg_olist_lookup_time", "fg_olist_insert_time"),
    )
    fg_submit_time = fields.get("fg_submit_time", 0)
    bg_raw_time = fields.get("bg_process_one_req_time", 0)
    fg_other_time = max(write_time - fg_olist_time - fg_submit_time, 0)

    fg_olist = fg_olist_time / write_count
    fg_submit = fg_submit_time / write_count
    fg_other = fg_other_time / write_count
    bg_time = bg_raw_time / write_count

    return (fg_olist, fg_submit, fg_other, bg_time)


def first_available_dir(candidates):
    """Return the first candidate result directory that exists."""
    for candidate in candidates:
        if os.path.isdir(os.path.join(RESULTS_DIR, candidate)):
            return candidate
    return candidates[0]


def get_averaged_breakdown(ablation_dirs, fs, bs, threads, variant="async_x1"):
    """Average breakdown across runs for a given config. Returns tuple or None."""
    ablation_dir = first_available_dir(ablation_dirs)
    pattern = os.path.join(
        RESULTS_DIR, ablation_dir, "smt0", fs,
        f"stats.{fs}.smt0.write.{threads}.128G.{bs}.30.0.0.100.{variant}.run*"
    )
    files = sorted(glob.glob(pattern))
    if not files:
        return None

    breakdowns = []
    for f in files:
        breakdown = compute_breakdown(parse_stats_file(f))
        if breakdown is not None:
            breakdowns.append(breakdown)
    if not breakdowns:
        return None
    n = len(breakdowns)
    return tuple(sum(b[i] for b in breakdowns) / n for i in range(4))


def get_baseline_write_time(fs, bs, threads):
    """Get averaged per-write time from baseline (orig_x1) runs.
    Returns (0, 0, fg_total_per_write, 0) so it shows as a single bar."""
    baseline_dir = first_available_dir(BASELINE_DIRS)
    pattern = os.path.join(
        RESULTS_DIR, baseline_dir, "smt0", fs,
        f"stats.{fs}.smt0.write.{threads}.128G.{bs}.30.0.0.100.orig_x1.run*"
    )
    files = sorted(glob.glob(pattern))
    if not files:
        return None

    per_write_times = []
    for f in files:
        fields = parse_stats_file(f)
        totals = get_write_totals(fields)
        if totals is None:
            continue
        wtime, wcount = totals
        per_write_times.append(wtime / wcount)
    if not per_write_times:
        return None

    avg = sum(per_write_times) / len(per_write_times)
    # No breakdown available: put all time into FG_Other, BG=0
    return (0.0, 0.0, avg, 0.0)


def block_label(block_size):
    return {"64": "64B", "4k": "4KB", "64k": "64KB"}.get(block_size, block_size)


def normalized_components(step_data, fs, bs, tc, step_index):
    """Return components normalized by that fs/block/thread baseline total."""
    baseline = step_data.get((fs, bs, tc), [None])[0]
    if baseline is None:
        return None
    baseline_total = sum(baseline)
    if baseline_total <= 0:
        return None

    values = step_data.get((fs, bs, tc), [])
    if step_index >= len(values) or values[step_index] is None:
        return None
    return tuple(v / baseline_total for v in values[step_index])


def fmt_value(value):
    if value is None or math.isnan(value):
        return "NaN"
    return f"{value:.12g}"


def write_combined_ablation_dat(step_data, thread_count):
    """Write the paper-style combined ablation dat consumed by gnuplot."""
    out_path = os.path.join(OUTPUT_DIR, f"ablation_{thread_count}t.dat")
    row_positions = {
        "64": [0.0, 1.2, 2.4, 3.6, 4.8],
        "4k": [6.6, 7.8, 9.0, 10.2, 11.4],
        "64k": [13.2, 14.4, 15.6, 16.8, 18.0],
    }

    max_total = 1.0
    with open(out_path, "w") as f:
        f.write(
            "# Pos BS Step "
            "Ext4_OList Ext4_Submission Ext4_Other Ext4_Background "
            "XFS_OList XFS_Submission XFS_Other XFS_Background\n"
        )
        for bs in BLOCK_SIZES:
            for si, label in enumerate(DATA_STEP_LABELS):
                ext4 = normalized_components(step_data, "ext4", bs, thread_count, si)
                xfs = normalized_components(step_data, "xfs", bs, thread_count, si)
                if ext4 is not None:
                    max_total = max(max_total, sum(ext4))
                if xfs is not None:
                    max_total = max(max_total, sum(xfs))

                ext4_vals = ext4 if ext4 is not None else (math.nan,) * 4
                xfs_vals = xfs if xfs is not None else (math.nan,) * 4
                row = [
                    fmt_value(row_positions[bs][si]),
                    bs,
                    label,
                    *(fmt_value(v) for v in ext4_vals),
                    *(fmt_value(v) for v in xfs_vals),
                ]
                f.write("\t".join(row) + "\n")
            f.write("\n")

    return out_path, max_total


def write_combined_ablation_gnuplot(dat_path, thread_count, max_total):
    """Write gnuplot matching ~/figures_fast_scripts/ablation_xfs.gnuplot."""
    gp_path = os.path.join(OUTPUT_DIR, f"ablation_{thread_count}t_combined.gnuplot")
    alias_gp_path = os.path.join(OUTPUT_DIR, "ablation_xfs.gnuplot")
    pdf_name = f"ablation_{thread_count}t_combined.pdf"
    combined_pdf_name = "ablation_combined.pdf"
    dat_name = os.path.basename(dat_path)
    xmax = max(3.5, math.ceil(max_total * 10.0) / 10.0 + 0.2)

    with open(gp_path, "w") as f:
        f.write(f"""\
set terminal pdfcairo enhanced font "Helvetica,16" size 8.5in,2.5in
set output '{pdf_name}'

set multiplot layout 1,2

set grid xtics lt 0 lw 1 lc rgb "#cccccc"
bw = 0.4

set yrange [19:-1]
set xrange [0:{xmax:.1f}]
set xtics 1.0 offset 0,0.5
set tics nomirror

set ytics ( \\
  "Baseline" 0, "Pipeline" 1.2, "+Alloc" 2.4, "+Zeroing" 3.6, "+Batching" 4.8, \\
  "Baseline" 6.6, "Pipeline" 7.8, "+Alloc" 9.0, "+Zeroing" 10.2, "+Batching" 11.4, \\
  "Baseline" 13.2, "Pipeline" 14.4, "+Alloc" 15.6, "+Zeroing" 16.8, "+Batching" 18.0 \\
) font "Helvetica,13"

set label "64B"  at graph -0.27, first 2.4  center font "Helvetica,14"
set label "4KB"  at graph -0.27, first 9.0  center font "Helvetica,14"
set label "64KB" at graph -0.268, first 15.6 center font "Helvetica,14"

sx  = 0.2
sw  = 0.03
sh  = 0.015
sy0 = 0.97
tx  = sx + sw + 0.01

set arrow from graph 0, first 5.7 to graph 1, first 5.7 nohead dt 1 lw 1 lc rgb "#000000" back
set arrow from graph 0, first 12.3 to graph 1, first 12.3 nohead dt 1 lw 1 lc rgb "#000000" back

set object 10 rect from screen sx, screen sy0-sh to screen sx+sw, screen sy0+sh \\
    fc rgb "black" fs solid 0.20 border -1 front
set object 11 rect from screen sx, screen sy0-sh to screen sx+sw, screen sy0+sh \\
    fc rgb "black" fs transparent pattern 6 noborder front
set label 10 "O-List" at screen tx, screen sy0 left

set object 20 rect from screen sx+0.13, screen sy0-sh to screen sx+0.13+sw, screen sy0+sh \\
    fc rgb "black" fs solid 0.20 border -1 front
set object 21 rect from screen sx+0.13, screen sy0-sh to screen sx+0.13+sw, screen sy0+sh \\
    fc rgb "black" fs transparent pattern 10 noborder front
set label 20 "Submission" at screen tx+0.13, screen sy0 left

set object 30 rect from screen sx+0.33, screen sy0-sh to screen sx+0.33+sw, screen sy0+sh \\
    fc rgb "black" fs solid 0.20 border -1 front
set label 30 "Other" at screen tx+0.33, screen sy0 left

set object 40 rect from screen sx+0.46, screen sy0-sh to screen sx+0.46+sw, screen sy0+sh \\
    fc rgb "white" fs solid 1.0 noborder front
set object 41 rect from screen sx+0.46, screen sy0-sh to screen sx+0.46+sw, screen sy0+sh \\
    fc rgb "white" fs empty border lc rgb "black" dt 5 lw 1.5 front
set label 40 "Background" at screen tx+0.46, screen sy0 left

set xlabel "Normalized Latency" offset 20,0.3
set arrow from first 1.0, graph 0 to first 1.0, graph 1 nohead lt 2 lw 1.5 lc rgb "#888888" dashtype 2

set lmargin at screen 0.14
set rmargin at screen 0.55
set bmargin at screen 0.18
set tmargin at screen 0.92
set title "ext4" offset 0,-15.5

plot \\
  '{dat_name}' u (0):($1):(0):($4):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($4):($4+$5):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($4+$5):($4+$5+$6):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($4+$5+$6):($4+$5+$6+$7):($1-bw):($1+bw) \\
    w boxxyerror fillcolor rgb "white" fs solid 1.0 noborder notitle, \\
  '' u ($4+$5+$6):($1-bw):($7):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u ($4+$5+$6):($1+bw):($7):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u ($4+$5+$6+$7):($1-bw):(0):(2*bw) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u (0):($1):(0):($4):($1-bw):($1+bw) \\
    w boxxyerror fs transparent pattern 6 lc rgb "black" notitle, \\
  '' u (0):($1):($4):($4+$5):($1-bw):($1+bw) \\
    w boxxyerror fs transparent pattern 10 lc rgb "black" notitle

set lmargin at screen 0.58
set rmargin at screen 0.99
unset ylabel
set format y ""
set title "XFS" offset 0,-15.5
unset ytics
unset label
unset xlabel

plot \\
  '{dat_name}' u (0):($1):(0):($8):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($8):($8+$9):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($8+$9):($8+$9+$10):($1-bw):($1+bw) \\
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \\
  '' u (0):($1):($8+$9+$10):($8+$9+$10+$11):($1-bw):($1+bw) \\
    w boxxyerror fillcolor rgb "white" fs solid 1.0 noborder notitle, \\
  '' u ($8+$9+$10):($1-bw):($11):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u ($8+$9+$10):($1+bw):($11):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u ($8+$9+$10+$11):($1-bw):(0):(2*bw) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \\
  '' u (0):($1):(0):($8):($1-bw):($1+bw) \\
    w boxxyerror fs transparent pattern 6 lc rgb "black" notitle, \\
  '' u (0):($1):($8):($8+$9):($1-bw):($1+bw) \\
    w boxxyerror fs transparent pattern 10 lc rgb "black" notitle

unset multiplot
""")

    if thread_count == "1":
        shutil.copyfile(gp_path, alias_gp_path)

    return gp_path, os.path.join(OUTPUT_DIR, pdf_name), os.path.join(OUTPUT_DIR, combined_pdf_name)


def run_gnuplot(gp_path):
    if shutil.which("gnuplot") is None:
        print(f"  gnuplot not found; skip PDF for {gp_path}")
        return False
    subprocess.run(
        ["gnuplot", os.path.basename(gp_path)],
        cwd=OUTPUT_DIR,
        check=True,
    )
    return True


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    for pattern in ("*.dat", "*.gnuplot", "*.pdf", "*.png", "*.svg"):
        for path in glob.glob(os.path.join(OUTPUT_DIR, pattern)):
            os.remove(path)

    step_labels = ["Baseline"] + [label for _, label in ABLATION_STEPS]
    all_step_data = {}

    for fs in FILESYSTEMS:
        for bs in BLOCK_SIZES:
            for tc in THREAD_COUNTS:
                # Baseline from orig_x1
                baseline = get_baseline_write_time(fs, bs, tc)
                step_data = [baseline]
                if baseline:
                    print(f"  baseline {fs} {bs} {tc}t: "
                          f"Total={baseline[2]:.1f} {UNIT_LABEL}")
                else:
                    print(f"  baseline {fs} {bs} {tc}t: NO DATA")

                # Collect per-step breakdowns
                for abl_dirs, label in ABLATION_STEPS:
                    bd = get_averaged_breakdown(abl_dirs, fs, bs, tc)
                    step_data.append(bd)
                    if bd:
                        print(f"  {label} {fs} {bs} {tc}t: "
                              f"OList={bd[0]:.1f} Sub={bd[1]:.1f} "
                              f"Other={bd[2]:.1f} BG={bd[3]:.1f} "
                              f"{UNIT_LABEL}")
                    else:
                        print(f"  {label} {fs} {bs} {tc}t: NO DATA")

                basename = f"{fs}_{bs}_{tc}t"
                all_step_data[(fs, bs, tc)] = step_data

                num_steps = len(step_labels)

                # --- Write original .dat (rows=components, cols=steps) ---
                dat_path = os.path.join(OUTPUT_DIR, f"{basename}.dat")
                with open(dat_path, "w") as f:
                    f.write("# " + "\t".join(step_labels) + "\n")
                    for ci, cname in enumerate(COMPONENT_NAMES):
                        vals = []
                        for si in range(num_steps):
                            if step_data[si] is not None:
                                vals.append(f"{step_data[si][ci]:.2f}")
                            else:
                                vals.append("NaN")
                        f.write(f"{cname}\t" + "\t".join(vals) + "\n")

                # --- Write transposed .dat for gnuplot (rows=steps, cols=components) ---
                tdat_path = os.path.join(OUTPUT_DIR, f"{basename}_t.dat")
                with open(tdat_path, "w") as f:
                    f.write("Step\t" + "\t".join(COMPONENT_NAMES) + "\n")
                    for si, label in enumerate(step_labels):
                        if step_data[si] is not None:
                            vals = "\t".join(f"{step_data[si][ci]:.2f}"
                                             for ci in range(4))
                        else:
                            vals = "\t".join(["NaN"] * 4)
                        f.write(f"{label}\t{vals}\n")

                # --- Write gnuplot script ---
                gp_path = os.path.join(OUTPUT_DIR, f"{basename}.gnuplot")
                pdf_name = f"{basename}.pdf"
                tdat_name = f"{basename}_t.dat"

                with open(gp_path, "w") as f:
                    f.write(f"""\
set terminal pdfcairo enhanced font "Arial,12" size 5,3.5
set output "{pdf_name}"

set title "Ablation: {fs.upper()} bs={bs} threads={tc}"
set ylabel "{UNIT_LABEL}"
set style data histograms
set style histogram rowstacked
set style fill solid 0.8 border -1
set boxwidth 0.75
set key outside right top
set xtics nomirror rotate by -20
set ytics nomirror
set grid y

set datafile separator "\\t"
set datafile missing "NaN"

plot "{tdat_name}" using 2:xtic(1) title "FG\\_OList" lc rgb "#4393C3", \\
     "" using 3 title "FG\\_Submission" lc rgb "#D6604D", \\
     "" using 4 title "FG\\_Other" lc rgb "#92C5DE", \\
     "" using 5 title "BG\\_Time" lc rgb "#F4A582"
""")

                print(f"  -> {dat_path}, {tdat_path}, {gp_path}\n")

    for tc in THREAD_COUNTS:
        dat_path, max_total = write_combined_ablation_dat(all_step_data, tc)
        gp_path, pdf_path, combined_pdf_path = write_combined_ablation_gnuplot(dat_path, tc, max_total)
        print(f"  -> {dat_path}, {gp_path}")
        if run_gnuplot(gp_path):
            if os.path.basename(pdf_path) != os.path.basename(combined_pdf_path):
                shutil.copyfile(pdf_path, combined_pdf_path)
            print(f"  -> {pdf_path}, {combined_pdf_path}\n")

    print(f"All files generated in {OUTPUT_DIR}/")
    print("Combined ablation PDFs are generated automatically when gnuplot is available.")


if __name__ == "__main__":
    main()
