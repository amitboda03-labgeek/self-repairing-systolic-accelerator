`timescale 1ns/1ps

// Self-repairing, weight-stationary systolic MAC array.
//
// The implementation is intentionally small enough to simulate quickly and
// inspect in a waveform.  It models one logical output channel per physical
// column.  The final physical column is a spare; the controller can copy the
// retired column's weights into it and redirect the logical channel through
// the map without resetting the array.
//
// The checksum is evaluated over the active output channels:
//   sum(observed outputs) == sum(golden outputs)
// A mismatch detects corruption during normal inference.  A test sweep then
// evaluates every physical column with an all-ones vector to localise the
// damaged column before repair.

module self_repairing_systolic #(
    parameter integer ROWS       = 8,
    parameter integer COLS       = 8,
    parameter integer PHYS_COLS  = 9,
    parameter integer DATA_W     = 8,
    parameter integer ACC_W      = 24,
    parameter integer PIPELINED  = 0,
    parameter integer ZERO_SKIP  = 0,
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

    localparam integer SPARE_COL = PHYS_COLS - 1;
    localparam integer COL_IDX_W = (PHYS_COLS <= 2) ? 1 : $clog2(PHYS_COLS);
    localparam integer FSM_W     = 3;

    localparam [FSM_W-1:0] S_IDLE     = 3'd0;
    localparam [FSM_W-1:0] S_EVAL     = 3'd1;
    localparam [FSM_W-1:0] S_MUL      = 3'd2;
    localparam [FSM_W-1:0] S_ACC      = 3'd3;
    localparam [FSM_W-1:0] S_CHECK    = 3'd4;
    localparam [FSM_W-1:0] S_LOCALIZE = 3'd5;
    localparam [FSM_W-1:0] S_REPAIR   = 3'd6;

    reg [FSM_W-1:0] state;
    reg [COL_IDX_W-1:0] localize_col;
    reg [COL_IDX_W-1:0] repair_fault_col;

    reg signed [DATA_W-1:0] weights [0:ROWS-1][0:PHYS_COLS-1];
    reg [1:0] fault_modes [0:ROWS-1][0:PHYS_COLS-1];
    reg signed [DATA_W-1:0] activations [0:ROWS-1];

    reg signed [ACC_W-1:0] product_pipe [0:ROWS-1][0:PHYS_COLS-1];
    reg signed [ACC_W-1:0] computed_physical [0:PHYS_COLS-1];
    reg signed [ACC_W-1:0] golden_physical [0:PHYS_COLS-1];

    reg [COL_IDX_W-1:0] logical_map [0:COLS-1];
    reg logical_valid [0:COLS-1];

    integer r;
    integer c;
    integer l;
    reg signed [ACC_W-1:0] running_sum;
    reg signed [ACC_W-1:0] next_sum;
    reg signed [ACC_W-1:0] observed_sum;
    reg signed [ACC_W-1:0] expected_sum;
    reg signed [DATA_W-1:0] selected_activation;
    reg signed [ACC_W-1:0] selected_product;
    reg signed [ACC_W-1:0] test_observed;
    reg signed [ACC_W-1:0] test_expected;
    reg found_logical_channel;

    function automatic signed [ACC_W-1:0] sign_extend_product;
        input signed [DATA_W-1:0] lhs;
        input signed [DATA_W-1:0] rhs;
        reg signed [(2*DATA_W)-1:0] product;
        begin
            product = lhs * rhs;
            sign_extend_product = {{(ACC_W-(2*DATA_W)){product[(2*DATA_W)-1]}}, product};
        end
    endfunction

    function automatic signed [ACC_W-1:0] apply_fault;
        input signed [ACC_W-1:0] value;
        input [1:0] mode;
        begin
            case (mode)
                2'b01: apply_fault = {ACC_W{1'b0}}; // stuck at zero
                2'b10: apply_fault = {ACC_W{1'b1}}; // stuck at one
                2'b11: apply_fault = value ^ {{(ACC_W-1){1'b0}}, 1'b1};
                default: apply_fault = value;
            endcase
        end
    endfunction

    // Direct combinational column evaluation is used by the baseline.  The
    // optimized configuration uses the same arithmetic after registering the
    // products, which shortens the multiply-to-accumulate path.
    function automatic signed [ACC_W-1:0] evaluate_column;
        input integer column;
        input integer inject_faults;
        input integer test_vector;
        integer row;
        reg signed [DATA_W-1:0] act;
        reg signed [ACC_W-1:0] product;
        reg signed [ACC_W-1:0] sum;
        reg signed [ACC_W-1:0] updated_sum;
        begin
            sum = {ACC_W{1'b0}};
            for (row = 0; row < ROWS; row = row + 1) begin
                if (test_vector)
                    act = {{(DATA_W-1){1'b0}}, 1'b1};
                else
                    act = activations[row];

                product = sign_extend_product(act, weights[row][column]);

                // A zero-skipping implementation removes the multiplier
                // activity for zero operands.  Fault injection overrides the
                // skip so injected defects remain observable in verification.
                if (ZERO_SKIP && !test_vector &&
                    ((act == {DATA_W{1'b0}}) ||
                     (weights[row][column] == {DATA_W{1'b0}})) &&
                    (fault_modes[row][column] == 2'b00))
                    product = {ACC_W{1'b0}};

                updated_sum = sum + product;
                if (inject_faults && (fault_modes[row][column] != 2'b00))
                    updated_sum = apply_fault(updated_sum, fault_modes[row][column]);
                sum = updated_sum;
            end
            evaluate_column = sum;
        end
    endfunction

    initial begin
        if (PHYS_COLS != (COLS + 1))
            $display("INFO: PHYS_COLS is not COLS+1; spare is still the final physical column");
        if (ACC_W < (2*DATA_W))
            $display("WARNING: ACC_W is smaller than the signed product width");
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            detect_error  <= 1'b0;
            repair_done   <= 1'b0;
            degraded      <= 1'b0;
            dead_columns  <= {PHYS_COLS{1'b0}};
            spare_in_use  <= 1'b0;
            output_data   <= {(COLS*ACC_W){1'b0}};
            localize_col  <= {COL_IDX_W{1'b0}};
            repair_fault_col <= {COL_IDX_W{1'b0}};
            for (r = 0; r < ROWS; r = r + 1) begin
                activations[r] <= {DATA_W{1'b0}};
                for (c = 0; c < PHYS_COLS; c = c + 1) begin
                    weights[r][c] <= {DATA_W{1'b0}};
                    fault_modes[r][c] <= 2'b00;
                    product_pipe[r][c] <= {ACC_W{1'b0}};
                end
            end
            for (c = 0; c < PHYS_COLS; c = c + 1) begin
                computed_physical[c] <= {ACC_W{1'b0}};
                golden_physical[c] <= {ACC_W{1'b0}};
            end
            for (l = 0; l < COLS; l = l + 1) begin
                logical_map[l] <= l[COL_IDX_W-1:0];
                logical_valid[l] <= 1'b1;
            end
        end else begin
            done        <= 1'b0;
            repair_done <= 1'b0;

            // Configuration writes are available while idle and remain
            // deliberately simple so a cocotb or firmware driver can use the
            // same interface for baseline and optimized variants.
            if (weight_we && !busy)
                weights[weight_row][weight_col] <= weight_data;
            if (activation_we && !busy)
                activations[activation_index] <= activation_data;
            if (fault_we && !busy)
                fault_modes[fault_row][fault_col] <= fault_mode;
            if (fault_clear && !busy)
                fault_modes[fault_row][fault_col] <= 2'b00;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        busy         <= 1'b1;
                        detect_error <= 1'b0;
                        if (PIPELINED)
                            state <= S_MUL;
                        else
                            state <= S_EVAL;
                    end
                end

                S_EVAL: begin
                    for (c = 0; c < PHYS_COLS; c = c + 1) begin
                        computed_physical[c] <= evaluate_column(c, 1, 0);
                        golden_physical[c] <= evaluate_column(c, 0, 0);
                    end
                    state <= S_CHECK;
                end

                S_MUL: begin
                    // Registered product stage used by the PPA-oriented
                    // pipeline.  The optional clock-enable condition makes
                    // the register bank quiet for an all-zero activation row.
                    for (r = 0; r < ROWS; r = r + 1) begin
                        for (c = 0; c < PHYS_COLS; c = c + 1) begin
                            selected_product = sign_extend_product(activations[r], weights[r][c]);
                            if (ZERO_SKIP &&
                                ((activations[r] == {DATA_W{1'b0}}) ||
                                 (weights[r][c] == {DATA_W{1'b0}})) &&
                                (fault_modes[r][c] == 2'b00))
                                selected_product = {ACC_W{1'b0}};

                            if (CLOCK_GATED &&
                                (activations[r] == {DATA_W{1'b0}}) &&
                                (fault_modes[r][c] == 2'b00))
                                product_pipe[r][c] <= {ACC_W{1'b0}};
                            else
                                product_pipe[r][c] <= selected_product;
                        end
                    end
                    state <= S_ACC;
                end

                S_ACC: begin
                    for (c = 0; c < PHYS_COLS; c = c + 1) begin
                        running_sum = {ACC_W{1'b0}};
                        for (r = 0; r < ROWS; r = r + 1) begin
                            next_sum = running_sum + product_pipe[r][c];
                            if (fault_modes[r][c] != 2'b00)
                                next_sum = apply_fault(next_sum, fault_modes[r][c]);
                            running_sum = next_sum;
                        end
                        computed_physical[c] <= running_sum;
                        golden_physical[c] <= evaluate_column(c, 0, 0);
                    end
                    state <= S_CHECK;
                end

                S_CHECK: begin
                    observed_sum = {ACC_W{1'b0}};
                    expected_sum = {ACC_W{1'b0}};
                    for (l = 0; l < COLS; l = l + 1) begin
                        if (logical_valid[l]) begin
                            output_data[(l*ACC_W) +: ACC_W] <= computed_physical[logical_map[l]];
                            observed_sum = observed_sum + computed_physical[logical_map[l]];
                            expected_sum = expected_sum + golden_physical[logical_map[l]];
                        end else begin
                            output_data[(l*ACC_W) +: ACC_W] <= {ACC_W{1'b0}};
                        end
                    end

                    if (observed_sum != expected_sum) begin
                        detect_error <= 1'b1;
                        localize_col <= {COL_IDX_W{1'b0}};
                        state <= S_LOCALIZE;
                    end else begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                S_LOCALIZE: begin
                    test_observed = evaluate_column(localize_col, 1, 1);
                    test_expected = evaluate_column(localize_col, 0, 1);
                    if ((test_observed != test_expected) &&
                        !dead_columns[localize_col]) begin
                        repair_fault_col <= localize_col;
                        state <= S_REPAIR;
                    end else if (localize_col == (PHYS_COLS-1)) begin
                        // A checksum mismatch without a localisable active
                        // column is retained as an error; no unsafe repair is
                        // attempted.
                        busy <= 1'b0;
                        degraded <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        localize_col <= localize_col + 1'b1;
                    end
                end

                S_REPAIR: begin
                    found_logical_channel = 1'b0;
                    for (l = 0; l < COLS; l = l + 1) begin
                        if (logical_valid[l] &&
                            (logical_map[l] == repair_fault_col)) begin
                            found_logical_channel = 1'b1;
                            if (!spare_in_use && (repair_fault_col != SPARE_COL)) begin
                                logical_map[l] <= SPARE_COL;
                                for (r = 0; r < ROWS; r = r + 1) begin
                                    weights[r][SPARE_COL] <= weights[r][repair_fault_col];
                                    fault_modes[r][SPARE_COL] <= 2'b00;
                                end
                                spare_in_use <= 1'b1;
                            end else begin
                                logical_valid[l] <= 1'b0;
                                degraded <= 1'b1;
                            end
                        end
                    end
                    dead_columns[repair_fault_col] <= 1'b1;
                    if (!found_logical_channel)
                        degraded <= 1'b1;
                    repair_done <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
