`timescale 1ns/1ps

// Self-repairing weight-stationary systolic neural accelerator.
//
// The data path is a real PE array: weights stay in the PEs, activations move
// right, and partial sums move down.  Column COLS is an ABFT checksum column
// whose row weights are the sums of the real output-column weights.  The last
// physical column is a spare used to replace one failed output column.
module self_repairing_systolic #(
    parameter integer ROWS        = 8,
    parameter integer COLS        = 8,
    parameter integer PHYS_COLS   = COLS + 2,
    parameter integer DATA_W      = 8,
    parameter integer WEIGHT_W    = DATA_W + $clog2(COLS),
    parameter integer ACC_W       = 24,
    parameter integer ZERO_SKIP   = 0,
    parameter integer CLOCK_GATED = 0
) (
    input  wire                         clk,
    input  wire                         reset_n,
    input  wire                         start,

    input  wire                         weight_we,
    input  wire [$clog2(ROWS)-1:0]      weight_row,
    input  wire [$clog2(PHYS_COLS)-1:0] weight_col,
    input  wire signed [DATA_W-1:0]     weight_data,

    input  wire                         fault_we,
    input  wire                         fault_clear,
    input  wire [$clog2(ROWS)-1:0]      fault_row,
    input  wire [$clog2(PHYS_COLS)-1:0] fault_col,
    input  wire [1:0]                   fault_mode,

    input  wire                         activation_we,
    input  wire [$clog2(ROWS)-1:0]      activation_index,
    input  wire signed [DATA_W-1:0]     activation_data,

    output reg                          busy,
    output reg                          done,
    output reg                          detect_error,
    output reg                          repair_done,
    output reg                          degraded,
    output reg [PHYS_COLS-1:0]          dead_columns,
    output reg                          spare_in_use,
    output reg signed [COLS*ACC_W-1:0]  output_data
);

    localparam integer CHECKSUM_COL = COLS;
    localparam integer SPARE_COL    = COLS + 1;
    localparam integer ROW_IDX_W    = (ROWS <= 2) ? 1 : $clog2(ROWS);
    localparam integer COL_IDX_W    = (PHYS_COLS <= 2) ? 1 : $clog2(PHYS_COLS);
    localparam integer STATE_W      = 3;

    localparam [STATE_W-1:0] S_IDLE        = 3'd0;
    localparam [STATE_W-1:0] S_RUN_START   = 3'd1;
    localparam [STATE_W-1:0] S_RUN_WAIT    = 3'd2;
    localparam [STATE_W-1:0] S_TEST_START  = 3'd3;
    localparam [STATE_W-1:0] S_TEST_WAIT   = 3'd4;
    localparam [STATE_W-1:0] S_REPAIR_COPY = 3'd5;

    reg [STATE_W-1:0] state;
    reg [ROW_IDX_W-1:0] repair_row;
    reg [COL_IDX_W-1:0] repair_fault_col;

    reg signed [WEIGHT_W-1:0] weights [0:ROWS-1][0:PHYS_COLS-1];
    reg signed [ACC_W-1:0] column_signature [0:PHYS_COLS-1];
    reg signed [DATA_W-1:0] activations [0:ROWS-1];
    reg [COL_IDX_W-1:0] logical_map [0:COLS-1];
    reg logical_valid [0:COLS-1];

    wire signed [ROWS*DATA_W-1:0] activation_vector;
    wire signed [PHYS_COLS*ACC_W-1:0] array_result;
    wire array_start;
    wire array_test_mode;
    wire [PHYS_COLS-1:0] array_bypass_columns;
    wire array_running;
    wire array_valid;

    wire array_weight_we;
    wire [ROW_IDX_W-1:0] array_weight_row;
    wire [COL_IDX_W-1:0] array_weight_col;
    wire signed [WEIGHT_W-1:0] array_weight_data;
    wire array_checksum_weight_we;
    wire [ROW_IDX_W-1:0] array_checksum_weight_row;
    wire signed [WEIGHT_W-1:0] array_checksum_weight_data;
    wire array_fault_we;
    wire [ROW_IDX_W-1:0] array_fault_row;
    wire [COL_IDX_W-1:0] array_fault_col;
    wire [1:0] array_fault_mode;

    reg signed [WEIGHT_W-1:0] incoming_weight;
    reg signed [WEIGHT_W-1:0] old_weight;
    reg signed [WEIGHT_W-1:0] weight_delta;
    reg signed [ACC_W-1:0] observed_sum;
    reg signed [ACC_W-1:0] checksum_value;
    reg signed [ACC_W-1:0] candidate_value;
    integer r;
    integer c;
    integer l;
    integer logical_channel;
    integer fault_candidate;
    reg found_logical_channel;

    function automatic signed [WEIGHT_W-1:0] extend_input_weight;
        input signed [DATA_W-1:0] value;
        begin
            extend_input_weight = {{(WEIGHT_W-DATA_W){value[DATA_W-1]}}, value};
        end
    endfunction

    function automatic signed [WEIGHT_W-1:0] checksum_weight_for_row;
        input integer row_index;
        input integer override_column;
        input signed [WEIGHT_W-1:0] override_value;
        integer column_index;
        reg signed [WEIGHT_W-1:0] sum;
        begin
            sum = {WEIGHT_W{1'b0}};
            for (column_index = 0; column_index < COLS; column_index = column_index + 1) begin
                if (column_index == override_column)
                    sum = sum + override_value;
                else
                    sum = sum + weights[row_index][column_index];
            end
            checksum_weight_for_row = sum;
        end
    endfunction

    generate
        genvar activation_row;
        for (activation_row = 0; activation_row < ROWS; activation_row = activation_row + 1) begin : g_activation_vector
            assign activation_vector[activation_row*DATA_W +: DATA_W] = activations[activation_row];
        end
    endgenerate

    assign array_start = (state == S_RUN_START) || (state == S_TEST_START);
    assign array_test_mode = (state == S_TEST_START) || (state == S_TEST_WAIT);
    assign array_bypass_columns = dead_columns;

    assign array_weight_we =
        (state == S_REPAIR_COPY) ||
        ((state == S_IDLE) && !busy && weight_we && (weight_col != CHECKSUM_COL));
    assign array_weight_row = (state == S_REPAIR_COPY) ? repair_row : weight_row;
    assign array_weight_col = (state == S_REPAIR_COPY) ? SPARE_COL : weight_col;
    assign array_weight_data = (state == S_REPAIR_COPY) ?
        weights[repair_row][repair_fault_col] : extend_input_weight(weight_data);

    assign array_checksum_weight_we =
        (state == S_IDLE) && !busy && weight_we && (weight_col < COLS);
    assign array_checksum_weight_row = weight_row;
    assign array_checksum_weight_data = checksum_weight_for_row(
        weight_row, weight_col, extend_input_weight(weight_data));

    assign array_fault_we =
        (state == S_REPAIR_COPY) ||
        ((state == S_IDLE) && !busy && (fault_we || fault_clear));
    assign array_fault_row = (state == S_REPAIR_COPY) ? repair_row : fault_row;
    assign array_fault_col = (state == S_REPAIR_COPY) ? SPARE_COL : fault_col;
    assign array_fault_mode = (state == S_REPAIR_COPY) ? 2'b00 :
                              (fault_clear ? 2'b00 : fault_mode);

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .PHYS_COLS(PHYS_COLS),
        .DATA_W(DATA_W),
        .WEIGHT_W(WEIGHT_W),
        .ACC_W(ACC_W),
        .ZERO_SKIP(ZERO_SKIP),
        .CLOCK_GATED(CLOCK_GATED)
    ) array (
        .clk(clk),
        .reset_n(reset_n),
        .start(array_start),
        .test_mode(array_test_mode),
        .bypass_columns(array_bypass_columns),
        .activation_vector(activation_vector),
        .weight_we(array_weight_we),
        .weight_row(array_weight_row),
        .weight_col(array_weight_col),
        .weight_data(array_weight_data),
        .checksum_weight_we(array_checksum_weight_we),
        .checksum_weight_row(array_checksum_weight_row),
        .checksum_weight_data(array_checksum_weight_data),
        .fault_we(array_fault_we),
        .fault_row(array_fault_row),
        .fault_col(array_fault_col),
        .fault_mode(array_fault_mode),
        .running(array_running),
        .valid(array_valid),
        .result_data(array_result)
    );

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            detect_error <= 1'b0;
            repair_done <= 1'b0;
            degraded <= 1'b0;
            dead_columns <= {PHYS_COLS{1'b0}};
            spare_in_use <= 1'b0;
            output_data <= {(COLS*ACC_W){1'b0}};
            repair_row <= {ROW_IDX_W{1'b0}};
            repair_fault_col <= {COL_IDX_W{1'b0}};

            for (r = 0; r < ROWS; r = r + 1) begin
                activations[r] <= {DATA_W{1'b0}};
                for (c = 0; c < PHYS_COLS; c = c + 1)
                    weights[r][c] <= {WEIGHT_W{1'b0}};
            end
            for (c = 0; c < PHYS_COLS; c = c + 1)
                column_signature[c] <= {ACC_W{1'b0}};
            for (l = 0; l < COLS; l = l + 1) begin
                logical_map[l] <= l;
                logical_valid[l] <= 1'b1;
            end
        end else begin
            done <= 1'b0;
            repair_done <= 1'b0;

            if ((state == S_IDLE) && !busy) begin
                if (activation_we)
                    activations[activation_index] <= activation_data;

                if (weight_we && (weight_col < PHYS_COLS) && (weight_col != CHECKSUM_COL)) begin
                    incoming_weight = extend_input_weight(weight_data);
                    old_weight = weights[weight_row][weight_col];
                    weight_delta = incoming_weight - old_weight;
                    weights[weight_row][weight_col] <= incoming_weight;
                    column_signature[weight_col] <= column_signature[weight_col] + weight_delta;

                    if (weight_col < COLS) begin
                        weights[weight_row][CHECKSUM_COL] <=
                            checksum_weight_for_row(weight_row, weight_col, incoming_weight);
                        column_signature[CHECKSUM_COL] <=
                            column_signature[CHECKSUM_COL] + weight_delta;
                    end
                end

                if (start) begin
                    busy <= 1'b1;
                    detect_error <= 1'b0;
                    state <= S_RUN_START;
                end
            end

            case (state)
                S_IDLE: begin
                    // Configuration writes and a new start request are
                    // handled above while the controller is idle.
                end

                S_RUN_START: begin
                    state <= S_RUN_WAIT;
                end

                S_RUN_WAIT: begin
                    if (array_valid) begin
                        observed_sum = {ACC_W{1'b0}};
                        for (l = 0; l < COLS; l = l + 1) begin
                            if (logical_valid[l]) begin
                                candidate_value = $signed(array_result[logical_map[l]*ACC_W +: ACC_W]);
                                output_data[l*ACC_W +: ACC_W] <= candidate_value;
                                observed_sum = observed_sum + candidate_value;
                            end else begin
                                output_data[l*ACC_W +: ACC_W] <= {ACC_W{1'b0}};
                            end
                        end
                        checksum_value = $signed(array_result[CHECKSUM_COL*ACC_W +: ACC_W]);

                        if (!degraded && (observed_sum != checksum_value)) begin
                            detect_error <= 1'b1;
                            state <= S_TEST_START;
                        end else begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                end

                S_TEST_START: begin
                    state <= S_TEST_WAIT;
                end

                S_TEST_WAIT: begin
                    if (array_valid) begin
                        fault_candidate = -1;
                        for (c = 0; c < PHYS_COLS; c = c + 1) begin
                            candidate_value = $signed(array_result[c*ACC_W +: ACC_W]);
                            if (!dead_columns[c] && (candidate_value != column_signature[c]) &&
                                (fault_candidate < 0))
                                fault_candidate = c;
                        end

                        if (fault_candidate < 0) begin
                            degraded <= 1'b1;
                            busy <= 1'b0;
                            repair_done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            dead_columns[fault_candidate] <= 1'b1;
                            found_logical_channel = 1'b0;
                            logical_channel = -1;
                            for (l = 0; l < COLS; l = l + 1) begin
                                if (logical_valid[l] && (logical_map[l] == fault_candidate) &&
                                    !found_logical_channel) begin
                                    found_logical_channel = 1'b1;
                                    logical_channel = l;
                                end
                            end

                            if (found_logical_channel && (fault_candidate < COLS) &&
                                !spare_in_use && !dead_columns[SPARE_COL]) begin
                                repair_fault_col <= fault_candidate;
                                repair_row <= {ROW_IDX_W{1'b0}};
                                logical_map[logical_channel] <= SPARE_COL;
                                spare_in_use <= 1'b1;
                                column_signature[SPARE_COL] <= column_signature[fault_candidate];
                                state <= S_REPAIR_COPY;
                            end else begin
                                if (found_logical_channel)
                                    logical_valid[logical_channel] <= 1'b0;
                                degraded <= 1'b1;
                                busy <= 1'b0;
                                repair_done <= 1'b1;
                                state <= S_IDLE;
                            end
                        end
                    end
                end

                S_REPAIR_COPY: begin
                    weights[repair_row][SPARE_COL] <= weights[repair_row][repair_fault_col];
                    if (repair_row == ROWS-1) begin
                        busy <= 1'b0;
                        repair_done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        repair_row <= repair_row + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
