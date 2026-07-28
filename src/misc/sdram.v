// Simple SDRAM controller for Tang Nano 20K (GW2AR-18C embedded SDRAM)
// Based on nand2mario sdram-tang-nano-20k (2023)
// Adapted for 28.8 MHz operation with pixel FIFO for frame buffer use.
//
// GW2AR-18C embedded SDRAM: 64Mbit, 32-bit wide
//   Organization: 2K rows x 256 columns x 4 banks x 32 bits
//   No .cst pin assignments needed — SDRAM is embedded in the SIP package.
//   Requires: SDRAM_CLK fed from rPLL CLKOUTP (180° phase-shifted from clk).
//
// Interface: byte-addressed, non-bursting, auto-precharge.
//   - Each read/write takes 5 cycles at <=66.7 MHz.
//   - At 28.8 MHz (34.7 ns/cycle): all SDRAM timing specs met with margin.
//   - Refresh: caller must assert 'refresh' at least once every 15 µs.
//
// This module uses DATA_WIDTH=32 (4 bytes per access) to maximize efficiency.
// The frame_buffer packs two 12-bit pixels into one 32-bit word.

module sdram #(
    parameter         FREQ       = 28_800_000,
    parameter         DATA_WIDTH = 32,
    parameter         ROW_WIDTH  = 11,   // 2K rows
    parameter         COL_WIDTH  = 8,    // 256 words per row
    parameter         BANK_WIDTH = 2,    // 4 banks

    // Timing parameters (cycles at 28.8 MHz, 34.7 ns/cycle)
    // SDRAM spec: tRCD=15ns, tRP=15ns, tRC=60ns, tWR=2clk
    // At 28.8 MHz: 1 cycle=34.7ns >> all minimums satisfied with 1 cycle each
    parameter [3:0]   CAS   = 4'd2,   // CAS latency = 2 cycles
    parameter [3:0]   T_WR  = 4'd2,   // Write recovery = 2 cycles
    parameter [3:0]   T_MRD = 4'd2,   // Mode register set = 2 cycles
    parameter [3:0]   T_RP  = 4'd1,   // Precharge to active = 1 cycle (34.7ns > 15ns)
    parameter [3:0]   T_RCD = 4'd1,   // Active to R/W = 1 cycle (34.7ns > 15ns)
    parameter [3:0]   T_RC  = 4'd2    // Ref/Active to Ref/Active = 2 cycles (69ns > 60ns)
)(
    // -------- SDRAM chip interface (internal SIP, no .cst needed) --------
    inout  [DATA_WIDTH-1:0]     SDRAM_DQ,
    output reg [ROW_WIDTH-1:0]  SDRAM_A,
    output reg [BANK_WIDTH-1:0] SDRAM_BA,
    output                      SDRAM_nCS,
    output reg                  SDRAM_nWE,
    output reg                  SDRAM_nRAS,
    output reg                  SDRAM_nCAS,
    output                      SDRAM_CLK,    // 180°-phase-shifted clock from PLL
    output                      SDRAM_CKE,
    output reg [3:0]            SDRAM_DQM,

    // -------- Logic interface --------
    input                       clk,          // system clock (28.8 MHz)
    input                       clk_sdram,    // 180°-shifted from clk (rPLL CLKOUTP)
    input                       resetn,
    input                       rd,           // read strobe (1-cycle pulse)
    input                       wr,           // write strobe (1-cycle pulse)
    input                       refresh,      // auto-refresh request
    input  [22:0]               addr,         // byte address
    input  [DATA_WIDTH-1:0]     din,          // write data (32-bit)
    output [DATA_WIDTH-1:0]     dout,         // read data (32-bit)
    output reg                  data_ready,   // read data valid (1 cycle)
    output reg                  busy          // controller busy
);

assign SDRAM_nCS  = 1'b0;   // always selected
assign SDRAM_CKE  = 1'b1;   // always enabled
assign SDRAM_CLK  = clk_sdram;

// DQ tristate control
reg  [DATA_WIDTH-1:0] dq_out;
reg                   dq_oe;
assign SDRAM_DQ = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};
assign dout     = SDRAM_DQ;

// -------- FSM states --------
localparam S_IDLE     = 4'd0;
localparam S_INIT_WAIT= 4'd1;
localparam S_PRECHARGE= 4'd2;
localparam S_REFRESH  = 4'd3;
localparam S_MODE     = 4'd4;
localparam S_ACTIVE   = 4'd5;
localparam S_READ     = 4'd6;
localparam S_READ_D1  = 4'd7;
localparam S_READ_D2  = 4'd8;
localparam S_WRITE    = 4'd9;
localparam S_WRITE_D1 = 4'd10;
localparam S_PRECHARGE2=4'd11;

// SDRAM commands: {nRAS, nCAS, nWE}
localparam CMD_NOP        = 3'b111;
localparam CMD_ACTIVE     = 3'b011;
localparam CMD_READ       = 3'b101;
localparam CMD_WRITE      = 3'b100;
localparam CMD_PRECHARGE  = 3'b010;
localparam CMD_AUTO_REFRESH=3'b001;
localparam CMD_LOAD_MODE  = 3'b000;

reg [3:0]  state;
reg [3:0]  wait_cnt;
reg [22:0] addr_reg;
reg [DATA_WIDTH-1:0] din_reg;
reg        rd_reg, wr_reg, ref_reg;

// Initialization counter (200µs @ 28.8MHz = 5760 cycles)
reg [12:0] init_cnt;
reg        initialized;

task set_cmd;
    input [2:0] cmd;
    begin
        {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= cmd;
    end
endtask

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state       <= S_INIT_WAIT;
        init_cnt    <= 0;
        initialized <= 0;
        busy        <= 1;
        data_ready  <= 0;
        dq_oe       <= 0;
        SDRAM_DQM   <= 4'b1111;
        set_cmd(CMD_NOP);
        SDRAM_A     <= 0;
        SDRAM_BA    <= 0;
    end else begin
        data_ready <= 0;
        set_cmd(CMD_NOP);
        dq_oe      <= 0;

        case (state)
            // ---- Initialization: wait 200µs, then precharge all ----
            S_INIT_WAIT: begin
                busy     <= 1;
                init_cnt <= init_cnt + 1;
                if (init_cnt == 13'd5760) begin
                    // Precharge all banks
                    set_cmd(CMD_PRECHARGE);
                    SDRAM_A  <= 11'b10000000000; // A10=1 → all banks
                    SDRAM_BA <= 0;
                    wait_cnt <= T_RP;
                    state    <= S_PRECHARGE;
                end
            end

            S_PRECHARGE: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    if (!initialized) begin
                        // Issue 2 auto-refreshes before mode register set
                        set_cmd(CMD_AUTO_REFRESH);
                        wait_cnt <= T_RC + T_RC; // two consecutive
                        state    <= S_REFRESH;
                    end else begin
                        state <= S_IDLE;
                        busy  <= 0;
                    end
                end
            end

            S_REFRESH: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    if (!initialized) begin
                        // Load mode register
                        set_cmd(CMD_LOAD_MODE);
                        SDRAM_BA <= 0;
                        // Mode: burst=1 (no burst), CAS=2, sequential
                        SDRAM_A  <= {4'b0000, 1'b1, 2'b00, CAS[2:0], 1'b0, 3'b000};
                        wait_cnt    <= T_MRD;
                        state       <= S_MODE;
                    end else begin
                        state <= S_IDLE;
                        busy  <= 0;
                    end
                end
            end

            S_MODE: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    initialized <= 1;
                    busy        <= 0;
                    state       <= S_IDLE;
                end
            end

            // ---- Idle: accept rd/wr/refresh ----
            S_IDLE: begin
                if (!initialized) begin
                    state <= S_INIT_WAIT;
                end else if (ref_reg || refresh) begin
                    ref_reg  <= 0;
                    busy     <= 1;
                    set_cmd(CMD_AUTO_REFRESH);
                    wait_cnt <= T_RC;
                    state    <= S_REFRESH;
                end else if (rd_reg || rd) begin
                    addr_reg <= rd ? addr : addr_reg;
                    rd_reg   <= 0;
                    busy     <= 1;
                    // Activate row
                    set_cmd(CMD_ACTIVE);
                    SDRAM_BA <= rd ? addr[COL_WIDTH+BANK_WIDTH-1:COL_WIDTH] : addr_reg[COL_WIDTH+BANK_WIDTH-1:COL_WIDTH];
                    SDRAM_A  <= rd ? addr[COL_WIDTH+ROW_WIDTH+BANK_WIDTH-1:COL_WIDTH+BANK_WIDTH] :
                                     addr_reg[COL_WIDTH+ROW_WIDTH+BANK_WIDTH-1:COL_WIDTH+BANK_WIDTH];
                    wait_cnt <= T_RCD;
                    state    <= S_READ;
                end else if (wr_reg || wr) begin
                    addr_reg <= wr ? addr : addr_reg;
                    din_reg  <= wr ? din : din_reg;
                    wr_reg   <= 0;
                    busy     <= 1;
                    set_cmd(CMD_ACTIVE);
                    SDRAM_BA <= wr ? addr[COL_WIDTH+BANK_WIDTH-1:COL_WIDTH] : addr_reg[COL_WIDTH+BANK_WIDTH-1:COL_WIDTH];
                    SDRAM_A  <= wr ? addr[COL_WIDTH+ROW_WIDTH+BANK_WIDTH-1:COL_WIDTH+BANK_WIDTH] :
                                     addr_reg[COL_WIDTH+ROW_WIDTH+BANK_WIDTH-1:COL_WIDTH+BANK_WIDTH];
                    wait_cnt <= T_RCD;
                    state    <= S_WRITE;
                end else begin
                    busy <= 0;
                end
            end

            S_READ: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    set_cmd(CMD_READ);
                    // A[10]=1 → auto-precharge; A[9:8]=0; A[7:0]=column
                    // ROW_WIDTH=11 bits: must be {1,0,0,col[7:0]} = 11 bits
                    SDRAM_A  <= {1'b1, 2'b00, addr_reg[COL_WIDTH-1:0]};
                    SDRAM_DQM<= 4'b0000;
                    dq_oe    <= 0;
                    wait_cnt <= CAS - 1;
                    state    <= S_READ_D1;
                end
            end

            S_READ_D1: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    // Data will be on DQ next cycle
                    state <= S_READ_D2;
                end
            end

            S_READ_D2: begin
                data_ready <= 1;  // dout is valid this cycle
                wait_cnt   <= T_RP;
                state      <= S_PRECHARGE2;
            end

            // ---- Write sequence ----
            S_WRITE: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    set_cmd(CMD_WRITE);
                    // A[10]=1 → auto-precharge; A[9:8]=0; A[7:0]=column
                    SDRAM_A   <= {1'b1, 2'b00, addr_reg[COL_WIDTH-1:0]};
                    SDRAM_DQM <= 4'b0000;
                    dq_oe     <= 1;
                    dq_out    <= din_reg;
                    wait_cnt  <= T_WR;
                    state     <= S_WRITE_D1;
                end
            end

            S_WRITE_D1: begin
                dq_oe <= 0;
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    wait_cnt <= T_RP;
                    state    <= S_PRECHARGE2;
                end
            end

            S_PRECHARGE2: begin
                if (wait_cnt != 0)
                    wait_cnt <= wait_cnt - 1;
                else begin
                    busy  <= 0;
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase

        // Latch incoming requests when busy (don't drop them)
        if (busy && rd) rd_reg  <= 1;
        if (busy && wr) wr_reg  <= 1;
        if (refresh)    ref_reg <= 1;
    end
end

endmodule
