`timescale 1ns/1ps

// One weight-stationary processing element.  The PE keeps its weight local,
// forwards activations to the right, and forwards partial sums downward.
module systolic_pe #(
    parameter integer DATA_W       = 8,
    parameter integer WEIGHT_W     = 11,
    parameter integer ACC_W        = 24,
    parameter integer ZERO_SKIP    = 0,
    parameter integer CLOCK_GATED  = 0
) (
    input  wire                         clk,
    input  wire                         reset_n,
    input  wire                         clear,
    input  wire                         run_enable,
    input  wire                         bypass,
    input  wire signed [DATA_W-1:0]     activation_in,
    output reg  signed [DATA_W-1:0]     activation_out,
    input  wire signed [ACC_W-1:0]      psum_in,
    output reg  signed [ACC_W-1:0]      psum_out,
    input  wire                         weight_we,
    input  wire signed [WEIGHT_W-1:0]   weight_data,
    input  wire                         fault_we,
    input  wire [1:0]                   fault_mode
);

    reg signed [WEIGHT_W-1:0] weight_reg;
    reg signed [DATA_W-1:0] isolated_activation;
    reg [1:0] fault_mode_reg;

    wire signed [ACC_W-1:0] product_value;
    wire signed [ACC_W-1:0] accumulated_value;
    wire signed [ACC_W-1:0] faulted_value;

    function automatic signed [ACC_W-1:0] multiply_extend;
        input signed [DATA_W-1:0] lhs;
        input signed [WEIGHT_W-1:0] rhs;
        reg signed [DATA_W+WEIGHT_W-1:0] product;
        begin
            product = lhs * rhs;
            multiply_extend = {{(ACC_W-(DATA_W+WEIGHT_W)){product[DATA_W+WEIGHT_W-1]}}, product};
        end
    endfunction

    function automatic signed [ACC_W-1:0] inject_fault;
        input signed [ACC_W-1:0] value;
        input [1:0] mode;
        begin
            case (mode)
                2'b01: inject_fault = {ACC_W{1'b0}};
                2'b10: inject_fault = {{(ACC_W-1){1'b0}}, 1'b1};
                2'b11: inject_fault = value ^ {{(ACC_W-1){1'b0}}, 1'b1};
                default: inject_fault = value;
            endcase
        end
    endfunction

    assign product_value = multiply_extend(isolated_activation, weight_reg);
    assign accumulated_value = psum_in + product_value;
    assign faulted_value = inject_fault(accumulated_value, fault_mode_reg);

    always @(posedge clk) begin
        if (!reset_n) begin
            weight_reg         <= {WEIGHT_W{1'b0}};
            isolated_activation <= {DATA_W{1'b0}};
            activation_out     <= {DATA_W{1'b0}};
            psum_out           <= {ACC_W{1'b0}};
            fault_mode_reg     <= 2'b00;
        end else begin
            if (weight_we)
                weight_reg <= weight_data;
            if (fault_we)
                fault_mode_reg <= fault_mode;

            if (clear) begin
                isolated_activation <= {DATA_W{1'b0}};
                activation_out <= {DATA_W{1'b0}};
                psum_out <= {ACC_W{1'b0}};
            end else if (run_enable) begin
                // The activation path always advances one PE per cycle.
                activation_out <= activation_in;

                // A retired physical column remains in the wavefront so
                // downstream columns keep their timing, but its arithmetic
                // is bypassed.  The controller selects the spare output for
                // the retired logical channel.
                if (bypass) begin
                    isolated_activation <= {DATA_W{1'b0}};
                    psum_out <= psum_in;
                end else begin

                    // Operand isolation holds the multiplier's activation
                    // input at zero during an idle wavefront instead of
                    // repeatedly toggling the multiplier inputs.
                    if (ZERO_SKIP && (activation_in == {DATA_W{1'b0}}) &&
                        (fault_mode_reg == 2'b00)) begin
                        isolated_activation <= {DATA_W{1'b0}};
                    end else begin
                        isolated_activation <= activation_in;
                    end

                    // A clock-gated accumulator holds its state when the PE
                    // has no new work.  It does not write a replacement zero
                    // value.
                    if (!(CLOCK_GATED &&
                          (activation_in == {DATA_W{1'b0}}) &&
                          (isolated_activation == {DATA_W{1'b0}}) &&
                          (psum_in == psum_out) &&
                          (fault_mode_reg == 2'b00))) begin
                        psum_out <= faulted_value;
                    end
                end
            end
        end
    end

endmodule
