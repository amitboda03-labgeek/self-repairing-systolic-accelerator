from __future__ import annotations

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
    await FallingEdge(dut.clk)
    dut.weight_we.value = 0


async def write_activation(dut, row: int, value: int) -> None:
    dut.activation_we.value = 1
    dut.activation_index.value = row
    dut.activation_data.value = value & 0xFF
    await FallingEdge(dut.clk)
    dut.activation_we.value = 0


async def set_fault(dut, row: int, col: int, mode: int) -> None:
    dut.fault_we.value = 1
    dut.fault_row.value = row
    dut.fault_col.value = col
    dut.fault_mode.value = mode
    await FallingEdge(dut.clk)
    dut.fault_we.value = 0


async def run(dut) -> None:
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    # A detected fault is an intermediate state; wait for the repair
    # transaction to finish rather than treating detect_error as completion.
    while not int(dut.done.value) and not int(dut.repair_done.value):
        await RisingEdge(dut.clk)


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
    for row, value in enumerate(activations):
        await write_activation(dut, row, value)
    for row in range(ROWS):
        for col in range(COLS):
            await write_weight(dut, row, col, row + col + 1)

    await run(dut)
    for col in range(COLS):
        expected = sum(activations[row] * (row + col + 1) for row in range(ROWS))
        actual = signed(int(dut.output_data.value) >> (col * ACC_W), ACC_W)
        assert actual == expected
    await set_fault(dut, 2, 3, 1)
    await run(dut)
    while not int(dut.spare_in_use.value):
        await RisingEdge(dut.clk)

    await run(dut)
    for col in range(COLS):
        expected = sum(activations[row] * (row + col + 1) for row in range(ROWS))
        actual = signed(int(dut.output_data.value) >> (col * ACC_W), ACC_W)
        assert actual == expected
