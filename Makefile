.PHONY: test clean lint synth cocotb

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
	$(MAKE) -C tb -f Makefile.cocotb SIM=verilator

clean:
	rm -rf build
