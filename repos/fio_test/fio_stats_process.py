import re
import os
from dataclasses import dataclass
import sys

@dataclass
class typ_dat:
    name: str
    count: int
    time: int|str
    avg: float|str

orig_x1_stat_arg = sys.argv[1]
async_x1_stat_arg = sys.argv[2]
scache_x1_stat_arg = sys.argv[3]
other_tag = sys.argv[4]

def split_files(arg):
    if not arg:
        return []
    if "," in arg:
        return [p.strip() for p in arg.split(",") if p.strip()]
    return [arg]

def parse_bucket(line):
    # Extracting the numbers from the text
    matches = re.findall(r"==> BUCKET: (\w+) ((?:\d+ -> \d+: \d+ ?)+)", line)
    bucket_name = matches[0][0]
    print("Bucket name: {}".format(bucket_name))
    data = matches[0][1]

    data_matches = re.findall(r"(\d+) -> (\d+): (\d+)", data)
    for match in data_matches:
        print("{} -> {}: {}".format(match[0], match[1], match[2]))

def gen_stat(file):
    stats = {}
    if not os.path.exists(file):
        return stats
    with open(file, "r") as f:
        for line in f.readlines():
            if 'BUCKET' in line:
                # Parse bucket
                parse_bucket(line)
                continue
            time = "N/A"
            type_name = "N/A"
            count = 0
            average = "N/A"

            match = re.search(r'(\w+): (\d+), (\w+): (\d+)', line)
            if match:
                type_name = line.split(':')[0].strip('==> ')
                time = int(match.group(2))
                count = int(match.group(4))
                average = round(time / count, 2) if count > 0 else "N/A"
            else:
                # Handle lines that only have count
                match = re.search(r'(\w+): (\d+)', line)
                if match:
                    type_name = line.split(':')[0].strip('==> ')
                    count = int(match.group(2))
    
            stats[type_name] = {"count": count, "time": time, "avg": average}
    return stats

def merge_stats(stat_list):
    agg = {}
    for stats in stat_list:
        for k, v in stats.items():
            entry = agg.setdefault(k, {"count": 0, "time": None, "avg": "N/A"})
            count = v.get("count", 0)
            if isinstance(count, int):
                entry["count"] += count
            time_val = v.get("time")
            if isinstance(time_val, int):
                if entry["time"] is None:
                    entry["time"] = 0
                entry["time"] += time_val
    for k, v in agg.items():
        if isinstance(v["time"], int) and v["count"] > 0:
            v["avg"] = round(v["time"] / v["count"], 2)
        else:
            v["time"] = "N/A"
            v["avg"] = "N/A"
    return agg

o1_stat = merge_stats([gen_stat(p) for p in split_files(orig_x1_stat_arg)])
a1_stat = merge_stats([gen_stat(p) for p in split_files(async_x1_stat_arg)])
s1_stat = merge_stats([gen_stat(p) for p in split_files(scache_x1_stat_arg)])

tbl_template = """
[*Field*], [*Time*], [*Count*], [*Average*],
"""


def stat_values(stats, key):
    if key in stats:
        row = stats[key]
        return row["time"], row["count"], row["avg"]
    return "N/A", 0, "N/A"


def gen_tbl(orig_x1_stat, async_x1_stat, scache_x1_stat):
    print(f"- COMM breakdown {other_tag} (ORIG x1 -> ASYNC x1 -> SCACHE x1)")
    print(tbl_template)

    keys = sorted(set(orig_x1_stat.keys()) | set(async_x1_stat.keys()) | set(scache_x1_stat.keys()))
    for key in keys:
        o1_time, o1_count, o1_avg = stat_values(orig_x1_stat, key)
        a1_time, a1_count, a1_avg = stat_values(async_x1_stat, key)
        s1_time, s1_count, s1_avg = stat_values(scache_x1_stat, key)
        print(
            f"{key}\t{o1_time} -> {a1_time} -> {s1_time}\t"
            f"{o1_count} -> {a1_count} -> {s1_count}\t"
            f"{o1_avg} -> {a1_avg} -> {s1_avg}"
        )
    print(")\n")

    print(f"- ORIG x1: {other_tag} (Only in ORIG x1)")
    print(tbl_template)
    for key in sorted(orig_x1_stat.keys()):
        if key in async_x1_stat or key in scache_x1_stat:
            continue
        row = orig_x1_stat[key]
        print(f"{key}\t{row['time']}\t{row['count']}\t{row['avg']}")
    print(")\n")

    print(f"- ASYNC x1: {other_tag} (Only in ASYNC x1)")
    print(tbl_template)
    for key in sorted(async_x1_stat.keys()):
        if key in orig_x1_stat or key in scache_x1_stat:
            continue
        row = async_x1_stat[key]
        print(f"{key}\t{row['time']}\t{row['count']}\t{row['avg']}")
    print(")\n")

    print(f"- SCACHE x1: {other_tag} (Only in SCACHE x1)")
    print(tbl_template)
    for key in sorted(scache_x1_stat.keys()):
        if key in orig_x1_stat or key in async_x1_stat:
            continue
        row = scache_x1_stat[key]
        print(f"{key}\t{row['time']}\t{row['count']}\t{row['avg']}")
    print(")\n")


gen_tbl(o1_stat, a1_stat, s1_stat)
