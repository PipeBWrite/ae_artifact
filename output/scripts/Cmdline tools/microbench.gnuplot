set terminal pdfcairo enhanced font "Helvetica,24" size 7in,2.8in

set output '../../figures/Cmdline tools/cli.pdf'

# Common settings for both subplots
set style data histogram
set style histogram clustered gap 1.5
set boxwidth 1 relative
set yrange [0:30]
set xrange [-0.7:3.7]
# set ytics 0.2
set grid ytics lt 0 lw 0.5 lc rgb "#cccccc"
# set arrow from graph 0, first 1.0 to graph 1, first 1.0 nohead lt 2 lw 1.0 lc rgb "#888888" dashtype 2

# Shared vertical margins
set tmargin at screen 0.90
set bmargin at screen 0.18
set rmargin at screen 0.98

# set xtic offset 0,0.5 font "Helvetica,22"

set xtic offset 0,0.2


# set label 10 "YCSB Workload" at screen 0.54, screen 0.04 center

set linetype 1 lw 2 lc rgb "black"
set linetype 2 lw 2 lc rgb "black"
set linetype 3 lw 2 lc rgb "black"
set grid ytics lt 0 lw 1.5 lc rgb "#cccccc"

set border linewidth 2


# ---- MANUAL LEGEND (screen coordinates) ----
leg_y1 = 0.93
leg_y2 = 0.97
box_w  = 0.05
leg_x  = 0.27          # overall horizontal offset for the legend
gap1   = 0.00          # offset for entry 1 (BW)
gap2   = 0.13          # offset for entry 2 (StreamCache)
gap3   = 0.40          # offset for entry 3 (PBW)

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

set multiplot

# ---- LEFT SUBPLOT: ext4 ----
set lmargin at screen 0.12
set rmargin at screen 0.53

set ylabel "Exec. Time (s)" offset 1.5,0
set title "ext4" offset 0,-12.3

set tics nomirror


# set key above horizontal Left reverse \
#     font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.6 offset 0,-0.6
# set key above center Left reverse font "Helvetica,14" samplen 2 spacing 1.2 maxrows 1 width 2 offset 0,-0.5

unset key

plot '../../raw_data/Cmdline tools/data.dat' using 2:xtic(1) title "ext4" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
'' using 3 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
'' using 4 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2

# ---- RIGHT SUBPLOT: XFS ----
set lmargin at screen 0.58
set rmargin at screen 0.98

set key above horizontal Left reverse \
    font "Helvetica,22" samplen 2 spacing 1.2 width 0 maxrows 1 width -0.2 offset 0,-0.6

unset key

unset ylabel            # shared y-axis: no label on right
set format y ""         # hide y-tic labels on right plot
set title "XFS" offset 0,-12.3


plot '../../raw_data/Cmdline tools/data.dat' using 5:xtic(1) title "XFS" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
'' using 6 title "SC" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
'' using 7 title "PBW" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2

# (then your pattern overlay layer for XFS...)

unset multiplot
