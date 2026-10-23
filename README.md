# Self-repairing systolic neural accelerator

This repository contains a parameterized signed-int8 matrix-vector accelerator
with a weight-stationary systolic data path, online error detection, and one
spare output column for runtime repair.

## Architecture

`rtl/systolic_pe.sv` implements one processing element. Each PE stores one
weight, forwards its activation to the right on every cycle, and forwards its
partial sum down on every cycle. `rtl/systolic_array.sv` instantiates the PE
mesh and launches the input rows as a staggered wavefront.

The default 8×8 design has ten physical columns:

- columns 0–7 produce the eight logical outputs;
- column 8 is an ABFT checksum column;
- column 9 is a spare column used for repair.

When a real-column weight is written, the controller writes the corresponding
row sum into the checksum column. During inference, the sum of the eight
logical outputs is compared with the checksum-column output. A mismatch starts
an all-ones diagnostic wavefront. The first physical column whose diagnostic
output disagrees with its stored signature is retired, its weights are copied
into the spare, and the logical-to-physical map is updated. If the spare is
already occupied, the affected logical output is invalidated and `degraded`
asserts.

`rtl/variants.sv` exposes two equivalent wrappers:

- `sr_systolic_baseline` uses ordinary multiplier and accumulator updates;
- `sr_systolic_optimized` uses operand isolation for zero activations and a
  true accumulator clock-enable condition.

## Verification

The Icarus testbench checks matrix-vector results, zero-heavy inputs, checksum
fault detection, column localisation, spare-column repair, and graceful
degradation after a second fault.

```sh
make test
```

The waveform is written to `build/systolic.vcd`. Verilator lint and the cocotb
regression are also included in the CI workflow:

```sh
make lint
make cocotb
```

The cocotb run writes cycle-level completion, detection, and repair latency to
`build/rtl_metrics.json`. `make activity` converts the representative RTL
workload waveform into `build/activity.saif`, which can be supplied to a
power-analysis flow. SAIF is an activity input, not a fabricated power result.

The browser demo in `demo/` makes the data path and repair sequence tangible:

```sh
python3 -m http.server 8000 --directory demo
```

Open <http://localhost:8000> and inject a stuck-at or bit-flip fault.

## Synthesis and PPA

The Yosys smoke test synthesizes both wrappers and records cell statistics in
`build/synthesis`:

```sh
make synth
```

For Sky130 area, timing, and power measurements, use the OpenLane configuration
under `openlane/`. The companion
[`systolic-ppa-sweep`](https://github.com/amitboda03-labgeek/systolic-ppa-sweep)
repository runs parallel experiments across clock targets, density targets,
and design variants, then parses timing, area, and power reports into a Pareto
plot. The repository does not claim physical PPA numbers until OpenLane and a
Sky130 PDK are actually run; `make synth` is only a Yosys RTL smoke test.

## Quantized workload experiment

`experiments/mnist_fault_experiment.py` applies four fixed 3×3 edge filters and
ReLU to make a tiny convolutional feature stack, trains its eight-class head
with NumPy, quantizes the 144 features and weights to signed int8, and tiles
them into the same 8×8 matrix operations as the RTL. It sweeps permanent PE
faults and reports unprotected versus one-spare ABFT-protected accuracy in
JSON, CSV, and SVG form:

```sh
python3 experiments/mnist_fault_experiment.py --synthetic --limit 128
# or use official IDX files:
python3 experiments/mnist_fault_experiment.py --download --limit 512
```

The synthetic command is the fast CI smoke test. The MNIST command uses the
official 28×28 data, average-pools it to 8×8, and keeps digits 0–7 so the
classifier head can be tiled into eighteen accelerator matrix operations.

See [`docs/implementation-matrix.md`](docs/implementation-matrix.md) for the
report-to-implementation checklist and the remaining physical-flow boundary.

## Repository layout

- `rtl/` — processing element, systolic array, controller, and wrappers.
- `tb/` — SystemVerilog and cocotb regressions.
- `openlane/` — Sky130/OpenLane configuration.
- `scripts/` — simulation and Yosys smoke-test entry points.
- `tools/` — waveform-to-SAIF activity conversion.
- `experiments/` — quantized workload and fault-accuracy experiment.
- `demo/` — static browser walkthrough of detection and repair.
