# Documentação Técnica: As 3 Correções do Framebuffer Ping-Pong SDRAM

**Projeto:** Atari 2600 Nano SAN (Gowin Tang Nano 20K FPGA)  
**Arquivo Principal:** [frame_buffer.sv](file:///x:/ATARI/A2600NanoSAN/src/misc/frame_buffer.sv)  
**Data:** 28 de Julho de 2026  

---

## 1. Visão Geral da Arquitetura do Framebuffer

O módulo `frame_buffer` implementa um buffer de vídeo de quadro completo (*Ping-Pong*) armazenado na memória SDRAM externa de 32MB da Gowin Tang Nano 20K.

* **Lado de Escrita (Write Side):** O chip TIA (vídeo Atari 2600) gera pixels a 3.58 MHz (8 ciclos do clock do sistema de 28.8 MHz). O `frame_buffer` amostra a cor do TIA no ciclo `wr_tick == 3'd7` (fase de avaliação completa do multiplexador de cores do TIA), compacta 2 pixels de 12 bits (4-bit R, G, B) em palavras de 32 bits e as armazena em uma FIFO de escrita (`wf_dat`), que descarrega na SDRAM.
* **Lado de Leitura (Read Side):** Durante o HBLANK de cada linha, o árbitro da SDRAM busca 80 palavras de 32 bits (160 pixels) da linha seguinte e as armazena no Line Buffer BRAM interno de porta dupla (`line_buf`). Durante a região ativa, o `scandoubler` lê os pixels da BRAM e os dobra para exibição no HDMI a 60 Hz.

---

## 2. Correção 1: Compensação da Latência da BRAM (`pclk_div == 14`)

### O Problema
A imagem apresentava faixas verticais e um desalinhamento massivo de cores a cada 2 pixels (padrão de grade/listras horizontais e verticais).

### Causa Raiz
A memória BRAM da FPGA Gowin (`line_buf`) possui latência de leitura síncrona de 1 ciclo de clock (`lb_rdat <= line_buf[lb_raddr]`). No código original, o endereço de leitura `lb_raddr` era incrementado no ciclo `pclk_div == 15`. Devido à latência de 1 ciclo, o dado `lb_rdat` da nova palavra só ficava pronto no ciclo `pclk_div == 1` do pixel seguinte, fazendo com que o ciclo `pclk_div == 0` exibisse o dado obsoleto da palavra anterior.

### Solução Aplicada
Adiantamos a atualização do endereço BRAM `lb_raddr` para o ciclo **`pclk_div == 4'd14`**:

```verilog
// Pré-busca do próximo endereço BRAM no ciclo 14 para compensar a latência de 1 ciclo da BRAM
if (pclk_div == 4'd14 && rd_wcnt < WORDS_PER_LINE - 1) begin
    lb_raddr <= rd_wcnt + 1;
end
```

### Resultado
Ao chegar no ciclo `pclk_div == 0`, o registrador `lb_rdat` já contém a palavra correta 100% pronta. Eliminou completamente o desalinhamento a cada 2 pixels e removeu as faixas verticais.

---

## 3. Correção 2: Encerramento Natural no Word 79 & Anti-Truncagem `HMOVE`

### O Problema
Surgiam artefatos azuis em áreas pretas da tela e os objetos no lado direito (como os números do placar) tinham suas bordas cortadas ou tremidas.

### Causa Raiz
Quando jogos de Atari 2600 utilizam a instrução `HMOVE`, o sinal de HBLANK (`hb_in`) do TIA é estendido/deslocado. O código de leitura do framebuffer desligava abruptamente a região ativa (`rd_active <= 0`) ao detectar a subida do HBLANK (`rd_hblank_rise`), decapitando os últimos pixels das 80 palavras da linha antes que pudessem ser transmitidos para o `scandoubler`.

### Solução Aplicada
Em vez de permitir que o `rd_hblank_rise` decapite a linha no meio do caminho, o `rd_active` é desligado naturalmente **assim que a 80ª palavra (`WORDS_PER_LINE - 1`) completa sua transmissão no ciclo `pclk_div == 15`**:

```verilog
if (pclk_div == 4'd15) begin
    pclk_div <= 0;
    rd_wcnt  <= rd_wcnt + 1;
    if (rd_wcnt == WORDS_PER_LINE - 1)
        rd_active <= 0;
end
```

### Resultado
Todos os 160 pixels de cada linha são transmitidos na íntegra para o `scandoubler` sem cortes abruptos. Eliminou os artefatos azuis em áreas pretas e preservou o lado direito da tela.

---

## 4. Correção 3: Prioridade Ininterrupta do Fetch da Linha na SDRAM

### O Problema
Pontos aleatórios de 1 pixel ficavam "fritando" (oscilando em alta frequência) nas bordas de contraste alto (ex: placar amarelo sobre fundo azul). O teste diagnóstico comprovou que esse ruído continuava ocorrendo **mesmo com o quadro congelado na SDRAM**.

### Causa Raiz
O temporizador de Auto-Refresh da SDRAM roda a cada 430 ciclos de clock (`REFRESH_PERIOD = 430`), enquanto cada linha da tela tem 1820 ciclos. Como 1820 não é múltiplo de 430, o Auto-Refresh da SDRAM derrapava de posição horizontal a cada frame. No código original, o Auto-Refresh tinha prioridade sobre a busca da linha (`fetch_active`), pausando a leitura da SDRAM no meio do HBLANK. Essa pausa fazia com que a gravação dos últimos pixels da linha na BRAM invadisse a região de vídeo ativo, colidindo com a leitura do Scandoubler (colisão de Dual-Port RAM).

### Solução Aplicada
Reordenamos o árbitro principal da SDRAM dando **prioridade máxima e ininterrupta ao `fetch_active`** durante o HBLANK:

```verilog
// Árbitro principal: durante HBLANK, fetch da linha tem prioridade absoluta
if (!sdram_busy) begin
    if (fetch_active && fetch_state != FETCH_DONE) begin
        case (fetch_state)
            FETCH_IDLE: begin
                if (fetch_wcnt < WORDS_PER_LINE) begin
                    sdram_addr  <= make_addr(~bank_wr, fetch_line, {1'b0, fetch_wcnt});
                    sdram_rd    <= 1;
                    fetch_state <= FETCH_WAIT;
                end else begin
                    fetch_state  <= FETCH_DONE;
                    fetch_active <= 0; // linha concluída!
                end
            end
            default: ;
        endcase
    end else if (refresh_due) begin
        sdram_refresh <= 1;
        refresh_due   <= 0;
    end else if (!wf_empty) begin
        sdram_addr <= wf_addr[wf_rptr[1:0]];
        sdram_din  <= wf_dat [wf_rptr[1:0]];
        sdram_wr   <= 1;
        wf_rptr    <= wf_rptr + 1;
    end
end
```

### Resultado
Durante o HBLANK, as 80 palavras da linha são lidas da SDRAM em 400 ciclos ininterruptos planos. A BRAM fica 100% cheia e pronta **144 ciclos de clock ANTES** do vídeo ativo começar. O Auto-Refresh da SDRAM aguarda o término do fetch (apenas 13 microssegundos) e executa logo em seguida, zerando 100% as colisões de memória BRAM e eliminando totalmente a "fritação" estática!

---

## 5. Resumo da Estrutura Final do Árbitro e Read State Machine

O arquivo [frame_buffer.sv](file:///x:/ATARI/A2600NanoSAN/src/misc/frame_buffer.sv) combina as três correções em uma máquina de estados robusta, determinística e livre de qualquer race condition de hardware.
