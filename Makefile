.PHONY: test clean lint synth

ROOT := $(abspath .)

test:
	./scripts/run_iverilog.sh

lint:
	iverilog -g2012 -Wall -t null \
	  rtl/self_repairing_systolic.sv rtl/variants.sv

synth:
	./scripts/synthesize.sh

clean:
	rm -rf build
