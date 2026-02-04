#!/bin/bash
# Benchmark statusline implementations

CWD="$(pwd)"
INPUT="{
  \"model\": {\"id\": \"claude-opus-4-5-20251101\", \"display_name\": \"Opus 4.5\"},
  \"workspace\": {\"current_dir\": \"$CWD\"},
  \"cost\": {\"total_cost_usd\": 0.64, \"total_duration_ms\": 295637, \"total_lines_added\": 156, \"total_lines_removed\": 23},
  \"context_window\": {\"used_percentage\": 42, \"input_tokens\": 10, \"output_tokens\": 3, \"cache_creation_input_tokens\": 51, \"cache_read_input_tokens\": 47250},
  \"vim\": {\"mode\": \"INSERT\"}
}"

ITERATIONS=${1:-100}

echo "Benchmarking statusline implementations ($ITERATIONS iterations each)"
echo "======================================================================="
echo ""

# Build both versions first
echo "Building..."
make -s statusline 2>/dev/null
odin build . -o:speed -no-bounds-check -disable-assert -microarch:native -out:statusline_odin 2>/dev/null
echo ""

# C version
echo "C version (./statusline):"
C_START=$(date +%s%N)
for i in $(seq 1 $ITERATIONS); do
    echo "$INPUT" | ./statusline > /dev/null
done
C_END=$(date +%s%N)
C_TIME=$(( (C_END - C_START) / 1000000 ))
C_AVG=$(echo "scale=2; $C_TIME / $ITERATIONS" | bc)
echo "  Total: ${C_TIME}ms | Avg: ${C_AVG}ms/iter"
echo ""

# Odin version
echo "Odin version (./statusline_odin):"
ODIN_START=$(date +%s%N)
for i in $(seq 1 $ITERATIONS); do
    echo "$INPUT" | ./statusline_odin > /dev/null
done
ODIN_END=$(date +%s%N)
ODIN_TIME=$(( (ODIN_END - ODIN_START) / 1000000 ))
ODIN_AVG=$(echo "scale=2; $ODIN_TIME / $ITERATIONS" | bc)
echo "  Total: ${ODIN_TIME}ms | Avg: ${ODIN_AVG}ms/iter"
echo ""

# Comparison
echo "======================================================================="
if [ "$C_TIME" -lt "$ODIN_TIME" ]; then
    DIFF=$(echo "scale=1; $ODIN_TIME * 100 / $C_TIME - 100" | bc)
    echo "C is ${DIFF}% faster"
else
    DIFF=$(echo "scale=1; $C_TIME * 100 / $ODIN_TIME - 100" | bc)
    echo "Odin is ${DIFF}% faster"
fi
