// video.v

module video (
          input	   clk,
          input    clk_pixel_x5,
          input    clk_cpu,
          input    pll_lock,

          input    vb_in,
          input    hb_in,
	      input	   vs_in_n,
	      input	   hs_in_n,
          input    de_in,

	      input [3:0]  r_in,
	      input [3:0]  g_in,
	      input [3:0]  b_in,

          input [14:0] audio_l,
          input [14:0] audio_r,

          input vblank_regenerate,
          output osd_status,
          output paldetect,

          // (spi) interface from MCU
          input	   mcu_start,
          input	   mcu_osd_strobe,
          input [7:0]  mcu_data,

          // values that can be configure by the user via osd          
          input [1:0]  system_scanlines,
          input [1:0]  system_volume,
          input	[1:0]  system_screen,
          // Mod by SAN: VSync stabilizer mode (00 = smart, 01 = fixed, 10 = none)
          input [1:0]  system_video_stab,

          // Mod by SAN: bypass when loading cart (no SDRAM frame buffering during download)
          input        fb_bypass,

          // SDRAM frame buffer interface (connected to embedded GW2AR-18C SDRAM)
          inout [31:0]  IO_sdram_dq,
          output [10:0] O_sdram_addr,
          output [1:0]  O_sdram_ba,
          output        O_sdram_cs_n,
          output        O_sdram_ras_n,
          output        O_sdram_cas_n,
          output        O_sdram_wen_n,
          output        O_sdram_clk,
          output        O_sdram_cke,
          output [3:0]  O_sdram_dqm,
          input         clk_sdram,   // 180°-phase-shifted clock for SDRAM

	      // hdmi/tdms
	      output	   tmds_clk_n,
	      output	   tmds_clk_p,
	      output [2:0] tmds_d_n,
	      output [2:0] tmds_d_p  
	      );
   
/* -------------------- HDMI video and audio -------------------- */

wire vs_stab,vb_stab,pal;
wire sd_hs_n, sd_vs_n;
wire [8:0] total_lines;
assign paldetect = pal;

// video_stabilize receives RAW TIA signals (unchanged) for PAL detection
video_stabilize video_stabilize
(
	.clk(clk),          // system clock
	.reset(!pll_lock),  // System reset
	.oclk(clk),         // Oscillator clock aka pixel clock or color clock
	// Mod by SAN: set stabilizer mode from sysctrl
	.mode(system_video_stab),  // 00 = smart, 01 = fixed, 10 = none
	.vsync_in(vs_in_n), // Unmodified vsync signal
	.vblank_in(vb_in),  // Umodified vblank signal
	.hsync_in(hs_in_n), // Unmodified hsync signal
	.hblank_in(hb_in),  // Hblank signal with applicable system delays

	.vsync(vs_stab),
	.vblank(vb_stab),
	.auto_pal(pal),
	.f1(),
    .tlines(total_lines)
);

// -------- SDRAM frame buffer (ping-pong) --------
// Captures TIA frames into SDRAM and replays them with FIXED height
// to the scandoubler, eliminating frame-height variation.

// frame_buffer outputs only pixel data (no timing signals)
wire [7:0]  fb_rd_r, fb_rd_g, fb_rd_b;

wire        fb_sdram_rd, fb_sdram_wr, fb_sdram_refresh;
wire [22:0] fb_sdram_addr;
wire [31:0] fb_sdram_din;
wire [31:0] fb_sdram_dout;
wire        fb_sdram_data_ready;
reg [15:0] por_cnt = 0;
reg        por_resetn = 0;

always @(posedge clk or negedge pll_lock) begin
    if (!pll_lock) begin
        por_cnt    <= 0;
        por_resetn <= 0;
    end else begin
        if (por_cnt < 16'd30000) begin // ~1.04ms @ 28.8MHz (>200us physical SDRAM requirement)
            por_cnt    <= por_cnt + 1'b1;
            por_resetn <= 0;
        end else begin
            por_resetn <= 1;
        end
    end
end

frame_buffer frame_buffer (
    .clk     (clk),
    .clk_cpu (clk_cpu),
    .resetn  (por_resetn),
    .bypass  (fb_bypass),

    // TIA write side (captura frames na SDRAM)
    .wr_vsync  (!vs_in_n),   // vsync active-high
    .wr_hblank (hb_in),
    .wr_vblank (vb_in),
    .wr_r      ({r_in, 4'b0}),
    .wr_g      ({g_in, 4'b0}),
    .wr_b      ({b_in, 4'b0}),
    .pal       (pal),

    // Read side: timing externo (video_stabilize controla tudo)
    .rd_hblank_in (hb_in),    // hblank TIA (timing horizontal)
    .rd_vblank_in (vb_stab),  // vblank estabilizado pelo video_stabilize

    // Saída de pixel (somente cor — sem timing)
    .rd_r (fb_rd_r),
    .rd_g (fb_rd_g),
    .rd_b (fb_rd_b),

    // SDRAM controller
    .sdram_rd         (fb_sdram_rd),
    .sdram_wr         (fb_sdram_wr),
    .sdram_refresh    (fb_sdram_refresh),
    .sdram_addr       (fb_sdram_addr),
    .sdram_din        (fb_sdram_din),
    .sdram_dout       (fb_sdram_dout),
    .sdram_data_ready (fb_sdram_data_ready),
    .sdram_busy       (fb_sdram_busy)
);

sdram #(
    .FREQ(28_800_000),
    .T_RCD(4'd0),
    .T_RP(4'd0)
) sdram_ctrl (
    // Embedded SDRAM chip pins (GW2AR-18C SIP, no .cst needed)
    .SDRAM_DQ  (IO_sdram_dq),
    .SDRAM_A   (O_sdram_addr),
    .SDRAM_BA  (O_sdram_ba),
    .SDRAM_nCS (O_sdram_cs_n),
    .SDRAM_nRAS(O_sdram_ras_n),
    .SDRAM_nCAS(O_sdram_cas_n),
    .SDRAM_nWE (O_sdram_wen_n),
    .SDRAM_CLK (O_sdram_clk),
    .SDRAM_CKE (O_sdram_cke),
    .SDRAM_DQM (O_sdram_dqm),

    // Logic interface
    .clk        (clk),
    .clk_sdram  (clk_sdram),
    .resetn     (por_resetn),
    .rd         (fb_sdram_rd),
    .wr         (fb_sdram_wr),
    .refresh    (fb_sdram_refresh),
    .addr       (fb_sdram_addr),
    .din        (fb_sdram_din),
    .dout       (fb_sdram_dout),
    .data_ready (fb_sdram_data_ready),
    .busy       (fb_sdram_busy)
);

// generate 48khz audio clock
`define PIXEL_CLOCK 28542800

// generate 48khz audio clock
reg clk_audio;
reg [8:0] aclk_cnt;
always @(posedge clk) begin
    // divisor = pixel clock / 48000 / 2 - 1
    if(aclk_cnt < `PIXEL_CLOCK / 48000 / 2 -1)
        aclk_cnt <= aclk_cnt + 9'd1;
    else begin
        aclk_cnt <= 9'd0;
        clk_audio <= ~clk_audio;
    end
end

/* ------------ expand audio to 16 bits and apply volume adjustment ------------ */
wire [15:0] audio16_l = { audio_l[14], audio_l };
wire [15:0] audio16_r = { audio_r[14], audio_r };

// scale audio for valume by signed division
wire [15:0] audio_vol_l = 
    (system_volume == 2'd0)?16'd0:
    (system_volume == 2'd1)?{ {2{audio16_l[15]}}, audio16_l[15:2] }:
    (system_volume == 2'd2)?{ audio16_l[15], audio16_l[15:1] }:
    audio16_l;

wire [15:0] audio_vol_r = 
    (system_volume == 2'd0)?16'd0:
    (system_volume == 2'd1)?{ {2{audio16_r[15]}}, audio16_r[15:2] }:
    (system_volume == 2'd2)?{ audio16_r[15], audio16_r[15:1] }:
    audio16_r;

wire vreset;
reg  HSync, VSync, vbl_gen;
wire [1:0] vmode;

video_analyzer video_analyzer (
   .clk(clk),
   .vs(sd_vs_n),
   .hs(sd_hs_n),
   .de(de_in),
   .screen(system_screen),
   .ntscmode(1'b1),
   .mode(vmode),
   .vreset(vreset)
);

wire VBlank = vblank_regenerate ? vbl_gen:vb_stab;
reg [7:0] adaptive_ary = 8'd108;
wire [7:0] vertical_ar_lut[256] = '{
	8'h00, 8'h01, 8'h01, 8'h02, 8'h02, 8'h03, 8'h03, 8'h04,
	8'h05, 8'h05, 8'h06, 8'h06, 8'h07, 8'h07, 8'h08, 8'h08,
	8'h09, 8'h0A, 8'h0A, 8'h0B, 8'h0B, 8'h0C, 8'h0C, 8'h0D,
	8'h0E, 8'h0E, 8'h0F, 8'h0F, 8'h10, 8'h10, 8'h11, 8'h11,
	8'h12, 8'h13, 8'h13, 8'h14, 8'h14, 8'h15, 8'h15, 8'h16,
	8'h17, 8'h17, 8'h18, 8'h18, 8'h19, 8'h19, 8'h1A, 8'h1A,
	8'h1B, 8'h1C, 8'h1C, 8'h1D, 8'h1D, 8'h1E, 8'h1E, 8'h1F,
	8'h1F, 8'h20, 8'h21, 8'h21, 8'h22, 8'h22, 8'h23, 8'h23,
	8'h24, 8'h25, 8'h25, 8'h26, 8'h26, 8'h27, 8'h27, 8'h28,
	8'h28, 8'h29, 8'h2A, 8'h2A, 8'h2B, 8'h2B, 8'h2C, 8'h2C,
	8'h2D, 8'h2E, 8'h2E, 8'h2F, 8'h2F, 8'h30, 8'h30, 8'h31,
	8'h31, 8'h32, 8'h33, 8'h33, 8'h34, 8'h34, 8'h35, 8'h35,
	8'h36, 8'h37, 8'h37, 8'h38, 8'h38, 8'h39, 8'h39, 8'h3A,
	8'h3B, 8'h3B, 8'h3C, 8'h3C, 8'h3D, 8'h3D, 8'h3E, 8'h3E,
	8'h3F, 8'h40, 8'h40, 8'h41, 8'h41, 8'h42, 8'h42, 8'h43,
	8'h44, 8'h44, 8'h45, 8'h45, 8'h46, 8'h46, 8'h47, 8'h47,
	8'h48, 8'h49, 8'h49, 8'h4A, 8'h4A, 8'h4B, 8'h4B, 8'h4C,
	8'h4D, 8'h4D, 8'h4E, 8'h4E, 8'h4F, 8'h4F, 8'h50, 8'h50,
	8'h51, 8'h52, 8'h52, 8'h53, 8'h53, 8'h54, 8'h54, 8'h55,
	8'h56, 8'h56, 8'h57, 8'h57, 8'h58, 8'h58, 8'h59, 8'h59,
	8'h5A, 8'h5B, 8'h5B, 8'h5C, 8'h5C, 8'h5D, 8'h5D, 8'h5E,
	8'h5E, 8'h5F, 8'h60, 8'h60, 8'h61, 8'h61, 8'h62, 8'h62,
	8'h63, 8'h64, 8'h64, 8'h65, 8'h65, 8'h66, 8'h66, 8'h67,
	8'h68, 8'h68, 8'h69, 8'h69, 8'h6A, 8'h6A, 8'h6B, 8'h6B,
	8'h6C, 8'h6D, 8'h6D, 8'h6E, 8'h6E, 8'h6F, 8'h6F, 8'h70,
	8'h71, 8'h71, 8'h72, 8'h72, 8'h73, 8'h73, 8'h74, 8'h74,
	8'h75, 8'h76, 8'h76, 8'h77, 8'h77, 8'h78, 8'h78, 8'h79,
	8'h7A, 8'h7A, 8'h7B, 8'h7B, 8'h7C, 8'h7C, 8'h7D, 8'h7D,
	8'h7E, 8'h7F, 8'h7F, 8'h80, 8'h80, 8'h81, 8'h81, 8'h82,
	8'h83, 8'h83, 8'h84, 8'h84, 8'h85, 8'h85, 8'h86, 8'h86,
	8'h87, 8'h88, 8'h88, 8'h89, 8'h89, 8'h8A, 8'h8A, 8'h8B,
	8'h8C, 8'h8C, 8'h8D, 8'h8D, 8'h8E, 8'h8E, 8'h8F, 8'h8F
};

always @(posedge clk) begin
	reg [8:0] line_cnt, vblank_start, visible_cnt;

	HSync <= hs_in_n;
	if(~HSync & hs_in_n) begin
		VSync <= vs_stab;
		line_cnt <= line_cnt + 1'b1;
		if (~VBlank)
			visible_cnt <= visible_cnt + 1'b1;

		if (~VSync & vs_stab) begin
			line_cnt <= 0;
			visible_cnt <= 0;
			if (visible_cnt < 255)
				adaptive_ary <= vertical_ar_lut[visible_cnt[7:0]];
			else
				adaptive_ary <= vertical_ar_lut[255];

			vblank_start <= line_cnt - 9'd25;
		end

		if (line_cnt == vblank_start) begin
			vbl_gen <= 1'b1;
		end

		if (line_cnt == 9'd34) begin
			vbl_gen <= 0;
		end
	end
end


wire [5:0] sd_r;
wire [5:0] sd_g;
wire [5:0] sd_b;

// Timing do scandoubler: restaurado ao original (video_stabilize)
// Pixels: frame_buffer (banco SDRAM anterior = 1 frame de atraso)
scandoubler #(10) scandoubler (
        // system interface
        .clk_sys(clk),
        .bypass(1'b0),
        .ce_divider(3'd1),
        .pixel_ena(),

        // scanlines (00-none 01-25% 10-50% 11-75%)
        .scanlines(system_scanlines),

        // Timing: ORIGINAL (video_stabilize) — inalterado
        .hb_in(hb_in),
        .vb_in(VBlank),
        .hs_in(hs_in_n),
        .vs_in(vs_stab),
        // Pixels: frame_buffer (bypass → TIA direto; normal → SDRAM)
        .r_in(fb_rd_r[7:4]),
        .g_in(fb_rd_g[7:4]),
        .b_in(fb_rd_b[7:4]),

        // output interface
        .hb_out(),
        .vb_out(),
        .hs_out(sd_hs_n),
        .vs_out(sd_vs_n),
        .r_out(sd_r),
        .g_out(sd_g),
        .b_out(sd_b)
);

wire [5:0] osd_r;
wire [5:0] osd_g;
wire [5:0] osd_b;  

osd_u8g2 osd_u8g2 (
        .clk(clk),
        .reset(!pll_lock),

        .data_in_strobe(mcu_osd_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data),

        .hs(sd_hs_n),
        .vs(sd_vs_n),
		     
        .r_in(sd_r),
        .g_in(sd_g),
        .b_in(sd_b),
		     
        .r_out(osd_r),
        .g_out(osd_g),
        .b_out(osd_b),
        .osd_status(osd_status)
);   

wire [2:0] tmds;
wire tmds_clock;

hdmi #(
   .AUDIO_RATE(48000), 
   .AUDIO_BIT_WIDTH(16),
   .VENDOR_NAME( { "MiSTle", 16'd0} ),
   .PRODUCT_DESCRIPTION( {"A2600", 64'd0} )
) hdmi(
  .clk_pixel_x5(clk_pixel_x5),
  .clk_pixel(clk),
  .clk_audio(clk_audio),
  .audio_sample_word( { audio_vol_l, audio_vol_r } ),
  .tmds(tmds),
  .tmds_clock(tmds_clock),

  // video input
  .stmode(vmode),    // current video mode PAL/NTSC/MONO
  .screen(system_screen),
  .total_lines(total_lines),
  .reset(vreset),    // signal to synchronize HDMI
  // Atari STE outputs 4 bits per color. Scandoubler outputs 6 bits (to be
  // able to implement dark scanlines) and HDMI expects 8 bits per color
  .rgb( { osd_r, 2'b00, osd_g, 2'b00, osd_b, 2'b00 } )
);

// differential output
ELVDS_OBUF tmds_bufds [3:0] (
        .I({tmds_clock, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
);

endmodule
