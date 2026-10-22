`timescale 1ns/1ps

// Named wrappers keep the verification interface identical while exposing a
// baseline and a power-oriented PE implementation to synthesis.

module sr_systolic_baseline #(
    parameter integer ROWS = 8,
    parameter integer COLS = 8,
    parameter integer PHYS_COLS = COLS + 2,
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 24
) (
    input wire clk, input wire reset_n, input wire start,
    input wire weight_we, input wire [$clog2(ROWS)-1:0] weight_row,
    input wire [$clog2(PHYS_COLS)-1:0] weight_col,
    input wire signed [DATA_W-1:0] weight_data,
    input wire fault_we, input wire fault_clear,
    input wire [$clog2(ROWS)-1:0] fault_row,
    input wire [$clog2(PHYS_COLS)-1:0] fault_col,
    input wire [1:0] fault_mode,
    input wire activation_we,
    input wire [$clog2(ROWS)-1:0] activation_index,
    input wire signed [DATA_W-1:0] activation_data,
    output wire busy, output wire done, output wire detect_error,
    output wire repair_done, output wire degraded,
    output wire [PHYS_COLS-1:0] dead_columns,
    output wire spare_in_use,
    output wire signed [COLS*ACC_W-1:0] output_data
);
    self_repairing_systolic #(
        .ROWS(ROWS), .COLS(COLS), .PHYS_COLS(PHYS_COLS),
        .DATA_W(DATA_W), .ACC_W(ACC_W),
        .ZERO_SKIP(0), .CLOCK_GATED(0)
    ) u_core (
        .clk(clk), .reset_n(reset_n), .start(start),
        .weight_we(weight_we), .weight_row(weight_row), .weight_col(weight_col),
        .weight_data(weight_data), .fault_we(fault_we), .fault_clear(fault_clear),
        .fault_row(fault_row), .fault_col(fault_col), .fault_mode(fault_mode),
        .activation_we(activation_we), .activation_index(activation_index),
        .activation_data(activation_data), .busy(busy), .done(done),
        .detect_error(detect_error), .repair_done(repair_done),
        .degraded(degraded), .dead_columns(dead_columns),
        .spare_in_use(spare_in_use), .output_data(output_data)
    );
endmodule

module sr_systolic_optimized #(
    parameter integer ROWS = 8,
    parameter integer COLS = 8,
    parameter integer PHYS_COLS = COLS + 2,
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 24
) (
    input wire clk, input wire reset_n, input wire start,
    input wire weight_we, input wire [$clog2(ROWS)-1:0] weight_row,
    input wire [$clog2(PHYS_COLS)-1:0] weight_col,
    input wire signed [DATA_W-1:0] weight_data,
    input wire fault_we, input wire fault_clear,
    input wire [$clog2(ROWS)-1:0] fault_row,
    input wire [$clog2(PHYS_COLS)-1:0] fault_col,
    input wire [1:0] fault_mode,
    input wire activation_we,
    input wire [$clog2(ROWS)-1:0] activation_index,
    input wire signed [DATA_W-1:0] activation_data,
    output wire busy, output wire done, output wire detect_error,
    output wire repair_done, output wire degraded,
    output wire [PHYS_COLS-1:0] dead_columns,
    output wire spare_in_use,
    output wire signed [COLS*ACC_W-1:0] output_data
);
    self_repairing_systolic #(
        .ROWS(ROWS), .COLS(COLS), .PHYS_COLS(PHYS_COLS),
        .DATA_W(DATA_W), .ACC_W(ACC_W),
        .ZERO_SKIP(1), .CLOCK_GATED(1)
    ) u_core (
        .clk(clk), .reset_n(reset_n), .start(start),
        .weight_we(weight_we), .weight_row(weight_row), .weight_col(weight_col),
        .weight_data(weight_data), .fault_we(fault_we), .fault_clear(fault_clear),
        .fault_row(fault_row), .fault_col(fault_col), .fault_mode(fault_mode),
        .activation_we(activation_we), .activation_index(activation_index),
        .activation_data(activation_data), .busy(busy), .done(done),
        .detect_error(detect_error), .repair_done(repair_done),
        .degraded(degraded), .dead_columns(dead_columns),
        .spare_in_use(spare_in_use), .output_data(output_data)
    );
endmodule
