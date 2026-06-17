set terminal pdfcairo enhanced font "Helvetica,24" size 7.0in,2.8in
set output '../../figures/Kafka/producer_combined.pdf'

set multiplot layout 1, 2

set style data histogram
set style histogram clustered gap 1.5
set boxwidth 1 relative
set grid ytics lt 0 lw 0.5 lc rgb "#cccccc"
set xrange [-0.7:1.7]
set xtic offset 0,0.2
set linetype 1 lw 2 lc rgb "black"
set linetype 2 lw 2 lc rgb "black"
set linetype 3 lw 2 lc rgb "black"
set border linewidth 2
unset key

# ---- SHARED MANUAL LEGEND ----
leg_y1 = 0.93
leg_y2 = 0.97
box_w  = 0.05
leg_x  = 0.27          # overall horizontal offset for the legend
gap1   = 0.00          # offset for entry 1 (BW)
gap2   = 0.13          # offset for entry 2 (StreamCache)
gap3   = 0.40          # offset for entry 3 (PBW)

set object 10 rect from screen leg_x+gap1, screen leg_y1 to screen leg_x+gap1+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 1 border lc rgb "black" lw 2 front
set label 10 "BW" at screen leg_x+gap1+box_w+0.01, screen (leg_y1+leg_y2)/2 left font "Helvetica,22"

set object 11 rect from screen leg_x+gap2, screen leg_y1 to screen leg_x+gap2+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 4 border lc rgb "black" lw 2 front
set label 11 "StreamCache" at screen leg_x+gap2+box_w+0.01, screen (leg_y1+leg_y2)/2 left font "Helvetica,22"

set object 12 rect from screen leg_x+gap3, screen leg_y1 to screen leg_x+gap3+box_w, screen leg_y2 \
    fc rgb "black" fs transparent pattern 7 border lc rgb "black" lw 2 front
set label 12 "PBW" at screen leg_x+gap3+box_w+0.01, screen (leg_y1+leg_y2)/2 left font "Helvetica,22"

# ---- FIRST PLOT: LATENCY ----
set tmargin at screen 0.87
set bmargin at screen 0.12
set lmargin at screen 0.60
set rmargin at screen 0.98

set yrange [0:1.8]
set ytics 0.4
set ylabel "Latency (s)" offset 1.7,0

plot '../../raw_data/Kafka/producer_absolute.dat' index 0 using ($2/1000.0):xtic(1) title "Baseline" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
'' index 0 using ($3/1000.0) title "StreamCache" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
'' index 0 using ($4/1000.0) title "PipeBWrite" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2

# ---- SECOND PLOT: THROUGHPUT ----


set tmargin at screen 0.87
set bmargin at screen 0.12
set lmargin at screen 0.10
set rmargin at screen 0.46

set yrange [0:22]
set ytics 5
set ylabel "Throughput (MB/s)" offset 1.2,0

plot '../../raw_data/Kafka/producer_absolute.dat' index 1 using 2:xtic(1) title "Baseline" fc rgb "black" fs transparent pattern 1 lc rgb "black" lw 2, \
'' index 1 using 3 title "StreamCache" fc rgb "black" fs transparent pattern 4 lc rgb "black" lw 2, \
'' index 1 using 4 title "PipeBWrite" fc rgb "black" fs transparent pattern 7 lc rgb "black" lw 2

unset multiplot
