// frame_buffer.sv — Buffer de pixels de vídeo para o Atari 2600 Nano SAN
//
// ARQUITETURA PRAGMÁTICA DE DUPLO LINE-BUFFER BRAM:
//   • O frame_buffer não altera a lógica de timing do video_stabilize.
//   • wr_line_buf (BRAM 128x32 bits): Armazena a amostragem da linha atual do TIA a 3.58 MHz.
//   • rd_line_buf (BRAM 128x32 bits): Armazena a linha lida da SDRAM para consumo do Scandoubler.
//   • SDRAM Arbiter: Realiza o Fetch (Leitura em Rajada de 87 ciclos = 3.0 µs) e o Flush
//     (Escrita em Rajada de 86 ciclos = 2.98 µs) exclusivamente dentro da janela do HBLANK (228 ciclos).
//   • Durante a tela ativa (538 ciclos), a SDRAM fica 100% IDLE (0% de uso de barramento).
//
// DOCUMENTAÇÃO EM PORTUGUÊS — ARQUITETURA DETERMINÍSTICA ZERO-JITTER

module frame_buffer (
    input           clk,            // Relógio do sistema (28.8 MHz)
    input           clk_cpu,        // Relógio de cor do TIA (3.58 MHz)
    input           resetn,         // Reset global (active-low)
    input           bypass,         // 1 = Passagem direta do TIA (durante download do cartucho)

    // Lado de Escrita do TIA (Captura de vídeo)
    input           wr_vsync,       // Vsync do TIA (active-high)
    input           wr_hblank,      // Hblank do TIA
    input           wr_vblank,      // Vblank do TIA
    input  [7:0]    wr_r, wr_g, wr_b, // Cores do TIA (8 bits por canal)
    input           pal,            // Detecção PAL/NTSC

    // Lado de Leitura (Timing externo vindo do video_stabilize via video.v)
    input           rd_hblank_in,   // Hblank do TIA (timing horizontal)
    input           rd_vblank_in,   // Vblank estabilizado pelo video_stabilize

    // Saída de pixel para o Scandoubler (Apenas cor RGB)
    output reg [7:0] rd_r, rd_g, rd_b,

    // Controlador da SDRAM
    output reg        sdram_rd,
    output reg        sdram_wr,
    output reg        sdram_refresh,
    output reg [22:0] sdram_addr,
    output reg [31:0] sdram_din,
    input  [31:0]     sdram_dout,
    input             sdram_data_ready,
    input             sdram_busy,
    input  [6:0]      sdram_col       // Endereço de coluna atual em rajada recebido da SDRAM
);

// ============================================================
// CONSTANTES E ENDEREÇAMENTO FÍSICO DA SDRAM
// ============================================================
localparam [6:0]  WORDS_PER_LINE = 7'd80;   // 160 pixels / 2 pixels por palavra = 80 palavras
localparam [9:0]  REFRESH_PERIOD = 10'd430;  // Período de auto-refresh da SDRAM

// Função de montagem do endereço de 23 bits da SDRAM:
//   bank: bit[8]      (Alternância de banco Ping-Pong 0 e 1)
//   line: bits[19:10] (Número absoluto da linha de varredura)
//   word: bits[7:0]   (Índice da palavra dentro da linha: 0 a 79)
function automatic [22:0] make_addr;
    input        bank;
    input [9:0]  line;
    input [7:0]  word;
    make_addr = {3'b0, line, 10'b0} | {14'b0, bank, 8'b0} | {15'b0, word};
endfunction

// Função de empacotamento de cores: reduz 8 bits por canal para 4 bits (12 bits por pixel)
function automatic [11:0] pack_px;
    input [7:0] r, g, b;
    pack_px = {r[7:4], g[7:4], b[7:4]};
endfunction

// ============================================================
// DUPLO LINE-BUFFER BRAM (INFERÊNCIA AUTOMÁTICA DE BRAM DO GOWIN)
// ============================================================

// 1. Line Buffer de Escrita do TIA (wr_line_buf: 128x32 bits = 1 Bloco BSRAM)
reg [31:0] wr_line_buf [0:127];
reg [6:0]  wr_waddr;
reg [31:0] wr_wdat;
reg        wr_wen;
reg [6:0]  wr_raddr;
reg [31:0] wr_rdat;

always @(posedge clk) begin
    if (wr_wen) wr_line_buf[wr_waddr] <= wr_wdat;
    wr_rdat <= wr_line_buf[wr_raddr];
end

// 2. Line Buffer de Leitura do Scandoubler (rd_line_buf: 128x32 bits = 1 Bloco BSRAM)
reg [31:0] rd_line_buf [0:127];
reg [6:0]  lb_waddr;
reg [31:0] lb_wdat;
reg        lb_wen;
reg [6:0]  lb_raddr;
reg [31:0] lb_rdat;

always @(posedge clk) begin
    if (lb_wen) rd_line_buf[lb_waddr] <= lb_wdat;
    lb_rdat <= rd_line_buf[lb_raddr];
end

// ============================================================
// DETECÇÃO DE BORDAS SÍNCRONAS DE SINCRONISMO
// ============================================================
reg wr_hblank_d, wr_vsync_d, rd_hblank_d;
wire wr_hblank_rise = !wr_hblank_d && wr_hblank;
wire wr_hblank_fall =  wr_hblank_d && !wr_hblank; // Início do vídeo ativo do TIA
wire wr_vsync_rise  = !wr_vsync_d  && wr_vsync;
wire rd_hblank_fall =  rd_hblank_d && !rd_hblank_in; // Início da imagem ativa no monitor
wire rd_hblank_rise = !rd_hblank_d &&  rd_hblank_in; // Início do retorno de tela (HBLANK)

// ============================================================
// REGISTRADORES DE CONTROLE DO TIA E DA SDRAM
// ============================================================
reg [9:0]  wr_lcnt;
reg [6:0]  wr_wcnt;
reg [11:0] wr_odd_pixel;
reg        wr_has_odd;
reg        bank_wr;
reg        frame_valid;
reg [2:0]  wr_tick;
reg        clk_cpu_d;
reg [31:0] sdram_dout_neg;
reg        fetch_active, flush_active;
reg        refresh_done_line;

// Limites verticais da tela ativa para eliminação de ruído de borda
reg [9:0]  wr_line_min, wr_line_max;
reg [9:0]  wr_line_min_next, wr_line_max_next;

// Captura síncrona da SDRAM no meio-ciclo (negedge clk = 17.3 ns)
always @(negedge clk) begin
    sdram_dout_neg <= sdram_dout;
end

// ============================================================
// LADO DE ESCRITA: AMOSTRAGEM DO TIA → wr_line_buf (BRAM)
// ============================================================
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
        wr_tick      <= 0;
        wr_waddr     <= 0;
        wr_wdat      <= 0;
        wr_wen       <= 0;
        wr_line_min  <= 0;
        wr_line_max  <= 0;
        wr_line_min_next <= 10'h3FF;
        wr_line_max_next <= 0;
    end else begin
        clk_cpu_d <= clk_cpu;

        // Sincronização de fase com o relógio de cor do TIA (3.58 MHz)
        if (!clk_cpu_d && clk_cpu) begin
            wr_tick <= 0;
        end else begin
            wr_tick <= wr_tick + 1;
        end

        wr_hblank_d <= wr_hblank;
        wr_vsync_d  <= wr_vsync;

        if (!bypass) begin
            // Início de um novo quadro: alterna o banco de memória Ping-Pong
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

            // Início do vídeo ativo do TIA (borda de descida do HBLANK): resincroniza a fase no Pixel 0
            if (wr_hblank_fall && frame_valid) begin
                wr_tick    <= 0;
                wr_wcnt    <= 0;
                wr_has_odd <= 0;
            end

            // Final da linha ativa (HBLANK): empacota pixel ímpar restante e zera a contagem
            if (wr_hblank_rise && frame_valid) begin
                if (wr_has_odd && wr_wcnt < WORDS_PER_LINE) begin
                    wr_wdat  <= { 12'b0, 4'b0, wr_odd_pixel, 4'b0 };
                    wr_waddr <= wr_wcnt;
                    wr_wen   <= 1;
                end
                wr_has_odd <= 0; // Garantia síncrona: a próxima linha sempre começa no Pixel 0

                if (!wr_vblank) begin
                    if (wr_line_min_next == 10'h3FF)
                        wr_line_min_next <= wr_lcnt;
                    wr_line_max_next <= wr_lcnt;
                end

                wr_lcnt <= wr_lcnt + 1;
                wr_wcnt <= 0;
            end

            // Amostragem síncrona do TIA durante vídeo ativo e preenchimento limpo com preto (32'h0) no HBLANK
            if (wr_hblank && !wr_vblank && frame_valid) begin
                wr_has_odd <= 0;
                if (wr_wcnt < WORDS_PER_LINE) begin
                    //wr_wdat  <= 32'h0; // Preenche palavras restantes do lado direito com preto puro!
                    wr_waddr <= wr_wcnt;
                    wr_wen   <= 1;
                    wr_wcnt  <= wr_wcnt + 1;
                end else begin
                    wr_wen   <= 0;
                end
            end else if (wr_vblank) begin
                wr_has_odd <= 0;
                wr_wcnt    <= 0;
                wr_wen     <= 0;
            end else begin
                wr_wen <= 0;
                // Amostragem síncrona no ciclo 7 da fase do relógio de cor do TIA
                if (wr_tick == 3'd7 && wr_wcnt < WORDS_PER_LINE) begin
                    if (!wr_has_odd) begin
                        wr_odd_pixel <= pack_px(wr_r, wr_g, wr_b);
                        wr_has_odd   <= 1;
                    end else begin
                        // Empacota o Pixel 1 (Ímpar) e o Pixel 0 (Par) em 32 bits e grava no wr_line_buf
                        wr_wdat  <= { pack_px(wr_r, wr_g, wr_b), 4'b0, wr_odd_pixel, 4'b0 };
                        wr_waddr <= wr_wcnt;
                        wr_wen   <= 1;
                        wr_wcnt  <= wr_wcnt + 1;
                        wr_has_odd <= 0;
                    end
                end
            end
        end
    end
end

// ============================================================
// LADO DE LEITURA: rd_line_buf (BRAM) → SCANDOUBLER (EXIBIÇÃO)
// ============================================================
reg [9:0] rd_lcnt;
reg [3:0] pclk_div;
reg [6:0] rd_wcnt;
reg       rd_active;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        rd_lcnt     <= 0;
        pclk_div    <= 0;
        rd_wcnt     <= 0;
        rd_active   <= 0;
        lb_raddr    <= 0;
        rd_hblank_d <= 1;
        rd_r <= 0; rd_g <= 0; rd_b <= 0;
    end else if (bypass) begin
        rd_hblank_d <= rd_hblank_in;
        rd_active   <= 0;
        rd_r <= wr_r; rd_g <= wr_g; rd_b <= wr_b;
    end else begin
        rd_hblank_d <= rd_hblank_in;

        // Reset da contagem de linhas no Vsync
        if (wr_vsync_rise) begin
            rd_lcnt   <= 0;
            rd_active <= 0;
        end

        // Início do HBLANK: avança o contador de linhas de leitura
        if (rd_hblank_rise && !wr_vsync_rise)
            rd_lcnt <= rd_lcnt + 1;

        // Início do vídeo ativo no monitor
        if (rd_hblank_fall && !rd_vblank_in) begin
            rd_active <= 1;
            pclk_div  <= 0;
            rd_wcnt   <= 0;
        end

        // Início do HBLANK: pré-carrega o endereço 0 da BRAM
        if (rd_hblank_rise) begin
            rd_active <= 0;
            lb_raddr  <= 0;
        end

        // Saída contínua de pixels durante a região ativa
        if (rd_active && !rd_vblank_in) begin
            pclk_div <= pclk_div + 1;

            // Pré-busca do próximo endereço da BRAM no ciclo 14 para compensar a latência de 1 ciclo
            if (pclk_div == 4'd14 && rd_wcnt < WORDS_PER_LINE - 1) begin
                lb_raddr <= rd_wcnt + 1;
            end

            if (pclk_div == 4'd15) begin
                pclk_div <= 0;
                rd_wcnt  <= rd_wcnt + 1;
                if (rd_wcnt == WORDS_PER_LINE - 1)
                    rd_active <= 0;
            end

            // Limpeza de borda: linhas fora da área gravada retornam Preto Puro (0,0,0)
            if (rd_lcnt < wr_line_min || rd_lcnt > wr_line_max || rd_wcnt >= WORDS_PER_LINE) begin
                //rd_r <= 0; rd_g <= 0; rd_b <= 0;
            end else if (pclk_div == 4'd15) begin
                rd_r <= rd_r; rd_g <= rd_g; rd_b <= rd_b;
            end else if (!pclk_div[3]) begin
                // Pixel 0 (Par): extração limpa dos 4 bits de cor por canal
                rd_r <= { (lb_rdat[15:12] & 4'hF), (lb_rdat[15:12] & 4'hF) };
                rd_g <= { (lb_rdat[11:8]  & 4'hF), (lb_rdat[11:8]  & 4'hF) };
                rd_b <= { (lb_rdat[7:4]   & 4'hF), (lb_rdat[7:4]   & 4'hF) };
            end else begin
                // Pixel 1 (Ímpar): extração limpa dos 4 bits de cor por canal
                rd_r <= { (lb_rdat[31:28] & 4'hF), (lb_rdat[31:28] & 4'hF) };
                rd_g <= { (lb_rdat[27:24] & 4'hF), (lb_rdat[27:24] & 4'hF) };
                rd_b <= { (lb_rdat[23:20] & 4'hF), (lb_rdat[23:20] & 4'hF) };
            end
        end else if (!rd_active || rd_vblank_in) begin
            rd_r <= 0; rd_g <= 0; rd_b <= 0;
        end
    end
end

// ============================================================
// ÁRBITRO PRINCIPAL DA SDRAM (EXCLUSIVO NO HBLANK)
//   • Fase 1: Fetch (Leitura em Rajada de 87 ciclos = 3.0 µs) da SDRAM → rd_line_buf
//   • Fase 2: Flush (Escrita em Rajada de 86 ciclos = 2.98 µs) da wr_line_buf → SDRAM
// ============================================================
reg [9:0]  fetch_line;
reg [6:0]  fetch_wcnt;
reg [1:0]  fetch_state;
localparam FETCH_IDLE = 2'd0;
localparam FETCH_WAIT = 2'd1;
localparam FETCH_DONE = 2'd2;

reg [9:0]  flush_line;
reg [6:0]  flush_wcnt;
reg [1:0]  flush_state;
localparam FLUSH_IDLE = 2'd0;
localparam FLUSH_WAIT = 2'd1;
localparam FLUSH_DONE = 2'd2;

reg [9:0]  refresh_cnt;
reg        refresh_due;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        sdram_rd      <= 0;
        sdram_wr      <= 0;
        sdram_refresh <= 0;
        sdram_addr    <= 0;
        sdram_din     <= 0;
        lb_waddr      <= 0;
        lb_wdat       <= 0;
        lb_wen        <= 0;
        wr_raddr      <= 0;
        refresh_cnt   <= 0;
        refresh_due   <= 0;
        fetch_wcnt    <= 0;
        fetch_active  <= 0;
        fetch_line    <= 0;
        fetch_state   <= FETCH_IDLE;
        flush_wcnt    <= 0;
        flush_active  <= 0;
        flush_line    <= 0;
        flush_state   <= FLUSH_IDLE;
    end else begin
        sdram_rd      <= 0;
        sdram_wr      <= 0;
        sdram_refresh <= 0;
        lb_wen        <= 0;

        // Timer de auto-refresh da SDRAM
        refresh_cnt <= refresh_cnt + 1;
        if (refresh_cnt == REFRESH_PERIOD) begin
            refresh_cnt <= 0;
            refresh_due <= 1;
        end

        // Início do HBLANK: Dispara o pré-carregamento (Fetch) e a regravação (Flush) da linha
        if (rd_hblank_rise && frame_valid && !bypass) begin
            fetch_active      <= 1;
            fetch_wcnt        <= 0;
            fetch_state       <= FETCH_IDLE;
            fetch_line        <= rd_lcnt + 1;
            flush_active      <= 1;
            flush_wcnt        <= 0;
            flush_state       <= FLUSH_IDLE;
            flush_line        <= (wr_lcnt > 0) ? (wr_lcnt - 1) : 10'd0;
            refresh_done_line <= 0; // Habilita o Auto-Refresh obrigatório do HBLANK atual
        end

        // Reset da SDRAM no Vsync
        if (wr_vsync_rise && frame_valid && !bypass) begin
            fetch_active      <= 1;
            fetch_wcnt        <= 0;
            fetch_state       <= FETCH_IDLE;
            fetch_line        <= 0;
            flush_active      <= 0;
            flush_state       <= FLUSH_DONE;
            refresh_done_line <= 1;
        end

        // ÁRBITRO DE EXECUÇÃO: Executa exclusivamente no HBLANK
        if (!sdram_busy) begin
            // 1. Fase 1: Fetch (Leitura em Rajada de 80 palavras = 87 ciclos = 3.0 µs)
            if (fetch_active && fetch_state == FETCH_IDLE) begin
                sdram_addr  <= make_addr(~bank_wr, fetch_line, 8'd0);
                sdram_rd    <= 1;
                fetch_state <= FETCH_WAIT;
            end 
            // 2. Fase 2: Flush (Escrita em Rajada de 80 palavras = 86 ciclos = 2.98 µs)
            else if (flush_active && fetch_state == FETCH_DONE && flush_state == FLUSH_IDLE) begin
                sdram_addr  <= make_addr(bank_wr, flush_line, 8'd0);
                sdram_wr    <= 1;
                flush_state <= FLUSH_WAIT;
            end
            // 3. Fase 3: Auto-Refresh Físico Obrigatório (6 ciclos = 0.21 µs) em TODO HBLANK
            else if (fetch_state == FETCH_DONE && flush_state == FLUSH_DONE && !refresh_done_line) begin
                sdram_refresh     <= 1;
                refresh_done_line <= 1; // Garante 1 Auto-Refresh físico em cada HBLANK!
            end
        end

        // Recepção dos dados do Fetch (SDRAM → rd_line_buf da BRAM)
        if (sdram_data_ready && fetch_state == FETCH_WAIT) begin
            lb_wdat  <= sdram_dout_neg;
            lb_waddr <= fetch_wcnt;
            lb_wen   <= 1;
            fetch_wcnt <= fetch_wcnt + 1;
            if (fetch_wcnt == WORDS_PER_LINE - 1) begin
                fetch_state <= FETCH_DONE;
            end
        end

        // Envio síncrono dos dados do Flush (wr_line_buf da BRAM → SDRAM)
        // O endereço de leitura da BRAM (wr_raddr) é guiado diretamente pelo col_addr da SDRAM
        wr_raddr <= sdram_col;
        sdram_din <= wr_rdat;

        if (flush_state == FLUSH_WAIT && !sdram_busy) begin
            flush_state  <= FLUSH_DONE;
            flush_active <= 0; // Escrita em rajada de 80 palavras 100% concluída em 2.98 µs!
        end
    end
end

endmodule
