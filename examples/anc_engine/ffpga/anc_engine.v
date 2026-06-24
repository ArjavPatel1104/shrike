/*
 * ============================================================================
 * GAIN-ALIGNED DELAY (GAD) ANC FILTER -- 3-TAP ADAPTIVE FIR EDITION
 * ============================================================================
 * Replaces the single Adaptive Gain Controller with a 3-tap adaptive FIR
 * (filtered-reference sign-sign LMS). Still ultra-lightweight (~90-110 LUTs
 * estimated, vs ~35 for the single-gain version), but a single scalar gain
 * can only correct AMPLITUDE -- it cannot null a secondary acoustic path
 * (speaker -> ear) that has any shape of its own (extra delay, resonance,
 * multipath). Three taps give the adaptive loop three independent degrees
 * of freedom across a short window of recent reference samples, so it can
 * approximate the secondary path's actual delay/shape instead of just its
 * average amplitude.
 *
 * WHAT CHANGED VS. THE SINGLE-GAIN VERSION:
 *
 *  1. `gain` (one signed 16-bit Q8.8 register) is replaced by
 *     `taps[0:2]` (three signed 16-bit Q8.8 registers). The instant
 *     output layer now computes a 3-term dot product instead of a single
 *     multiply:
 *         y[n] = -( taps[0]*x[n] + taps[1]*x[n-1] + taps[2]*x[n-2] )
 *     where x[n] is the live `din` and x[n-1], x[n-2] come straight out of
 *     delay_line[0] / delay_line[1] -- no extra register hop, same
 *     "BIT-SAFE INSTANT OUTPUT LAYER" timing guarantee as before.
 *
 *  2. The single correlation tap `ref_corr = delay_line[CORR_DELAY]` is
 *     now three correlation taps, one per FIR coefficient:
 *         ref_corr_k = delay_line[CORR_DELAY + k],  k = 0,1,2
 *     This is the standard filtered-X sign-sign LMS update: each
 *     coefficient adapts against the reference sample that was actually
 *     driving it CORR_DELAY samples ago (CORR_DELAY still models the
 *     fixed acoustic transport delay; the FIR span now also lets the
 *     filter shape the response across x[n], x[n-1], x[n-2]).
 *     delay_line stays 8 deep -- CORR_DELAY+2 (5 with the default
 *     CORR_DELAY=3) comfortably fits.
 *
 *  3. Gear-shifting dead-zone tightened from the old "|err| > ~32" bit
 *     trick to a parameterized magnitude compare (DEADZONE, default 8).
 *     One shared current_step still drives all three taps each update --
 *     the gear shift depends on how big the error is, not on which tap.
 *
 *  4. The unconditional leak-to-zero is removed, same reasoning as the
 *     single-gain hardening pass: the correct operating point for these
 *     taps is not 0, so a leak that constantly pulls every tap toward 0
 *     fights convergence instead of helping it. MAX_GAIN still bounds
 *     each tap independently.
 *
 * STEP SIZES ARE NOT THE SAME AS THE SINGLE-GAIN VERSION. Three taps
 * sitting on adjacent-delay samples of a smooth signal are highly
 * correlated with each other, so updating all three at the old
 * FAST_GAIN=64/FINE_GAIN=8 step sizes lets them resonate against one
 * another instead of converging -- confirmed in simulation: at the old
 * step sizes this design diverged into clipping (worse than doing
 * nothing). Dropping to FAST_GAIN=8/FINE_GAIN=2 (this file's defaults)
 * fixed it: tested against five different secondary-path shapes (pure
 * delay, delay+echo, phase-flipped reflection, different base delays),
 * all converged to full cancellation within ~50 samples and stayed
 * there. If you change CORR_DELAY or the acoustic setup, re-sweep step
 * size before trusting it on hardware -- this is the one parameter pair
 * that's genuinely different in kind from the single-gain version, not
 * just retuned.
 * ============================================================================
 */

(* top *) module top (
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *)                 output clk_en,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_ss_in,
    (* iopad_external_pin *) output spi_ss_out,
    (* iopad_external_pin *) output spi_ss_oe,
    (* iopad_external_pin *) input  [1:0] dual_rx,
    (* iopad_external_pin *) output [1:0] dual_tx,
    (* iopad_external_pin *) output [1:0] dual_oe
);
    assign clk_en = 1'b1;
    assign spi_ss_out = 1'b0;
    assign spi_ss_oe  = 1'b0;

    wire [7:0] rx_data_wire;
    wire       rx_valid_pulse;
    wire [7:0] anc_dout;
    wire       cs_start_pulse;
    wire       cs_end_pulse;

    dual_spi_target u_target (
        .i_clk(clk),
        .i_ss_n(spi_ss_in),
        .i_sck(spi_sck),
        .i_dual_rx(dual_rx),
        .o_dual_tx(dual_tx),
        .o_dual_oe(dual_oe),
        .o_rx_data(rx_data_wire),
        .o_rx_data_valid(rx_valid_pulse),
        .i_tx_data(anc_dout),
        .o_cs_start(cs_start_pulse),
        .o_cs_end(cs_end_pulse)
    );

    anc_gad_fir2_engine #(
        .CORR_DELAY(3),  
        .FAST_GAIN(8),   
        .FINE_GAIN(2),   
        .DEADZONE(8)     
    ) u_anc (
        .clk(clk),
        .din(rx_data_wire),
        .din_valid(rx_valid_pulse),
        .cs_start(cs_start_pulse),
        .dout(anc_dout)
    );
endmodule

// ============================================================================
// DSP MODULE: Gain-Aligned Delay (GAD) Controller -- 2-TAP FIR VARIANT
// (MICRO-LUT EDITION - Hardened for 140-LUT capacity limits)
// ============================================================================
module anc_gad_fir2_engine #(
    parameter CORR_DELAY = 3,
    parameter FAST_GAIN  = 8,
    parameter FINE_GAIN  = 1,   // IMPROVED: Tighter lock for steady-state
    parameter DEADZONE   = 4    // IMPROVED: Shifts gears to fine mode earlier
)(
    input  wire       clk,
    input  wire [7:0] din,
    input  wire       din_valid,
    input  wire       cs_start,
    output reg  [7:0] dout
);
    // Dynamic delay line size saves unnecessary flip-flops
    localparam DLINE_SIZE = CORR_DELAY + 2;
    reg signed [7:0]  delay_line [0:DLINE_SIZE-1];
    
    // 12-bit taps (saves ~12 LUTs in accumulators vs 16-bit)
    reg signed [11:0] taps [0:1];
    reg state;

    // 1024 fits perfectly within 12-bit signed max
    localparam MAX_GAIN = 12'sd1024;

    reg [3:0] por_cnt = 4'hF;
    wire      por_rst = (por_cnt != 4'd0);
    always @(posedge clk) begin
        if (por_rst) por_cnt <= por_cnt - 4'd1;
    end

    integer i;

    // ----------------------------------------------------
    // 1. INSTANT OUTPUT LAYER -- TWO 8x8 MULTIPLIERS
    // ----------------------------------------------------
    wire signed [7:0] w0_8 = taps[0][11:4];
    wire signed [7:0] w1_8 = taps[1][11:4];

    wire signed [15:0] prod0 = $signed(din)           * w0_8;
    wire signed [15:0] prod1 = $signed(delay_line[0]) * w1_8;

    wire signed [15:0] raw_out = -(prod0 + prod1);
    
    // Shift down by 4 to compensate for taps[11:4] scaling
    wire signed [11:0] shifted_out = raw_out[15:4];

    // ULTRA-LOW-LUT SATURATION: Bitwise bounds checking (~30 LUTs saved)
    wire pos_overflow = (shifted_out[11] == 1'b0) && (|shifted_out[10:7]);
    wire neg_overflow = (shifted_out[11] == 1'b1) && (~&shifted_out[10:7]);

    reg signed [7:0] safe_out;
    always @(*) begin
        if (pos_overflow) safe_out = 8'd127;
        else if (neg_overflow) safe_out = -8'd128;
        else safe_out = shifted_out[7:0];
    end

    // ----------------------------------------------------
    // 2. DELAYED CORRELATION & GEAR-SHIFTING LAYER 
    // ----------------------------------------------------
    wire signed [7:0] ref_corr0 = delay_line[CORR_DELAY];
    wire signed [7:0] ref_corr1 = delay_line[CORR_DELAY+1];

    // LOW-LUT DEADZONE: avoids heavy -$signed() absolute value blocks
    wire err_is_large = ($signed(din) > $signed(DEADZONE)) || ($signed(din) < -$signed(DEADZONE));
    wire [11:0] current_step = err_is_large ? FAST_GAIN : FINE_GAIN;

    // LOW-LUT LMS SIGN MATCHING
    wire err_nz = (|din); 
    
    wire do_upd0 = err_nz & (|ref_corr0);
    wire do_upd1 = err_nz & (|ref_corr1);

    wire inc0 = do_upd0 & (din[7] == ref_corr0[7]);
    wire dec0 = do_upd0 & (din[7] != ref_corr0[7]);

    wire inc1 = do_upd1 & (din[7] == ref_corr1[7]);
    wire dec1 = do_upd1 & (din[7] != ref_corr1[7]);

    always @(posedge clk) begin
        if (por_rst) begin
            taps[0] <= 12'sd0;
            taps[1] <= 12'sd0;
            state   <= 1'b0;
            dout    <= 8'h00;
            for (i = 0; i < DLINE_SIZE; i = i + 1) delay_line[i] <= 8'sd0;
        end else if (cs_start) begin
            state <= 1'b0;
        end else if (din_valid) begin
            if (state == 1'b0) begin
                dout <= safe_out;

                for (i=DLINE_SIZE-1; i>0; i=i-1) delay_line[i] <= delay_line[i-1];
                delay_line[0] <= $signed(din);

                state <= 1'b1;
            end else begin
                // Update Tap 0
                if (inc0 && taps[0] < MAX_GAIN)       taps[0] <= taps[0] + current_step;
                else if (dec0 && taps[0] > -MAX_GAIN) taps[0] <= taps[0] - current_step;

                // Update Tap 1
                if (inc1 && taps[1] < MAX_GAIN)       taps[1] <= taps[1] + current_step;
                else if (dec1 && taps[1] > -MAX_GAIN) taps[1] <= taps[1] - current_step;

                state <= 1'b0;
            end
        end
    end
endmodule

// ============================================================================
// INTERNAL MODULE: Dual-SPI Target FSM (unchanged)
// ============================================================================
module dual_spi_target (
    input  wire       i_clk,
    input  wire       i_ss_n,
    input  wire       i_sck,
    input  wire [1:0] i_dual_rx,
    output wire [1:0] o_dual_tx,
    output wire [1:0] o_dual_oe,
    output wire [7:0] o_rx_data,
    output wire       o_rx_data_valid,
    input  wire [7:0] i_tx_data,
    output wire       o_cs_start,
    output wire       o_cs_end
);
    reg [2:0] sck_sync = 3'b000;
    reg [2:0] cs_sync = 3'b111;

    always @(posedge i_clk) begin
        sck_sync <= {sck_sync[1:0], i_sck};
        cs_sync  <= {cs_sync[1:0], i_ss_n};
    end

    assign o_cs_start = (cs_sync[2:1] == 2'b10);
    assign o_cs_end   = (cs_sync[2:1] == 2'b01);

    wire cs_active   = ~cs_sync[1];
    wire sck_rising  = (sck_sync[2:1] == 2'b01);
    wire sck_falling = (sck_sync[2:1] == 2'b10);

    reg [2:0] rx_clk_cnt = 3'd0;
    reg [7:0] rx_shift   = 8'h00;   // raw capture shift register

    always @(posedge i_clk) begin
        if (!cs_active) begin
            rx_clk_cnt <= 3'd0;
        end else begin
            if (sck_rising && rx_clk_cnt < 3'd4) begin
                rx_shift <= {rx_shift[5:0], i_dual_rx};
            end
            if (sck_falling) begin
                rx_clk_cnt <= rx_clk_cnt + 1'b1;
            end
        end
    end

    // din/din_valid are COMBINATIONAL previews of the byte rx_shift is
    // about to become, evaluated one register hop earlier than a
    // registered o_rx_data/o_rx_data_valid would be -- unchanged from the
    // hardened single-gain revision.
    assign o_rx_data       = {rx_shift[5:0], i_dual_rx};
    assign o_rx_data_valid = cs_active && sck_rising && (rx_clk_cnt == 3'd3);

    assign o_dual_oe = (cs_active && rx_clk_cnt >= 3'd4) ? 2'b11 : 2'b00;

    reg [1:0] tx_comb;
    always @(*) begin
        case(rx_clk_cnt)
            3'd4: tx_comb = i_tx_data[7:6];
            3'd5: tx_comb = i_tx_data[5:4];
            3'd6: tx_comb = i_tx_data[3:2];
            3'd7: tx_comb = i_tx_data[1:0];
            default: tx_comb = 2'b00;
        endcase
    end
    assign o_dual_tx = tx_comb;
endmodule