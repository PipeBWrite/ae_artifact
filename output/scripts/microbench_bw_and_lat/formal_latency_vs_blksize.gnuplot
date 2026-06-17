set terminal pdfcairo enhanced font "Helvetica,28" size 6in,3.2in

# Shared formal style (mirrors RocksDB formal plots)
set style data histogram
set style histogram clustered gap 1.5
set boxwidth 1 relative
set xrange [-0.7:2.7]
set yrange [0:1.3]
set ytics 0.2
set grid ytics lt 0 lw 1.5 lc rgb "#cccccc"
set arrow from graph 0, first 1.0 to graph 1, first 1.0 nohead lt 2 lw 1.0 lc rgb "#888888" dashtype 2

set tmargin at screen 0.90
set bmargin at screen 0.11
set rmargin at screen 0.98
set xtic offset 0,0.2
# set label 10 "Block Size" at screen 0.54, screen 0.04 center

set style fill pattern border lc rgb "black"
set linetype 1 lw 2 lc rgb "black"
set linetype 2 lw 2 lc rgb "black"
set linetype 3 lw 2 lc rgb "black"
set border linewidth 2

# ---- MANUAL LEGEND (screen coordinates) ----
leg_y1 = 0.93
leg_y2 = 0.97
box_w  = 0.05
leg_x  = 0.27          # overall horizontal offset for the legend
gap1   = 0.00          # offset for entry 1 (BW)
gap2   = 0.15          # offset for entry 2 (StreamCache)
gap3   = 0.45          # offset for entry 3 (PBW)

# Entry 1: BW (pattern 1)
set object 10 rect from screen leg_x+gap1, screen leg_y1 to screen leg_x+gap1+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 1 border lc rgb "black" lw 2 front
set label 10 "BW" at screen leg_x+gap1+box_w+0.01, screen (leg_y1+leg_y2)/2 left \
    font "Helvetica,22"

# Entry 2: StreamCache (pattern 4)
set object 11 rect from screen leg_x+gap2, screen leg_y1 to screen leg_x+gap2+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 4 border lc rgb "black" lw 2 front
set label 11 "StreamCache" at screen leg_x+gap2+box_w+0.01, screen (leg_y1+leg_y2)/2 left \
    font "Helvetica,22"

# Entry 3: PBW (pattern 7)
set object 12 rect from screen leg_x+gap3, screen leg_y1 to screen leg_x+gap3+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 7 border lc rgb "black" lw 2 front
set label 12 "PBW" at screen leg_x+gap3+box_w+0.01, screen (leg_y1+leg_y2)/2 left \
    font "Helvetica,22"

unset key

# ==============================
# Figure 1: Avg latency, low t
# ==============================
set output '../../figures/microbench_bw_and_lat/formal_avg_1t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Avg Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_avg_1t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -1.4,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set output '../../figures/microbench_bw_and_lat/formal_avg_40t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Avg Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_avg_40t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -3.8,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set output '../../figures/microbench_bw_and_lat/formal_avg_80t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Avg Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_avg_80t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -3.8,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

######################

set output '../../figures/microbench_bw_and_lat/formal_p99_1t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized P99 Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_p99_1t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -3.8,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set output '../../figures/microbench_bw_and_lat/formal_p99_40t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized P99 Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_p99_40t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -3.8,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set output '../../figures/microbench_bw_and_lat/formal_p99_80t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized P99 Latency" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/lat_p99_80t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.2f{/Symbol m}s", $5)) with labels center offset -3.8,0.6 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

######################
set yrange [0:2.5]
set ytics 0.5

set output '../../figures/microbench_bw_and_lat/formal_tp_1t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Throughput" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/bw_1t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.1f", $5)) with labels center offset -3.0,0.7 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set output '../../figures/microbench_bw_and_lat/formal_tp_40t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Throughput" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/bw_40t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.1f", $5)) with labels center offset -3.0,0.7 font "Helvetica,24" tc rgb "black" notitle

unset multiplot

set yrange [0:1.4]
set ytics 0.2

set output '../../figures/microbench_bw_and_lat/formal_tp_80t.pdf'
set format y "%.1f"
set multiplot

set lmargin at screen 0.15
# set rmargin at screen 0.53
set ylabel "Normalized Throughput" offset 1.0,0
# set title "1" offset 0,0
# set key above horizontal Left reverse font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,0.4

plot '../../raw_data/microbench_bw_and_lat/bw_80t_ext4.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
     '' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
     '' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2, \
     '' using 0:2:(sprintf("%.1f", $5)) with labels center offset -3.3,0.7 font "Helvetica,24" tc rgb "black" notitle

unset multiplot
