/*
 * project.v - Echoes Affect Core (tt_um_eci_affect_core)
 * Evil Company Ink. LLC
 *
 * Hardware port of CIPHER's EchoesEmotionalState (Emotion.py):
 * one mood out of 12, one 8-bit intensity (round(x * 255) of the
 * Python float), the same priority rules, plus the new rules for
 * curious, amused, concerned and melancholy, and time-based cooling.
 *
 * Pins
 *   ui_in[0]  SPI_SCK        uo_out[0]   SPI_MISO
 *   ui_in[1]  SPI_MOSI       uo_out[1]   PWM_INTENSITY
 *   ui_in[2]  SPI_CS_N       uo_out[5:2] MOOD[3:0]
 *   ui_in[3]  TEST_MODE      uo_out[6]   MOOD_IRQ
 *   ui_in[4]  REFLEX_LOUD    uo_out[7]   HEARTBEAT
 *   ui_in[5]  REFLEX_TOUCH   uio[7:0]    DEBUG bus (test mode only)
 *   ui_in[6]  REFLEX_MOTION
 *   ui_in[7]  REFLEX_TILT
 */
`default_nettype none

module tt_um_eci_affect_core (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    // Mood codes follow the order of the MOODS dict in Emotion.py.
    localparam [3:0] M_NEUTRAL    = 4'h0,
                     M_ENGAGED    = 4'h1,
                     M_CURIOUS    = 4'h2,
                     M_AMUSED     = 4'h3,
                     M_IRRITATED  = 4'h4,
                     M_FRUSTRATED = 4'h5,
                     M_RESIGNED   = 4'h6,
                     M_CONCERNED  = 4'h7,
                     M_HURT       = 4'h8,
                     M_ANGRY      = 4'h9,
                     M_SATISFIED  = 4'hA,
                     M_MELANCHOLY = 4'hB;

    // Turn flag bits (register TURN)
    localparam F_HOSTILE     = 0,
               F_INSULT      = 1,
               F_SUCCESS     = 2,
               F_COMPLIMENT  = 3,
               F_INTERESTING = 4,
               F_QUESTION    = 5,
               F_JOKE        = 6,
               F_DISTRESS    = 7;

    // Event codes (register EVENT and reflex wires)
    localparam [1:0] E_GOODBYE = 2'd0,
                     E_STARTLE = 2'd1,
                     E_TOUCHED = 2'd2,
                     E_KNOCKED = 2'd3;

    // Register addresses
    localparam [6:0] A_ID        = 7'h00,
                     A_VERSION   = 7'h01,
                     A_MOOD      = 7'h02,
                     A_INTENSITY = 7'h03,
                     A_STATUS    = 7'h04,
                     A_SILENCE   = 7'h05,
                     A_REPEAT    = 7'h08,
                     A_TURN      = 7'h09,
                     A_EVENT     = 7'h0A,
                     A_TICK_DIV  = 7'h0B,
                     A_COOL      = 7'h0C,
                     A_MEL_DELAY = 7'h0D,
                     A_ODDS      = 7'h0E,
                     A_CONTROL   = 7'h0F,
                     A_SEED      = 7'h10,
                     A_DEBUG_SEL = 7'h11;

    // Engine action kinds
    localparam [2:0] K_NONE  = 3'd0,
                     K_EVENT = 3'd1,
                     K_TURN  = 3'd2,
                     K_COOL  = 3'd3,
                     K_MEL   = 3'd4;

    // ------------------------------------------------------------------
    // Saturating helpers. Every shift clamps intensity to 26..255,
    // the same as max(0.1, min(1.0, x)) in _shift().
    // ------------------------------------------------------------------
    function [7:0] add_sat;
        input [7:0] a;
        input [7:0] b;
        reg   [8:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            add_sat = s[8] ? 8'd255 : s[7:0];
        end
    endfunction

    function [7:0] sub_floor;
        input [7:0] a;
        input [7:0] b;
        begin
            sub_floor = ({1'b0, a} < ({1'b0, b} + 9'd26)) ? 8'd26 : (a - b);
        end
    endfunction

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg  [3:0]  mood;
    reg  [7:0]  inten;

    reg  [23:0] pre;          // free-running prescaler
    reg  [15:0] lfsr;
    reg         heartbeat;
    reg         irq;
    reg         changed;
    reg  [4:0]  turns;        // turns since STATUS was last read, saturating

    // configuration
    reg  [4:0]  tick_div;
    reg  [7:0]  cool_period;
    reg  [7:0]  mel_delay;
    reg  [7:0]  insult_odds;
    reg         lock;
    reg         freeze;
    reg  [6:0]  debug_sel;

    // time rules
    reg  [11:0] silence;      // ticks since the last turn, saturating
    reg  [7:0]  cool_cnt;
    reg         mel_fired;

    // pending work (one deep each)
    reg  [3:0]  pend_rf;      // [0] LOUD [1] TOUCH [2] MOTION [3] TILT
    reg         pend_ev;
    reg  [1:0]  ev_code;
    reg         pend_turn;
    reg  [7:0]  turn_flags;
    reg  [2:0]  turn_rep;
    reg  [2:0]  repeat_reg;
    reg         pend_cool;
    reg         pend_mel;

    // ------------------------------------------------------------------
    // Timing: tick, ~1 ms strobe, PWM
    // ------------------------------------------------------------------
    wire [23:0] tick_mask = (24'd1 << tick_div) - 24'd1;
    wire        tick      = &(pre | ~tick_mask);
    wire        ms_stb    = &pre[12:0];          // every 8192 clocks (0.82 ms at 10 MHz)
    wire        pwm       = (pre[7:0] < inten);

    // 16-bit Galois LFSR, taps 0xB400, steps every clock
    wire [15:0] lfsr_next = lfsr[0] ? ((lfsr >> 1) ^ 16'hB400) : (lfsr >> 1);

    // ------------------------------------------------------------------
    // SPI
    // ------------------------------------------------------------------
    wire [6:0] spi_addr;
    wire       spi_rd_stb, spi_wr_stb;
    wire [7:0] spi_wr_data;
    wire       spi_miso;
    reg  [7:0] rd_data;

    affect_spi u_spi (
        .clk     (clk),
        .rst_n   (rst_n),
        .sck_in  (ui_in[0]),
        .mosi_in (ui_in[1]),
        .csn_in  (ui_in[2]),
        .rd_data (rd_data),
        .miso    (spi_miso),
        .addr    (spi_addr),
        .rd_stb  (spi_rd_stb),
        .wr_stb  (spi_wr_stb),
        .wr_data (spi_wr_data)
    );

    // Register read mux. Written out twice (SPI and debug bus) instead of
    // as a function, so every simulator re-evaluates it when state changes.
    reg [7:0] dbg_data;

    always @(*) begin
        case (spi_addr)
            A_ID:        rd_data = 8'hEC;
            A_VERSION:   rd_data = 8'h02;
            A_MOOD:      rd_data = {4'd0, mood};
            A_INTENSITY: rd_data = inten;
            A_STATUS:    rd_data = {turns, mel_fired, changed, lock};
            A_SILENCE:   rd_data = silence[11:4];
            A_TICK_DIV:  rd_data = {3'd0, tick_div};
            A_COOL:      rd_data = cool_period;
            A_MEL_DELAY: rd_data = mel_delay;
            A_ODDS:      rd_data = insult_odds;
            A_CONTROL:   rd_data = {6'd0, freeze, lock};
            A_DEBUG_SEL: rd_data = {1'b0, debug_sel};
            default:     rd_data = 8'h00;
        endcase
    end

    always @(*) begin
        case (debug_sel)
            A_ID:        dbg_data = 8'hEC;
            A_VERSION:   dbg_data = 8'h02;
            A_MOOD:      dbg_data = {4'd0, mood};
            A_INTENSITY: dbg_data = inten;
            A_STATUS:    dbg_data = {turns, mel_fired, changed, lock};
            A_SILENCE:   dbg_data = silence[11:4];
            A_TICK_DIV:  dbg_data = {3'd0, tick_div};
            A_COOL:      dbg_data = cool_period;
            A_MEL_DELAY: dbg_data = mel_delay;
            A_ODDS:      dbg_data = insult_odds;
            A_CONTROL:   dbg_data = {6'd0, freeze, lock};
            A_DEBUG_SEL: dbg_data = {1'b0, debug_sel};
            default:     dbg_data = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------
    // Reflex inputs: sync, rising edge, ~1-2 ms lockout
    // ------------------------------------------------------------------
    reg  [3:0] rf_s1, rf_s2, rf_prev;
    reg  [7:0] rf_lock;                      // 2 bits per line
    wire [3:0] rf_rise = rf_s2 & ~rf_prev;
    reg  [3:0] rf_new;                       // accepted edges this cycle
    reg  [7:0] rf_lock_next;
    integer    i;

    always @(*) begin
        rf_new       = 4'd0;
        rf_lock_next = rf_lock;
        for (i = 0; i < 4; i = i + 1) begin
            if (ms_stb && rf_lock[2*i +: 2] != 2'd0)
                rf_lock_next[2*i +: 2] = rf_lock[2*i +: 2] - 2'd1;
            if (rf_rise[i] && rf_lock[2*i +: 2] == 2'd0) begin
                rf_new[i]              = 1'b1;
                rf_lock_next[2*i +: 2] = 2'd2;
            end
        end
    end

    // ------------------------------------------------------------------
    // Action select. Priority: TILT, LOUD, MOTION, TOUCH, SPI event,
    // turn, cooling, melancholy drift. SPI register writes take the
    // cycle when they happen; the engine waits one clock.
    // ------------------------------------------------------------------
    reg [2:0] kind;
    reg [1:0] act_ev;
    reg [3:0] rf_clr;
    reg       ev_clr;

    always @(*) begin
        kind   = K_NONE;
        act_ev = E_GOODBYE;
        rf_clr = 4'd0;
        ev_clr = 1'b0;
        if      (pend_rf[3]) begin kind = K_EVENT; act_ev = E_KNOCKED; rf_clr[3] = 1'b1; end
        else if (pend_rf[0]) begin kind = K_EVENT; act_ev = E_STARTLE; rf_clr[0] = 1'b1; end
        else if (pend_rf[2]) begin kind = K_EVENT; act_ev = E_STARTLE; rf_clr[2] = 1'b1; end
        else if (pend_rf[1]) begin kind = K_EVENT; act_ev = E_TOUCHED; rf_clr[1] = 1'b1; end
        else if (pend_ev)    begin kind = K_EVENT; act_ev = ev_code;   ev_clr    = 1'b1; end
        else if (pend_turn)  begin kind = K_TURN;  end
        else if (pend_cool)  begin kind = K_COOL;  end
        else if (pend_mel)   begin kind = K_MEL;   end
    end

    wire engine_go = (kind != K_NONE) && !spi_wr_stb;

    // ------------------------------------------------------------------
    // Transition rules (combinational). Mirrors process_turn(),
    // _shift() and _decay(), plus the new rules from the spec.
    // ------------------------------------------------------------------
    reg [3:0] nm;
    reg [7:0] ni;

    wire bad_mood = (mood == M_IRRITATED) || (mood == M_FRUSTRATED) || (mood == M_ANGRY);

    // Rule 2, shared by INSULT and KNOCKED
    wire       hurt_roll = (lfsr[7:0] < insult_odds);              // ~60% hurt
    wire [3:0] ins_m = bad_mood ? M_ANGRY : (hurt_roll ? M_HURT : M_ANGRY);
    wire [7:0] ins_i = bad_mood ? add_sat(inten, 8'd77)             // min(1.0, I + 0.3)
                                : 8'd191;                           // 0.75

    // _decay(): neutral and engaged never decay
    wire       dec_on   = (mood != M_NEUTRAL) && (mood != M_ENGAGED);
    wire [7:0] dec_v    = sub_floor(inten, 8'd18);                  // I - 0.07, floor 0.1
    wire       dec_zero = (dec_v <= 8'd38);                         // <= 0.15 -> neutral at 0.3
    wire [3:0] dec_m    = dec_on ? (dec_zero ? M_NEUTRAL : mood) : mood;
    wire [7:0] dec_i    = dec_on ? (dec_zero ? 8'd77 : dec_v) : inten;

    always @(*) begin
        nm = mood;
        ni = inten;

        case (kind)
        // ---------------- turns ----------------
        K_TURN: begin
            if (turn_flags[F_HOSTILE]) begin                       // 1
                nm = M_ANGRY; ni = 8'd242;
            end else if (turn_flags[F_INSULT]) begin               // 2
                nm = ins_m; ni = ins_i;
            end else if (turn_flags[F_DISTRESS] && mood != M_ANGRY) begin  // 3 (new)
                nm = M_CONCERNED; ni = 8'd179;
            end else if (turn_rep >= 3'd5) begin                   // 4
                nm = M_RESIGNED; ni = 8'd217;
            end else if (turn_rep >= 3'd3) begin
                if (mood == M_IRRITATED) begin
                    nm = M_FRUSTRATED; ni = add_sat(inten, 8'd64);
                end else if (mood != M_FRUSTRATED && mood != M_RESIGNED && mood != M_ANGRY) begin
                    nm = M_IRRITATED; ni = 8'd166;
                end
                // else: turn used, no change
            end else if (turn_rep == 3'd2 && mood == M_NEUTRAL) begin
                nm = M_IRRITATED; ni = 8'd89;
            end else if (turn_flags[F_SUCCESS]) begin              // 5
                nm = M_SATISFIED; ni = 8'd179;
            end else if (turn_flags[F_COMPLIMENT]) begin           // 6
                if (mood == M_HURT || bad_mood) begin
                    nm = M_NEUTRAL; ni = 8'd102;
                end else if (mood == M_NEUTRAL || mood == M_MELANCHOLY) begin
                    nm = M_ENGAGED; ni = 8'd140;
                end
            end else if (turn_flags[F_INTERESTING]) begin          // 7
                if (mood == M_NEUTRAL || mood == M_SATISFIED || mood == M_CURIOUS) begin
                    nm = M_ENGAGED; ni = 8'd179;
                end else if (mood == M_ENGAGED) begin
                    ni = add_sat(inten, 8'd26);
                end
            end else if (turn_flags[F_JOKE]) begin                 // 8 (new)
                if (mood == M_NEUTRAL || mood == M_ENGAGED || mood == M_SATISFIED ||
                    mood == M_CURIOUS || mood == M_AMUSED  || mood == M_MELANCHOLY) begin
                    nm = M_AMUSED; ni = 8'd153;
                end else if (mood == M_IRRITATED || mood == M_FRUSTRATED) begin
                    ni = sub_floor(inten, 8'd38);
                end
            end else if (turn_flags[F_QUESTION]) begin             // 9 (new)
                if (mood == M_NEUTRAL || mood == M_SATISFIED ||
                    mood == M_AMUSED  || mood == M_MELANCHOLY) begin
                    nm = M_CURIOUS; ni = 8'd140;
                end else if (mood == M_CURIOUS) begin
                    ni = add_sat(inten, 8'd26);
                end
            end else begin                                         // 10
                nm = dec_m; ni = dec_i;
            end
        end

        // ---------------- events (new) ----------------
        K_EVENT: begin
            case (act_ev)
                E_GOODBYE:
                    if (mood == M_ENGAGED || mood == M_SATISFIED ||
                        mood == M_AMUSED  || mood == M_CURIOUS) begin
                        nm = M_MELANCHOLY; ni = 8'd89;
                    end
                E_STARTLE:
                    if (mood == M_NEUTRAL || mood == M_SATISFIED ||
                        mood == M_ENGAGED || mood == M_MELANCHOLY) begin
                        nm = M_CURIOUS; ni = 8'd115;
                    end else if (bad_mood || mood == M_RESIGNED) begin
                        ni = add_sat(inten, 8'd26);
                    end
                E_TOUCHED:
                    if (mood == M_HURT || mood == M_MELANCHOLY) begin
                        nm = M_NEUTRAL; ni = 8'd77;
                    end
                E_KNOCKED: begin
                    nm = ins_m; ni = ins_i;
                end
            endcase
        end

        // ---------------- time rules (new) ----------------
        K_COOL: begin
            if (mood != M_MELANCHOLY) begin
                nm = dec_m; ni = dec_i;
            end
        end

        K_MEL: begin
            if (mood == M_NEUTRAL) begin
                nm = M_MELANCHOLY; ni = 8'd102;
            end
        end

        default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Time-rule triggers
    // ------------------------------------------------------------------
    wire [7:0] cool_cnt_inc = cool_cnt + 8'd1;
    wire time_on  = tick && !freeze;
    wire cool_set = time_on && (cool_period != 8'd0) && (cool_cnt_inc >= cool_period);
    wire mel_set  = time_on && (mel_delay != 8'd0) && !mel_fired && !pend_mel &&
                    (silence[11:4] >= mel_delay) && (mood == M_NEUTRAL);

    // Register write decode
    wire wr_ctrl    = spi_wr_stb && (spi_addr == A_CONTROL);
    wire ctrl_reset = wr_ctrl && spi_wr_data[2];
    wire turn_done  = engine_go && (kind == K_TURN);
    wire clr_time   = turn_done || ctrl_reset;

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            mood        <= M_NEUTRAL;
            inten       <= 8'd77;          // 0.3
            pre         <= 24'd0;
            lfsr        <= 16'hACE1;
            heartbeat   <= 1'b0;
            irq         <= 1'b0;
            changed     <= 1'b0;
            turns       <= 5'd0;
            tick_div    <= 5'd23;          // 0.84 s ticks at 10 MHz
            cool_period <= 8'd60;          // ~50 s per decay step
            mel_delay   <= 8'd134;         // ~30 min
            insult_odds <= 8'd154;         // ~60% hurt
            lock        <= 1'b0;
            freeze      <= 1'b0;
            debug_sel   <= A_MOOD;
            silence     <= 12'd0;
            cool_cnt    <= 8'd0;
            mel_fired   <= 1'b0;
            pend_rf     <= 4'd0;
            pend_ev     <= 1'b0;
            ev_code     <= 2'd0;
            pend_turn   <= 1'b0;
            turn_flags  <= 8'd0;
            turn_rep    <= 3'd0;
            repeat_reg  <= 3'd0;
            pend_cool   <= 1'b0;
            pend_mel    <= 1'b0;
            rf_s1       <= 4'd0;
            rf_s2       <= 4'd0;
            rf_prev     <= 4'd0;
            rf_lock     <= 8'd0;
        end else begin
            pre  <= pre + 24'd1;
            lfsr <= lfsr_next;

            // reflex synchronizers and lockouts
            rf_s1   <= ui_in[7:4];
            rf_s2   <= rf_s1;
            rf_prev <= rf_s2;
            rf_lock <= rf_lock_next;

            if (tick) begin
                heartbeat <= ~heartbeat;
                irq       <= 1'b0;
            end

            // time counters
            if (time_on) begin
                if (silence != 12'hFFF)
                    silence <= silence + 12'd1;
                cool_cnt <= cool_set ? 8'd0 : cool_cnt_inc;
            end
            if (mel_set)
                mel_fired <= 1'b1;

            // pending flags (single assignment each)
            pend_rf   <= (pend_rf & ~(engine_go ? rf_clr : 4'd0)) | rf_new;
            pend_cool <= clr_time ? 1'b0 :
                         ((pend_cool & ~(engine_go && kind == K_COOL)) | cool_set);
            pend_mel  <= clr_time ? 1'b0 :
                         ((pend_mel  & ~(engine_go && kind == K_MEL))  | mel_set);

            // STATUS read clears CHANGED and the turn counter
            if (spi_rd_stb && spi_addr == A_STATUS) begin
                changed <= 1'b0;
                turns   <= 5'd0;
            end

            // ---- SPI register writes ----
            if (spi_wr_stb) begin
                case (spi_addr)
                    A_MOOD:
                        if (!lock && spi_wr_data[3:0] <= M_MELANCHOLY) begin
                            if (spi_wr_data[3:0] != mood) begin
                                changed <= 1'b1;
                                irq     <= 1'b1;
                            end
                            mood <= spi_wr_data[3:0];
                        end
                    A_INTENSITY:
                        if (!lock)
                            inten <= (spi_wr_data < 8'd26) ? 8'd26 : spi_wr_data;
                    A_REPEAT:
                        repeat_reg <= spi_wr_data[2:0];
                    A_TURN: begin
                        pend_turn  <= 1'b1;
                        turn_flags <= spi_wr_data;
                        turn_rep   <= repeat_reg;
                    end
                    A_EVENT: begin
                        pend_ev <= 1'b1;
                        ev_code <= spi_wr_data[1:0];
                    end
                    A_TICK_DIV:  if (!lock) tick_div    <= spi_wr_data[4:0];
                    A_COOL:      if (!lock) cool_period <= spi_wr_data;
                    A_MEL_DELAY: if (!lock) mel_delay   <= spi_wr_data;
                    A_ODDS:      if (!lock) insult_odds <= spi_wr_data;
                    A_CONTROL: begin
                        if (spi_wr_data[0]) lock <= 1'b1;      // set-only
                        freeze <= spi_wr_data[1];
                        if (spi_wr_data[2]) begin              // RESET (self-clearing)
                            mood      <= M_NEUTRAL;
                            inten     <= 8'd77;
                            silence   <= 12'd0;
                            cool_cnt  <= 8'd0;
                            mel_fired <= 1'b0;
                            pend_turn <= 1'b0;
                            pend_ev   <= 1'b0;
                        end
                    end
                    A_SEED:
                        if (!lock)
                            lfsr <= ((lfsr_next ^ {8'd0, spi_wr_data}) == 16'd0) ?
                                    16'd1 : (lfsr_next ^ {8'd0, spi_wr_data});
                    A_DEBUG_SEL:
                        debug_sel <= spi_wr_data[6:0];
                    default: ;
                endcase
            end

            // ---- mood engine ----
            else if (engine_go) begin
                mood  <= nm;
                inten <= ni;
                if (nm != mood) begin
                    changed <= 1'b1;
                    irq     <= 1'b1;
                end
                if (ev_clr)
                    pend_ev <= 1'b0;
                if (kind == K_TURN) begin
                    pend_turn <= 1'b0;
                    silence   <= 12'd0;
                    cool_cnt  <= 8'd0;
                    mel_fired <= 1'b0;
                    if (turns != 5'd31)
                        turns <= turns + 5'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    wire test_mode = ui_in[3];

    assign uo_out  = {heartbeat, irq, mood, pwm, spi_miso};
    assign uio_out = test_mode ? dbg_data : 8'h00;
    assign uio_oe  = test_mode ? 8'hFF : 8'h00;

    // Unused inputs
    wire _unused = &{ena, uio_in, 1'b0};

endmodule

`default_nettype wire
