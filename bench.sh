#!/bin/bash
# Benchmark statusline implementations

INPUT='{"display_name":"Opus 4.5","version":"1.0.30","current_dir":"/home/nathanjones/Projects/mysuu-portal","used_percentage":42}'
ITERATIONS=100

echo "Benchmarking $ITERATIONS iterations..."
echo ""

# Bash version
echo "Bash (.sh):"
time for i in $(seq 1 $ITERATIONS); do
    echo "$INPUT" | ~/.claude/bobthefish-statusline.sh > /dev/null
done
echo ""

# C version
echo "C version:"
time for i in $(seq 1 $ITERATIONS); do
    echo "$INPUT" | ./statusline > /dev/null
done



