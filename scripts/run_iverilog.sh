#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root_dir/build"
mkdir -p "$build_dir"

iverilog -g2012 -Wall -s self_repairing_systolic_tb \
  -o "$build_dir/self_repairing_systolic_tb.vvp" \
  "$root_dir/rtl/systolic_pe.sv" \
  "$root_dir/rtl/systolic_array.sv" \
  "$root_dir/rtl/self_repairing_systolic.sv" \
  "$root_dir/rtl/variants.sv" \
  "$root_dir/tb/self_repairing_systolic_tb.sv"

(cd "$build_dir" && vvp "self_repairing_systolic_tb.vvp")
