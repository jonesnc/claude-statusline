#!/bin/bash
# Benchmark statusline implementations

CWD="$(pwd)"
INPUT="{
  \"model\": {\"id\": \"claude-sonnet-4-20250514\", \"display_name\": \"Sonnet 4\"},
  \"workspace\": {\"current_dir\": \"$CWD\"},
  \"cost\": {\"total_cost_usd\": 2.47, \"total_duration_ms\": 847293, \"total_lines_added\": 312, \"total_lines_removed\": 89},
  \"context_window\": {\"total_input_tokens\": 283432, \"total_output_tokens\": 42847, \"context_window_size\": 200000, \"used_percentage\": 67, \"current_usage\": {\"input_tokens\": 89432, \"output_tokens\": 12847, \"cache_creation_input_tokens\": 24680, \"cache_read_input_tokens\": 156320}},
  \"vim\": {\"mode\": \"NORMAL\"}
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

echo ""
echo "======================================================================="
echo "Odin Profiling (single run with STATUSLINE_DEBUG=1):"
echo "======================================================================="
echo ""

# First run - cache miss (clears any existing cache)
rm -f /dev/shm/claude-git-* 2>/dev/null
echo "Cache MISS (first run):"
echo "$INPUT" | STATUSLINE_DEBUG=1 ./statusline_odin 2>&1 | grep -E "^timing:" | sed 's/^/  /'
echo ""

# Second run - cache hit
echo "Cache HIT (second run):"
echo "$INPUT" | STATUSLINE_DEBUG=1 ./statusline_odin 2>&1 | grep -E "^timing:" | sed 's/^/  /'
