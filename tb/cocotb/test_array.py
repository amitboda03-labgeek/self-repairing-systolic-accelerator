from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge


ROWS = 8
COLS = 8
PHYS_COLS = COLS + 2
ACC_W = 24


async def write_weight(dut, row: int, col: int, value: int) -> None:
    dut.weight_we.value = 1
    dut.weight_row.value = row
    dut.weight_col.value = col
    dut.weight_data.value = value & 0xFF
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.weight_we.value = 0


async def write_activation(dut, row: int, value: int) -> None:
    dut.activation_we.value = 1
    dut.activation_index.value = row
    dut.activation_data.value = value & 0xFF
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.activation_we.value = 0


async def set_fault(dut, row: int, col: int, mode: int) -> None:
    dut.fault_we.value = 1
    dut.fault_row.value = row
    dut.fault_col.value = col
    dut.fault_mode.value = mode
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.fault_we.value = 0


async def run(dut, label: str, metrics: list[dict[str, int | str]]) -> None:
    cocotb.log.info("starting accelerator operation")
    dut.start.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.start.value = 0
    # A detected fault is an intermediate state; wait for the repair
    # transaction to finish rather than treating detect_error as completion.
    cycles = 0
    detection_cycles = None
    for _ in range(200):
        await RisingEdge(dut.clk)
        cycles += 1
        if detection_cycles is None and int(dut.detect_error.value):
            detection_cycles = cycles
        if int(dut.done.value) or int(dut.repair_done.value):
            cocotb.log.info(
                "accelerator operation complete: done=%d repair_done=%d "
                "detect_error=%d spare=%d degraded=%d",
                int(dut.done.value), int(dut.repair_done.value),
                int(dut.detect_error.value), int(dut.spare_in_use.value),
                int(dut.degraded.value),
            )
            metrics.append(
                {
                    "label": label,
                    "completion_cycles": cycles,
                    "detection_cycles": detection_cycles or 0,
                    "repair_cycles": (cycles - detection_cycles)
                    if detection_cycles is not None
                    else 0,
                }
            )
            return
    raise AssertionError("accelerator operation did not complete within 200 cycles")


def signed(value: int, width: int) -> int:
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


@cocotb.test()
async def repair_preserves_logical_outputs(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.reset_n.value = 0
    dut.start.value = 0
    dut.weight_we.value = 0
    dut.activation_we.value = 0
    dut.fault_we.value = 0
    dut.fault_clear.value = 0
    dut.fault_mode.value = 0
    for _ in range(2):
        await FallingEdge(dut.clk)
    dut.reset_n.value = 1

    activations = list(range(1, ROWS + 1))
    metrics: list[dict[str, int | str]] = []
    for row, value in enumerate(activations):
        await write_activation(dut, row, value)
    for row in range(ROWS):
        for col in range(COLS):
            await write_weight(dut, row, col, row + col + 1)

    cocotb.log.info("configuration loaded")
    await run(dut, "clean_inference", metrics)
    for col in range(COLS):
        expected = sum(activations[row] * (row + col + 1) for row in range(ROWS))
        actual = signed(int(dut.output_data.value) >> (col * ACC_W), ACC_W)
        assert actual == expected
    await set_fault(dut, 2, 3, 1)
    await run(dut, "fault_detection_and_repair", metrics)
    for _ in range(200):
        if int(dut.spare_in_use.value):
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("fault repair did not consume the spare column")

    await run(dut, "post_repair_inference", metrics)
    for col in range(COLS):
        expected = sum(activations[row] * (row + col + 1) for row in range(ROWS))
        actual = signed(int(dut.output_data.value) >> (col * ACC_W), ACC_W)
        assert actual == expected

    metrics_path = Path(
        os.environ.get("RTL_METRICS_FILE", "../build/rtl_metrics.json")
    )
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.write_text(json.dumps({"operations": metrics}, indent=2) + "\n")
