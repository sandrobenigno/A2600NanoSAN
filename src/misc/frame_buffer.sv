// frame_buffer.sv  — SOMENTE buffer de pixels (sem geração de timing)
//
// ARQUITETURA REVISADA:
//   • O frame_buffer NÃO gera vsync/vblank/hblank — isso fica com video_stabilize
//   • O frame_buffer apenas armazena pixels na SDRAM (frame anterior) e
//     os fornece ao scandoubler no timing correto
//   • Toda a lógica de timing (OSD, áudio, scandoubler) permanece inalterada
//
// INTERFACE:
//   WRITE SIDE: pixels do TIA → SDRAM (banco atual)
//   READ SIDE:  SDRAM (banco anterior) → pixels para o scandoubler
//     - rd_vblank_in: de video_stabilize (indica quando estamos no blanking)
//     - rd_r/g/b: pixels de saída (apenas cor, sem timing)
//
// rd_lcnt e wr_lcnt são contadores de linha absolutos desde o último vsync.
// SDRAM address = make_addr(bank, lcnt, wcnt).
// Linhas fora do frame gravado retornam preto (dados nunca escritos).
//
// LINE BUFFER:
//   BRAM 128×32 bits. Pré-carregada durante hblank (~400 ciclos < 547 do hblank).
//   Lida durante vídeo ativo com latência 1 ciclo (compensada pelo pré-endereçamento).
//
// TAXA DE PIXEL:
//   clk=28.8 MHz, pixel TIA=3.6 MHz → 8 ciclos/pixel, 16 ciclos/par (1 palavra).

module frame_buffer (
    input           clk,
    input           clk_cpu,
    input           resetn,
    input           bypass,     // 1 = passa TIA direto (durante cart_download)

    // TIA write side
    input           wr_vsync,   // vsync TIA (active-high)
    input           wr_hblank,  // hblank TIA
    input           wr_vblank,  // vblank TIA
    input  [7:0]    wr_r, wr_g, wr_b,
    input           pal,

    // Read side — timing externo (de video_stabilize via video.v)
    input           rd_hblank_in,  // hblank TIA (passado diretamente)
    input           rd_vblank_in,  // vblank estabilizado (de video_stabilize)

    // Saída de pixel (apenas cor — sem timing)
    output reg [7:0] rd_r, rd_g, rd_b,

    // SDRAM (único driver abaixo)
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
// Constantes e endereçamento
// ============================================================
localparam [6:0]  WORDS_PER_LINE = 7'd80;   // 160 pixels / 2
localparam [9:0]  REFRESH_PERIOD = 10'd430;

// addr = (bank<<8) | (line<<10) | word
// bank:  bit[8]      (stride    256 = 2^8)
// line:  bits[19:10] (stride   1024 = 2^10)
// word:  bits[7:0]   (stride      1)
function automatic [22:0] make_addr;
    input        bank;
    input [9:0]  line;
    input [7:0]  word;
    make_addr = {3'b0, line, 10'b0} | {14'b0, bank, 8'b0} | {15'b0, word};
endfunction

// ============================================================
// Line buffer BRAM 128×32 (inferência automática)
// ============================================================
reg [31:0] line_buf [0:127];
reg [6:0]  lb_waddr;
reg [31:0] lb_wdat;
reg        lb_wen;
reg [6:0]  lb_raddr;
reg [31:0] lb_rdat;

always @(posedge clk) begin
    if (lb_wen) line_buf[lb_waddr] <= lb_wdat;
    lb_rdat <= line_buf[lb_raddr];  // leitura síncrona: latência 1 ciclo
end

// ============================================================
// Detecção de borda
// ============================================================
reg wr_hblank_d, wr_vsync_d, rd_hblank_d;
wire wr_hblank_rise = !wr_hblank_d && wr_hblank;
wire wr_vsync_rise  = !wr_vsync_d  && wr_vsync;
wire rd_hblank_fall =  rd_hblank_d && !rd_hblank_in; // início do vídeo ativo
wire rd_hblank_rise = !rd_hblank_d &&  rd_hblank_in; // início do hblank

// ============================================================
// WRITE SIDE: TIA → write FIFO → árbitro SDRAM
// ============================================================
reg [9:0]  wr_lcnt;
reg [6:0]  wr_wcnt;
reg [11:0] wr_odd_pixel;
reg        wr_has_odd;
reg        bank_wr;
reg        frame_valid;
reg [2:0]  wr_tick;

// Line tracking registers for vertical crop (eliminates bottom/top noise)
reg [9:0]  wr_line_min, wr_line_max;
reg [9:0]  wr_line_min_next, wr_line_max_next;

function automatic [11:0] pack_px;
    input [7:0] r, g, b;
    pack_px = {r[7:4], g[7:4], b[7:4]};
endfunction

localparam FDEPTH = 4;
localparam FBITS  = 3; // 3 bits to distinguish full vs empty with FDEPTH=4
reg [31:0] wf_dat  [FDEPTH-1:0];
reg [22:0] wf_addr [FDEPTH-1:0];
reg [FBITS-1:0] wf_wptr, wf_rptr;
wire wf_empty = (wf_wptr == wf_rptr);
wire wf_full  = (wf_wptr - wf_rptr == 3'd4);

reg        clk_cpu_d;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        clk_cpu_d    <= 0;
        wr_hblank_d  <= 1;
        wr_vsync_d   <= 0;
        wr_lcnt      <= 0;
        wr_wcnt      <= 0;
        wr_has_odd   <= 0;
        wr_odd_pixel <= 0;
        bank_wr      <= 0;
        frame_valid  <= 0;
        wf_wptr      <= 0;
        wr_tick      <= 0;
        wr_line_min  <= 0;
        wr_line_max  <= 0;
        wr_line_min_next <= 10'h3FF;
        wr_line_max_next <= 0;
    end else begin
        clk_cpu_d <= clk_cpu;

        // Reset wr_tick on the rising edge of clk_cpu (3.6 MHz color clock divider)
        // to lock phase with the TIA clock. Since clk_cpu is generated by CLKDIV,
        // it is completely jitter-free and eliminates HMOVE horizontal ripple.
        if (!clk_cpu_d && clk_cpu) begin
            wr_tick <= 0;
        end else begin
            wr_tick <= wr_tick + 1;
        end

        wr_hblank_d <= wr_hblank;
        wr_vsync_d  <= wr_vsync;

        if (!bypass) begin
            if (wr_vsync_rise) begin
                wr_lcnt     <= 0;
                bank_wr     <= ~bank_wr;
                wr_has_odd  <= 0;
                frame_valid <= 1;
                wr_line_min <= wr_line_min_next;
                wr_line_max <= wr_line_max_next;
                wr_line_min_next <= 10'h3FF;
                wr_line_max_next <= 0;
            end

            if (wr_hblank_rise) begin
                if (wr_has_odd && !wf_full) begin
                    wf_dat [wf_wptr[1:0]] <= {12'b0, 4'b0, wr_odd_pixel, 4'b0};
                    wf_addr[wf_wptr[1:0]] <= make_addr(bank_wr, wr_lcnt, {1'b0, wr_wcnt});
                    wf_wptr    <= wf_wptr + 1;
                    wr_has_odd <= 0;
                end
                
                // Latch actual active screen boundaries (where wr_vblank was low during the line)
                if (!wr_vblank) begin
                    if (wr_line_min_next == 10'h3FF)
                        wr_line_min_next <= wr_lcnt;
                    wr_line_max_next <= wr_lcnt;
                end
                
                wr_lcnt <= wr_lcnt + 1;
                wr_wcnt <= 0;
            end

            if (!wr_hblank && !wr_vblank) begin
                // Sample at a stable phase (3'd7) of the 8-cycle TIA pixel period
                if (wr_tick == 3'd7 && !wf_full && wr_wcnt < WORDS_PER_LINE) begin
                    if (!wr_has_odd) begin
                        wr_odd_pixel <= pack_px(wr_r, wr_g, wr_b);
                        wr_has_odd   <= 1;
                    end else begin
                        wf_dat [wf_wptr[1:0]] <= {
                            pack_px(wr_r, wr_g, wr_b), 4'b0,
                            wr_odd_pixel, 4'b0
                        };
                        wf_addr[wf_wptr[1:0]] <= make_addr(bank_wr, wr_lcnt, {1'b0, wr_wcnt});
                        wf_wptr    <= wf_wptr + 1;
                        wr_wcnt    <= wr_wcnt + 1;
                        wr_has_odd <= 0;
                    end
                end
            end
        end
    end
end

// ============================================================
// READ SIDE: BRAM → scandoubler (somente pixels)
// rd_lcnt: linha absoluta desde o último vsync TIA
//   reset em wr_vsync_rise, incremento em rd_hblank_rise
// ============================================================
reg [9:0]  rd_lcnt;
reg        rd_active;
reg [3:0]  pclk_div;   // 0..15: 0..7=pixel par, 8..15=pixel ímpar
reg [6:0]  rd_wcnt;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        rd_hblank_d <= 1;
        rd_lcnt     <= 0;
        rd_active   <= 0;
        pclk_div    <= 0;
        rd_wcnt     <= 0;
        lb_raddr    <= 0;
        rd_r <= 0; rd_g <= 0; rd_b <= 0;
    end else if (bypass || !frame_valid) begin
        // Bypass ou 1º frame: passa TIA diretamente
        rd_hblank_d <= rd_hblank_in;
        rd_active   <= 0;
        rd_r <= wr_r; rd_g <= wr_g; rd_b <= wr_b;
    end else begin
        rd_hblank_d <= rd_hblank_in;

        // Reset linha ao vsync TIA
        if (wr_vsync_rise) begin
            rd_lcnt  <= 0;
            rd_active<= 0;
        end

        // Início do hblank: avança linha
        if (rd_hblank_rise && !wr_vsync_rise)
            rd_lcnt <= rd_lcnt + 1;

        // Início do vídeo ativo
        if (rd_hblank_fall && !rd_vblank_in) begin
            rd_active <= 1;
            pclk_div  <= 0;
            rd_wcnt   <= 0;
            lb_raddr  <= 0;  // BRAM pronto 1 ciclo depois (latência compensada abaixo)
        end

        // Início do hblank: pré-carrega lb_raddr=0 para que lb_rdat já
        // tenha line_buf[0] pronto antes do primeiro pixel ativo
        if (rd_hblank_rise) begin
            rd_active <= 0;
            lb_raddr  <= 0;
        end

        // Saída de pixel — somente durante região ativa
        if (rd_active && !rd_vblank_in) begin
            pclk_div <= pclk_div + 1;

            if (pclk_div == 4'd15) begin
                pclk_div <= 0;
                rd_wcnt  <= rd_wcnt + 1;
                if (rd_wcnt < WORDS_PER_LINE - 1)
                    lb_raddr <= rd_wcnt + 1;
            end

            // Se a linha ou coluna atual estiver fora do intervalo gravado do frame anterior, força preto
            if (rd_lcnt < wr_line_min || rd_lcnt > wr_line_max || rd_wcnt >= WORDS_PER_LINE) begin
                rd_r <= 0; rd_g <= 0; rd_b <= 0;
            end else if (!pclk_div[3]) begin
                rd_r <= {lb_rdat[15:12], lb_rdat[15:12]};
                rd_g <= {lb_rdat[11:8],  lb_rdat[11:8]};
                rd_b <= {lb_rdat[7:4],   lb_rdat[7:4]};
            end else begin
                rd_r <= {lb_rdat[31:28], lb_rdat[31:28]};
                rd_g <= {lb_rdat[27:24], lb_rdat[27:24]};
                rd_b <= {lb_rdat[23:20], lb_rdat[23:20]};
            end
        end else if (!rd_active || rd_vblank_in) begin
            rd_r <= 0; rd_g <= 0; rd_b <= 0;
        end
    end
end

// ============================================================
// ÁRBITRO SDRAM — único driver de todos os outputs SDRAM
// Durante hblank: pré-fetch linha rd_lcnt → BRAM (prioridade)
// Durante ativo: drena write FIFO
// Fetch reiniciado a cada hblank_rise (abandona fetch parcial de linha anterior)
// ============================================================
reg [9:0]  refresh_cnt;
reg        refresh_due;

localparam FETCH_IDLE = 2'd0;
localparam FETCH_WAIT = 2'd1;
localparam FETCH_DONE = 2'd2;

reg [1:0]  fetch_state;
reg [6:0]  fetch_wcnt;
reg        fetch_active;
reg [9:0]  fetch_line;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        sdram_rd       <= 0; sdram_wr      <= 0;
        sdram_refresh  <= 0; sdram_addr    <= 0;
        sdram_din      <= 0; refresh_cnt   <= 0;
        refresh_due    <= 0; wf_rptr       <= 0;
        lb_wen         <= 0; lb_waddr      <= 0;
        lb_wdat        <= 0; fetch_state   <= FETCH_IDLE;
        fetch_wcnt     <= 0; fetch_active  <= 0;
        fetch_line     <= 0;
    end else begin
        sdram_rd      <= 0; sdram_wr      <= 0;
        sdram_refresh <= 0; lb_wen        <= 0;

        // Refresh timer
        refresh_cnt <= refresh_cnt + 1;
        if (refresh_cnt == REFRESH_PERIOD) begin
            refresh_cnt <= 0;
            refresh_due <= 1;
        end

        // Início de hblank: (re)inicia fetch para a linha ATUAL (rd_lcnt)
        // Nota: rd_lcnt é lido ANTES do incremento pelo read SM (mesma aresta)
        // Após o incremento, rd_lcnt_NEW = rd_lcnt_OLD + 1
        // Queremos fetch da linha rd_lcnt_NEW (que será exibida neste hblank)
        if (rd_hblank_rise && frame_valid && !bypass) begin
            fetch_active    <= 1;
            fetch_wcnt      <= 0;
            fetch_state     <= FETCH_IDLE;
            // rd_lcnt ainda não foi incrementado (nonblocking no outro always).
            // rd_lcnt_NEW = rd_lcnt + 1 (exceto no vsync, mas vsync e hblank_rise
            // não ocorrem simultaneamente em condições normais)
            fetch_line <= rd_lcnt + 1;
        end

        // Vsync: fetch linha 0 para estar pronto antes do primeiro ativo
        if (wr_vsync_rise && frame_valid && !bypass) begin
            fetch_active    <= 1;
            fetch_wcnt      <= 0;
            fetch_state     <= FETCH_IDLE;
            fetch_line      <= 0;
        end

        // Latch dado SDRAM → BRAM (ocorre com busy ainda=1)
        if (sdram_data_ready && fetch_state == FETCH_WAIT) begin
            lb_wdat  <= sdram_dout;
            lb_waddr <= fetch_wcnt; // valor atual (NÃO incrementado ainda)
            lb_wen   <= 1;
        end

        // Árbitro principal
        if (!sdram_busy) begin
            if (refresh_due) begin
                sdram_refresh <= 1;
                refresh_due   <= 0;
            end else if (fetch_active && fetch_state != FETCH_DONE) begin
                case (fetch_state)
                    FETCH_IDLE: begin
                        if (fetch_wcnt < WORDS_PER_LINE) begin
                            sdram_addr  <= make_addr(~bank_wr, fetch_line, {1'b0, fetch_wcnt});
                            sdram_rd    <= 1;
                            fetch_state <= FETCH_WAIT;
                        end else begin
                            fetch_state  <= FETCH_DONE;
                            fetch_active <= 0; // finished the line fetch!
                        end
                    end
                    // FETCH_WAIT: sdram_busy=1 enquanto esperamos; transitamos
                    // no bloco else abaixo (quando busy=1 e data_ready=1)
                    default: ;
                endcase
            end else if (!wf_empty) begin
                sdram_addr <= wf_addr[wf_rptr[1:0]];
                sdram_din  <= wf_dat [wf_rptr[1:0]];
                sdram_wr   <= 1;
                wf_rptr    <= wf_rptr + 1;
            end
        end else begin
            // SDRAM ocupado: avança fetch quando data chega
            if (sdram_data_ready && fetch_state == FETCH_WAIT) begin
                fetch_wcnt  <= fetch_wcnt + 1;
                fetch_state <= FETCH_IDLE;
            end
        end
    end
end

endmodule
