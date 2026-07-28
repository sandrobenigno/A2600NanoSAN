// frame_buffer.sv  — ping-pong SDRAM frame buffer, A2600 Tang Nano 20K
//
// Problema anterior: reads SDRAM pixel-a-pixel causavam 6 ciclos de preto
// para cada 2 pixels (latência SDRAM = 5 ciclos >> 1 pixel TIA = 8 ciclos).
//
// Solução: LINE BUFFER (BRAM interno, 128×32-bit = 160 pixels/linha)
//   • Durante hblank (~547 ciclos): pré-buscar linha da SDRAM → BRAM
//     (80 words × 5 ciclos = 400 ciclos, cabe no hblank com folga)
//   • Durante vídeo ativo: ler da BRAM com latência 1 ciclo (zero stalls)
//   • SDRAM pode drenar o write FIFO livremente durante o vídeo ativo
//
// Endereçamento SDRAM (banco em addr[9:8], linha em addr[20:10], col em addr[7:0]):
//   addr = (bank<<8) | (line<<10) | word_col
//   Stride de banco = 256, stride de linha = 1024, max 80 palavras/linha

module frame_buffer (
    input           clk,
    input           resetn,
    input           bypass,

    // TIA input (write side)
    input           wr_hsync,
    input           wr_vsync,
    input           wr_hblank,
    input           wr_vblank,
    input  [7:0]    wr_r, wr_g, wr_b,
    input           pal,

    // Scandoubler output (read side)
    output reg      rd_hsync,
    output reg      rd_vsync,
    output reg      rd_hblank,
    output reg      rd_vblank,
    output reg [7:0] rd_r, rd_g, rd_b,

    // SDRAM controller interface — todos outputs driven por UM único always block
    output reg        sdram_rd,
    output reg        sdram_wr,
    output reg        sdram_refresh,
    output reg [22:0] sdram_addr,
    output reg [31:0] sdram_din,
    input  [31:0]     sdram_dout,
    input             sdram_data_ready,
    input             sdram_busy
);

// ============================================================
// Parâmetros
// ============================================================
localparam [9:0] NTSC_LINES = 10'd262;
localparam [9:0] PAL_LINES  = 10'd312;
localparam [6:0] WORDS_PER_LINE = 7'd80;  // 160 pixels / 2 por palavra

// Endereço SDRAM: bank<<8 | line<<10 | word
function automatic [22:0] make_addr;
    input        bank;
    input [9:0]  line;
    input [7:0]  word;
    // bank  → bit[8]      (stride 256)
    // line  → bits[18:10] (stride 1024)
    // word  → bits[7:0]
    make_addr = {4'b0, line, 9'b0} | {14'b0, bank, 8'b0} | {15'b0, word};
endfunction

// ============================================================
// Line buffer — BRAM 128×32 (inferência automática pelo Gowin)
// ============================================================
reg [31:0] line_buf [0:127];

// Porta de escrita (árbitro → BRAM, durante pré-fetch)
reg [6:0]  lb_waddr;
reg [31:0] lb_wdat;
reg        lb_wen;
always @(posedge clk) begin
    if (lb_wen) line_buf[lb_waddr] <= lb_wdat;
end

// Porta de leitura síncrona (1 ciclo de latência — zero stalls a 28.8 MHz)
reg [6:0]  lb_raddr;
reg [31:0] lb_rdat;
always @(posedge clk) lb_rdat <= line_buf[lb_raddr];

// ============================================================
// Detecção de borda
// ============================================================
reg wr_hblank_d, wr_vsync_d;
wire wr_hblank_rise = !wr_hblank_d &&  wr_hblank;   // fim do vídeo ativo / início hblank
wire wr_hblank_fall =  wr_hblank_d && !wr_hblank;   // início do vídeo ativo
wire wr_vsync_rise  = !wr_vsync_d  &&  wr_vsync;

// ============================================================
// Write side: TIA → FIFO → árbitro SDRAM
// ============================================================
reg [9:0]  wr_lcnt;
reg [6:0]  wr_wcnt;
reg [11:0] wr_odd_pixel;
reg        wr_has_odd;
reg [9:0]  frame_height;      // altura do frame anterior
reg [9:0]  frame_height_cnt;
reg        frame_valid;        // 1 após o primeiro vsync completo
reg        bank_wr;            // banco de escrita atual

function automatic [11:0] pack_px;
    input [7:0] r, g, b;
    pack_px = {r[7:4], g[7:4], b[7:4]};
endfunction

// Write FIFO (4 entradas × 32-bit dado + 23-bit addr)
localparam FDEPTH = 4;
localparam FBITS  = 2;
reg [31:0] wf_dat  [FDEPTH-1:0];
reg [22:0] wf_addr [FDEPTH-1:0];
reg [FBITS-1:0] wf_wptr, wf_rptr;
wire wf_empty = (wf_wptr == wf_rptr);
wire wf_full  = (wf_wptr - wf_rptr == FBITS'(FDEPTH));

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        wr_hblank_d      <= 1;
        wr_vsync_d       <= 0;
        wr_lcnt          <= 0;
        wr_wcnt          <= 0;
        wr_has_odd       <= 0;
        wr_odd_pixel     <= 0;
        bank_wr          <= 0;
        frame_height     <= NTSC_LINES;
        frame_height_cnt <= 0;
        frame_valid      <= 0;
        wf_wptr          <= 0;
    end else begin
        wr_hblank_d <= wr_hblank;
        wr_vsync_d  <= wr_vsync;

        if (!bypass) begin
            if (wr_vsync_rise) begin
                frame_height     <= frame_height_cnt;
                frame_height_cnt <= 0;
                wr_lcnt          <= 0;
                bank_wr          <= ~bank_wr;
                wr_has_odd       <= 0;
                frame_valid      <= 1;
            end

            if (wr_hblank_rise) begin
                if (wr_has_odd && !wf_full) begin
                    wf_dat [wf_wptr] <= {12'b0, 4'b0, wr_odd_pixel, 4'b0};
                    wf_addr[wf_wptr] <= make_addr(bank_wr, wr_lcnt, {1'b0, wr_wcnt});
                    wf_wptr    <= wf_wptr + 1;
                    wr_has_odd <= 0;
                end
                wr_lcnt          <= wr_lcnt + 1;
                frame_height_cnt <= frame_height_cnt + 1;
                wr_wcnt          <= 0;
            end

            if (!wr_hblank && !wr_vblank && !wf_full) begin
                if (!wr_has_odd) begin
                    wr_odd_pixel <= pack_px(wr_r, wr_g, wr_b);
                    wr_has_odd   <= 1;
                end else begin
                    wf_dat [wf_wptr] <= {
                        pack_px(wr_r, wr_g, wr_b), 4'b0,
                        wr_odd_pixel, 4'b0
                    };
                    wf_addr[wf_wptr] <= make_addr(bank_wr, wr_lcnt, {1'b0, wr_wcnt});
                    wf_wptr    <= wf_wptr + 1;
                    wr_wcnt    <= wr_wcnt + 1;
                    wr_has_odd <= 0;
                end
            end
        end
    end
end

// ============================================================
// Read side: line_buf → scandoubler
// (linha pre-buscada durante hblank pelo árbitro)
// ============================================================
reg [9:0]  rd_lcnt;
reg [9:0]  rd_frame_height;
reg [9:0]  rd_total_lines;
reg        bank_swap_d;
reg        rd_hblank_d_out;   // edge detect para saída
reg [7:0]  rd_pixel_cnt;      // posição dentro da linha ativa

// Parâmetros latched na troca de banco
always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        bank_swap_d    <= 0;
        rd_frame_height<= NTSC_LINES;
        rd_total_lines <= NTSC_LINES;
    end else begin
        bank_swap_d <= wr_vsync_rise;
        if (bank_swap_d && frame_valid && !bypass) begin
            rd_frame_height <= frame_height;
            rd_total_lines  <= pal ? PAL_LINES : NTSC_LINES;
        end
    end
end

// Saída de pixel a partir da BRAM:
// • lb_raddr é incrementado a cada 2 pixels (1 word = 2 pixels)
// • lb_rdat disponível 1 ciclo após lb_raddr, portanto adiantamos 1 ciclo

reg [7:0]  rd_vis_cnt;    // contador de pixel visível na linha (0..159)
reg        rd_pixel_sel;  // 0=par (bits[15:4]), 1=ímpar (bits[31:20])
reg        rd_active;     // 1 = estamos na região ativa

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        rd_hblank_d_out <= 1;
        rd_lcnt         <= 0;
        rd_vis_cnt      <= 0;
        rd_pixel_cnt    <= 0;
        rd_pixel_sel    <= 0;
        rd_active       <= 0;
        lb_raddr        <= 0;
        rd_hsync        <= 0;
        rd_vsync        <= 0;
        rd_hblank       <= 1;
        rd_vblank       <= 1;
        rd_r <= 0; rd_g <= 0; rd_b <= 0;
    end else if (bypass || !frame_valid) begin
        rd_hsync  <= wr_hsync;
        rd_vsync  <= wr_vsync;
        rd_hblank <= wr_hblank;
        rd_vblank <= wr_vblank;
        rd_r <= wr_r; rd_g <= wr_g; rd_b <= wr_b;
        rd_active <= 0;
    end else begin
        rd_hblank_d_out <= wr_hblank;
        rd_hsync        <= wr_hsync;

        // ---- Início do vídeo ativo ----
        if (rd_hblank_d_out && !wr_hblank) begin
            rd_vis_cnt   <= 0;
            rd_pixel_sel <= 0;
            lb_raddr     <= 0;
            rd_active    <= 1;
        end

        // ---- Fim do vídeo ativo / início do hblank ----
        if (!rd_hblank_d_out && wr_hblank) begin
            rd_active <= 0;
            rd_lcnt   <= rd_lcnt + 1;

            if (rd_lcnt + 1 >= rd_frame_height)
                rd_vblank <= 1;

            if (rd_lcnt + 1 >= rd_total_lines) begin
                rd_lcnt   <= 0;
                rd_vblank <= 1;
                rd_vsync  <= 1;
            end
            if (rd_lcnt == 3)  rd_vsync  <= 0;
            if (rd_lcnt == 10) rd_vblank <= 0;
        end

        // ---- Saída de pixel ativo ----
        if (rd_active && !rd_vblank) begin
            rd_hblank <= 0;

            // Adiantamos lb_raddr em 1 ciclo para compensar latência BRAM
            if (!rd_pixel_sel) begin
                // Próxima leitura: pré-carregar endereço par
                lb_raddr <= {1'b0, rd_vis_cnt[7:1]};   // word = vis_cnt / 2
            end

            // Saída do pixel atual a partir de lb_rdat (válido 1 ciclo após lb_raddr)
            if (!rd_pixel_sel) begin
                // Pixel par: bits[15:4]
                rd_r <= {lb_rdat[15:12], lb_rdat[15:12]};
                rd_g <= {lb_rdat[11:8],  lb_rdat[11:8]};
                rd_b <= {lb_rdat[7:4],   lb_rdat[7:4]};
            end else begin
                // Pixel ímpar: bits[31:20]
                rd_r <= {lb_rdat[31:28], lb_rdat[31:28]};
                rd_g <= {lb_rdat[27:24], lb_rdat[27:24]};
                rd_b <= {lb_rdat[23:20], lb_rdat[23:20]};
            end

            rd_pixel_sel <= ~rd_pixel_sel;
            rd_vis_cnt   <= rd_vis_cnt + 1;
        end else if (!rd_active) begin
            rd_hblank <= 1;
            rd_r <= 0; rd_g <= 0; rd_b <= 0;
        end
    end
end

// ============================================================
// Árbitro SDRAM unificado — ÚNICO driver de todos os outputs SDRAM
//
// Durante hblank: prioridade para pré-fetch linha → BRAM
//   (80 words × 5 ciclos = 400 ciclos << hblank ≈ 547 ciclos)
// Durante vídeo ativo: drena write FIFO; nenhum read necessário
// ============================================================
localparam REFRESH_PERIOD = 10'd430;
reg [9:0] refresh_cnt;
reg       refresh_due;

// Fetch state machine
localparam FETCH_IDLE  = 2'd0;
localparam FETCH_REQ   = 2'd1;
localparam FETCH_WAIT  = 2'd2;
localparam FETCH_DONE  = 2'd3;

reg [1:0] fetch_state;
reg [6:0] fetch_wcnt;      // palavra atual do fetch (0..79)
reg       fetch_active;    // 1 = hblank, modo fetch
reg [9:0] fetch_line;      // rd_lcnt no momento em que o fetch começa

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        sdram_rd      <= 0;
        sdram_wr      <= 0;
        sdram_refresh <= 0;
        sdram_addr    <= 0;
        sdram_din     <= 0;
        refresh_cnt   <= 0;
        refresh_due   <= 0;
        wf_rptr       <= 0;
        lb_wen        <= 0;
        lb_waddr      <= 0;
        lb_wdat       <= 0;
        fetch_state   <= FETCH_IDLE;
        fetch_wcnt    <= 0;
        fetch_active  <= 0;
        fetch_line    <= 0;
    end else begin
        sdram_rd      <= 0;
        sdram_wr      <= 0;
        sdram_refresh <= 0;
        lb_wen        <= 0;

        // Refresh timer
        refresh_cnt <= refresh_cnt + 1;
        if (refresh_cnt == REFRESH_PERIOD) begin
            refresh_cnt <= 0;
            refresh_due <= 1;
        end

        // Latch dado SDRAM → BRAM quando pronto
        if (sdram_data_ready) begin
            lb_wdat  <= sdram_dout;
            lb_waddr <= fetch_wcnt - 1; // -1 porque fetch_wcnt avançou no ciclo anterior
            lb_wen   <= 1;
        end

        // Detectar início/fim do hblank para controle do fetch
        if (!bypass && frame_valid) begin
            // Início do hblank: iniciar pré-fetch da PRÓXIMA linha (rd_lcnt após incremento)
            if (!rd_hblank_d_out && wr_hblank && !rd_vblank) begin
                fetch_active <= 1;
                fetch_wcnt   <= 0;
                fetch_state  <= FETCH_IDLE;
                // fetch_line = rd_lcnt+1 (linha que será exibida na próxima active)
                // Na verdade, rd_lcnt já será incrementado pelo read SM no mesmo ciclo.
                // Usamos rd_lcnt+1 explicitamente:
                fetch_line   <= rd_lcnt + 1;
            end

            // Fim do hblank: desabilitar fetch
            if (rd_hblank_d_out && !wr_hblank)
                fetch_active <= 0;
        end

        // Árbitro principal
        if (!sdram_busy) begin
            if (refresh_due) begin
                // P1: refresh
                sdram_refresh <= 1;
                refresh_due   <= 0;
            end else if (fetch_active && fetch_state != FETCH_DONE) begin
                // P2 (durante hblank): pré-fetch linha para BRAM
                case (fetch_state)
                    FETCH_IDLE: begin
                        if (fetch_wcnt < WORDS_PER_LINE) begin
                            sdram_addr  <= make_addr(~bank_wr, fetch_line, {1'b0, fetch_wcnt});
                            sdram_rd    <= 1;
                            fetch_state <= FETCH_WAIT;
                        end else begin
                            fetch_state <= FETCH_DONE;
                        end
                    end
                    FETCH_WAIT: begin
                        // Esperar data_ready (tratado acima com lb_wen)
                        if (sdram_data_ready) begin
                            fetch_wcnt  <= fetch_wcnt + 1;
                            fetch_state <= FETCH_IDLE;
                        end
                    end
                    default: ;
                endcase
            end else if (!wf_empty) begin
                // P3: drenar write FIFO
                sdram_addr <= wf_addr[wf_rptr];
                sdram_din  <= wf_dat [wf_rptr];
                sdram_wr   <= 1;
                wf_rptr    <= wf_rptr + 1;
            end
        end else begin
            // Quando busy: se chegou data_ready, avançar fetch
            if (sdram_data_ready && fetch_state == FETCH_WAIT) begin
                fetch_wcnt  <= fetch_wcnt + 1;
                fetch_state <= FETCH_IDLE;
            end
        end
    end
end

endmodule
