set terminal pdfcairo enhanced font "Helvetica,16" size 8.5in,2.5in
set output '../figures/ablation_combined.pdf'

set multiplot layout 1,2


# Common settings
set grid xtics lt 0 lw 1 lc rgb "#cccccc"
bw = 0.4

# Swap axes: categories on y, latency on x
set yrange [19:-1]
set xrange [0:3.5]
set xtics 1.0 offset 0,0.5

set tics nomirror

# Descriptive y-axis labels
set ytics ( \
  "Baseline" 0, "Pipeline" 1.2, "+Alloc" 2.4, "+Zeroing" 3.6, "+Batching" 4.8, \
  "Baseline" 6.6, "Pipeline" 7.8, "+Alloc" 9.0, "+Zeroing" 10.2, "+Batching" 11.4, \
  "Baseline" 13.2, "Pipeline" 14.4, "+Alloc" 15.6, "+Zeroing" 16.8, "+Batching" 18.0 \
) font "Helvetica,13"

# Block size group labels to the left of ytics
set label "64B"  at graph -0.27, first 2.4    center font "Helvetica,14"
set label "4KB"  at graph -0.27, first 9.0  center font "Helvetica,14"
set label "64KB" at graph -0.268, first 15.6   center font "Helvetica,14"

# Legend (screen coordinates)
sx  = 0.2
sw  = 0.03
sh  = 0.015
sy0 = 0.97
tx  = sx + sw + 0.01

# Add horizontal dividers between groups
set arrow from graph 0, first 5.7 to graph 1, first 5.7 nohead dt 1 lw 1 lc rgb "#000000" back
set arrow from graph 0, first 12.3 to graph 1, first 12.3 nohead dt 1 lw 1 lc rgb "#000000" back

set object 10 rect from screen sx, screen sy0-sh to screen sx+sw, screen sy0+sh \
    fc rgb "black" fs solid 0.20 border -1 front
set object 11 rect from screen sx, screen sy0-sh to screen sx+sw, screen sy0+sh \
    fc rgb "black" fs transparent pattern 6 noborder front
set label 10 "O-List" at screen tx, screen sy0 left

set object 20 rect from screen sx+0.13, screen sy0-sh to screen sx+0.13+sw, screen sy0+sh \
    fc rgb "black" fs solid 0.20 border -1 front
set object 21 rect from screen sx+0.13, screen sy0-sh to screen sx+0.13+sw, screen sy0+sh \
    fc rgb "black" fs transparent pattern 10 noborder front
set label 20 "Submission" at screen tx+0.13, screen sy0 left

set object 30 rect from screen sx+0.33, screen sy0-sh to screen sx+0.33+sw, screen sy0+sh \
    fc rgb "black" fs solid 0.20 border -1 front
set label 30 "Other" at screen tx+0.33, screen sy0 left

set object 40 rect from screen sx+0.46, screen sy0-sh to screen sx+0.46+sw, screen sy0+sh \
    fc rgb "white" fs solid 1.0 noborder front
set object 41 rect from screen sx+0.46, screen sy0-sh to screen sx+0.46+sw, screen sy0+sh \
    fc rgb "white" fs empty border lc rgb "black" dt 5 lw 1.5 front
set label 40 "Background" at screen tx+0.46, screen sy0 left

set xlabel "Normalized Latency" offset 20,0.3

# Reference line at x=1.0 (vertical now, was horizontal)
set arrow from first 1.0, graph 0 to first 1.0, graph 1 nohead lt 2 lw 1.5 lc rgb "#888888" dashtype 2

# Margins — extra left space for labels
set lmargin at screen 0.14
set rmargin at screen 0.99
set bmargin at screen 0.18
set tmargin at screen 0.92

set title "ext4" offset 0,-15.5

# set xlabel "Normalized Latency" offset 0,0.5

set rmargin at screen 0.55

# boxxyerror format: x, y, xlow, xhigh, ylow, yhigh
# Axes swapped: x = latency values, y = category position

plot \
  '../raw_data/ablation_1t.dat' u (0):($1):(0):($4):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($4):($4+$5):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($4+$5):($4+$5+$6):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($4+$5+$6):($4+$5+$6+$7):($1-bw):($1+bw) \
    w boxxyerror fillcolor rgb "white" fs solid 1.0 noborder notitle, \
  '' u ($4+$5+$6):($1-bw):($7):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u ($4+$5+$6):($1+bw):($7):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u ($4+$5+$6+$7):($1-bw):(0):(2*bw) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u (0):($1):(0):($4):($1-bw):($1+bw) \
    w boxxyerror fs transparent pattern 6 lc rgb "black" notitle, \
  '' u (0):($1):($4):($4+$5):($1-bw):($1+bw) \
    w boxxyerror fs transparent pattern 10 lc rgb "black" notitle

# ---- RIGHT SUBPLOT: XFS ----
set lmargin at screen 0.58
set rmargin at screen 0.99
unset ylabel
set format y ""
set title "XFS" offset 0,-15.5

unset ytics
unset label

unset xlabel


plot \
  '../raw_data/ablation_1t.dat' u (0):($1):(0):($8):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($8):($8+$9):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($8+$9):($8+$9+$10):($1-bw):($1+bw) \
    w boxxyerror fs solid 0.20 lc rgb "black" lw 1.5 notitle, \
  '' u (0):($1):($8+$9+$10):($8+$9+$10+$11):($1-bw):($1+bw) \
    w boxxyerror fillcolor rgb "white" fs solid 1.0 noborder notitle, \
  '' u ($8+$9+$10):($1-bw):($11):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u ($8+$9+$10):($1+bw):($11):(0) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u ($8+$9+$10+$11):($1-bw):(0):(2*bw) w vectors nohead dt 5 lw 1.5 lc rgb "black" notitle, \
  '' u (0):($1):(0):($8):($1-bw):($1+bw) \
    w boxxyerror fs transparent pattern 6 lc rgb "black" notitle, \
  '' u (0):($1):($8):($8+$9):($1-bw):($1+bw) \
    w boxxyerror fs transparent pattern 10 lc rgb "black" notitle

unset multiplot
