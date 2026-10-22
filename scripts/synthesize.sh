#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$root_dir/build/synthesis}"
mkdir -p "$output_dir"

if ! command -v yosys >/dev/null 2>&1; then
  echo "yosys is required for the synthesis smoke test" >&2
  exit 2
fi

for variant in baseline optimized; do
  case "$variant" in
    baseline) top="sr_systolic_baseline" ;;
    optimized) top="sr_systolic_optimized" ;;
  esac
  yosys -p "read_verilog -sv $root_dir/rtl/systolic_pe.sv $root_dir/rtl/systolic_array.sv $root_dir/rtl/self_repairing_systolic.sv $root_dir/rtl/variants.sv; hierarchy -top $top; proc; opt; check; stat" \
    | tee "$output_dir/${variant}.log"
done

echo "Synthesis smoke tests written to $output_dir"
