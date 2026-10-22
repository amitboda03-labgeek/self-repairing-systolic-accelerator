`timescale 1ns/1ps

// Weight-stationary systolic array.  Each PE owns one weight.  Activations
// travel right and partial sums travel down; the controller staggers the
// input rows so that a matrix-vector operation fills the array over time.
module systolic_array #(
    parameter integer ROWS        = 8,
    parameter integer COLS        = 8,
    parameter integer PHYS_COLS   = COLS + 2,
    parameter integer DATA_W      = 8,
    parameter integer WEIGHT_W    = DATA_W + $clog2(COLS),
    parameter integer ACC_W       = 24,
    parameter integer ZERO_SKIP   = 0,
    parameter integer CLOCK_GATED = 0
) (
    input  wire                                  clk,
    input  wire                                  reset_n,
    input  wire                                  start,
    input  wire                                  test_mode,
    input  wire signed [ROWS*DATA_W-1:0]         activation_vector,

    input  wire                                  weight_we,
    input  wire [$clog2(ROWS)-1:0]               weight_row,
    input  wire [$clog2(PHYS_COLS)-1:0]          weight_col,
    input  wire signed [WEIGHT_W-1:0]            weight_data,
    input  wire                                  checksum_weight_we,
    input  wire [$clog2(ROWS)-1:0]               checksum_weight_row,
    input  wire signed [WEIGHT_W-1:0]            checksum_weight_data,

    input  wire                                  fault_we,
    input  wire [$clog2(ROWS)-1:0]               fault_row,
    input  wire [$clog2(PHYS_COLS)-1:0]          fault_col,
    input  wire [1:0]                            fault_mode,

    output reg                                   running,
    output reg                                   valid,
    output wire signed [PHYS_COLS*ACC_W-1:0]     result_data
);

    localparam integer CHECKSUM_COL = COLS;
    localparam integer WAVE_CYCLES  = ROWS + PHYS_COLS;
    localparam integer CYCLE_W      = (WAVE_CYCLES <= 2) ? 1 : $clog2(WAVE_CYCLES + 1);

    reg test_mode_reg;
    reg [CYCLE_W-1:0] cycle_count;

    wire signed [DATA_W-1:0] activation_in [0:ROWS-1][0:PHYS_COLS-1];
    wire signed [DATA_W-1:0] activation_out [0:ROWS-1][0:PHYS_COLS-1];
    wire signed [ACC_W-1:0] psum_in [0:ROWS-1][0:PHYS_COLS-1];
    wire signed [ACC_W-1:0] psum_out [0:ROWS-1][0:PHYS_COLS-1];

    genvar row;
    genvar col;
    generate
        for (row = 0; row < ROWS; row = row + 1) begin : g_inputs
            assign activation_in[row][0] =
                (running && (cycle_count == row)) ?
                    (test_mode_reg ? {{(DATA_W-1){1'b0}}, 1'b1} :
                                     activation_vector[row*DATA_W +: DATA_W]) :
                    {DATA_W{1'b0}};
            for (col = 1; col < PHYS_COLS; col = col + 1) begin : g_activation_links
                assign activation_in[row][col] = activation_out[row][col-1];
            end
        end

        for (col = 0; col < PHYS_COLS; col = col + 1) begin : g_psum_inputs
            assign psum_in[0][col] = {ACC_W{1'b0}};
            for (row = 1; row < ROWS; row = row + 1) begin : g_psum_links
                assign psum_in[row][col] = psum_out[row-1][col];
            end
        end

        for (row = 0; row < ROWS; row = row + 1) begin : g_pes_row
            for (col = 0; col < PHYS_COLS; col = col + 1) begin : g_pes_col
                wire pe_weight_we;
                wire signed [WEIGHT_W-1:0] pe_weight_data;
                wire pe_fault_we;
                wire pe_run_enable;

                assign pe_weight_we =
                    (weight_we && (weight_row == row) && (weight_col == col)) ||
                    (checksum_weight_we && (checksum_weight_row == row) &&
                     (col == CHECKSUM_COL));
                assign pe_weight_data =
                    (checksum_weight_we && (checksum_weight_row == row) &&
                     (col == CHECKSUM_COL)) ? checksum_weight_data : weight_data;
                assign pe_fault_we = fault_we && (fault_row == row) && (fault_col == col);
                // Once a bottom-row column has produced its result, stop that
                // PE from consuming the trailing zero wavefront.  This keeps
                // each output stable while later columns finish draining.
                assign pe_run_enable = running &&
                    !((row == ROWS-1) && (cycle_count > (ROWS + col)));

                systolic_pe #(
                    .DATA_W(DATA_W),
                    .WEIGHT_W(WEIGHT_W),
                    .ACC_W(ACC_W),
                    .ZERO_SKIP(ZERO_SKIP),
                    .CLOCK_GATED(CLOCK_GATED)
                ) pe (
                    .clk(clk),
                    .reset_n(reset_n),
                    .clear(start),
                    .run_enable(pe_run_enable),
                    .activation_in(activation_in[row][col]),
                    .activation_out(activation_out[row][col]),
                    .psum_in(psum_in[row][col]),
                    .psum_out(psum_out[row][col]),
                    .weight_we(pe_weight_we),
                    .weight_data(pe_weight_data),
                    .fault_we(pe_fault_we),
                    .fault_mode(fault_mode)
                );

            end
        end

        for (col = 0; col < PHYS_COLS; col = col + 1) begin : g_results
            assign result_data[col*ACC_W +: ACC_W] = psum_out[ROWS-1][col];
        end
    endgenerate

    always @(posedge clk) begin
        if (!reset_n) begin
            running <= 1'b0;
            valid <= 1'b0;
            test_mode_reg <= 1'b0;
            cycle_count <= {CYCLE_W{1'b0}};
        end else begin
            valid <= 1'b0;
            if (start) begin
                running <= 1'b1;
                test_mode_reg <= test_mode;
                cycle_count <= {CYCLE_W{1'b0}};
            end else if (running) begin
                if (cycle_count == WAVE_CYCLES-1) begin
                    running <= 1'b0;
                    valid <= 1'b1;
                end else begin
                    cycle_count <= cycle_count + 1'b1;
                end
            end
        end
    end

endmodule
