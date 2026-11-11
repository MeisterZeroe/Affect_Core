/*
 * affect_spi.v - SPI slave for the Echoes Affect Core
 * Evil Company Ink. LLC
 *
 * Mode 0, MSB first, 16-bit frames:
 *   byte 0 = {rw, addr[6:0]}   rw = 1 -> read
 *   byte 1 = write data, or read data shifted out on MISO
 *
 * SCK, MOSI and CS_N are oversampled by the system clock through
 * two-flop synchronizers, so SCK must stay at or below clk/8
 * (1.25 MHz at a 10 MHz clock). The Pi driver uses 1 MHz.
 */
`default_nettype none

module affect_spi (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sck_in,
    input  wire       mosi_in,
    input  wire       csn_in,
    input  wire [7:0] rd_data,   // register value for `addr`, combinational from the top
    output wire       miso,
    output reg  [6:0] addr,      // valid from the 8th bit until CS_N rises
    output reg        rd_stb,    // one-cycle pulse when a read's data is captured
    output reg        wr_stb,    // one-cycle pulse when a write's 16th bit arrives
    output reg  [7:0] wr_data
);

    // ---- synchronizers -------------------------------------------------
    reg [2:0] sck_s;
    reg [1:0] mosi_s;
    reg [1:0] csn_s;

    always @(posedge clk) begin
        if (!rst_n) begin
            sck_s  <= 3'b000;
            mosi_s <= 2'b00;
            csn_s  <= 2'b11;
        end else begin
            sck_s  <= {sck_s[1:0], sck_in};
            mosi_s <= {mosi_s[0], mosi_in};
            csn_s  <= {csn_s[0], csn_in};
        end
    end

    wire sck_rise = sck_s[1] & ~sck_s[2];
    wire sck_fall = ~sck_s[1] & sck_s[2];
    wire mosi     = mosi_s[1];
    wire csn      = csn_s[1];

    // ---- frame logic ---------------------------------------------------
    reg [4:0] cnt;      // bits received this frame, 0..16
    reg [7:0] sh_in;
    reg [7:0] sh_out;
    reg       rw;
    reg       load1;    // byte 0 complete: latch addr / rw
    reg       load2;    // addr stable: capture read data

    assign miso = sh_out[7];

    always @(posedge clk) begin
        rd_stb <= 1'b0;
        wr_stb <= 1'b0;
        load1  <= 1'b0;
        load2  <= 1'b0;

        if (!rst_n) begin
            cnt     <= 5'd0;
            sh_in   <= 8'd0;
            sh_out  <= 8'd0;
            rw      <= 1'b0;
            addr    <= 7'd0;
            wr_data <= 8'd0;
        end else if (csn) begin
            cnt    <= 5'd0;
            sh_out <= 8'd0;
        end else begin
            if (sck_rise && cnt != 5'd16) begin
                sh_in <= {sh_in[6:0], mosi};
                cnt   <= cnt + 5'd1;
                if (cnt == 5'd7)
                    load1 <= 1'b1;
                if (cnt == 5'd15) begin
                    wr_data <= {sh_in[6:0], mosi};
                    if (!rw)
                        wr_stb <= 1'b1;
                end
            end

            if (load1) begin
                rw    <= sh_in[7];
                addr  <= sh_in[6:0];
                load2 <= sh_in[7];
            end

            if (load2) begin
                sh_out <= rd_data;   // MSB appears on MISO before the 9th SCK rise
                rd_stb <= 1'b1;
            end

            // Shift the next read bit out after each falling edge of byte 1.
            if (sck_fall && cnt >= 5'd9)
                sh_out <= {sh_out[6:0], 1'b0};
        end
    end

endmodule

`default_nettype wire
