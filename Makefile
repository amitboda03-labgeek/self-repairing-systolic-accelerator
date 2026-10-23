.PHONY: test clean lint synth cocotb metrics activity evidence experiment-smoke

ROOT := $(abspath .)

test:
	./scripts/run_iverilog.sh

lint:
	verilator --lint-only -Wall --Wno-fatal \
	  --top-module sr_systolic_baseline \
	  rtl/systolic_pe.sv rtl/systolic_array.sv \
	  rtl/self_repairing_systolic.sv rtl/variants.sv

synth:
	./scripts/synthesize.sh

cocotb:
	@if command -v cocotb-config >/dev/null 2>&1; then \
		$(MAKE) -C tb -f Makefile.cocotb SIM=verilator; \
	elif [ -x "$(ROOT)/.venv/bin/cocotb-config" ]; then \
		PATH="$(ROOT)/.venv/bin:$$PATH" VIRTUAL_ENV="$(ROOT)/.venv" $(MAKE) -C tb -f Makefile.cocotb SIM=verilator; \
	else \
		echo "cocotb-config not found; create .venv and install 'cocotb<2'" >&2; \
		exit 1; \
	fi

metrics: cocotb

activity: test
	python3 tools/vcd_to_saif.py build/systolic.vcd build/activity.saif

evidence: test metrics activity

experiment-smoke:
	python3 experiments/mnist_fault_experiment.py --synthetic --limit 128 --output build/fault-experiment

clean:
	rm -rf build
