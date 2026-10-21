# Engenharia reversa do Wolfenstein 3D, para o MSX DOOM com Geo3D

Estudo do código-fonte original do Wolfenstein 3D (id Software, 1992) para responder uma
pergunta: **o que faz aquele motor rodar num 286 e o que disso serve a um jogo em Z80 que
desenha pelo Geo3D?**

- Fonte: `https://github.com/id-Software/wolf3d`, clonado em `C:\Projects\mmsoft\wolf3d`
  (commit `0516778`). Os arquivos lidos estão em `WOLFSRC/`.
- Só as ideias foram usadas. Nenhuma linha do Wolf3D foi copiada: o código do cartucho é
  Z80 original. A licença do repositório (`WOLFSRC/README/LICENSE.DOC`) é de uso
  limitado, para estudo; não é GPL.
- Data: 6 de outubro de 2026. Medidas no openMSX (Z80 a 3,58 MHz), com
  `tests/run_tests.sh prof`.

## Resumo

O Wolf3D não é rápido por causa do lançamento de raios em si. É rápido por quatro regras
que valem para qualquer motor:

1. **O caminho de cada quadro só faz o que muda a cada quadro.** Tudo o que pode ser
   preparado antes vira tabela ou código pronto (tangentes, ângulo de cada coluna, uma
   rotina de escala compilada para cada altura).
2. **Nunca espera pela tela.** Três páginas de vídeo: sempre há uma livre para desenhar.
3. **Visibilidade e oclusão saem de graça do desenho das paredes** (`spotvis` e
   `wallheight`), em vez de serem calculadas à parte.
4. **Quem não está perto do jogador não custa nada**: ator fora da área do jogador nem
   é chamado; movimento e colisão são decididos uma vez por ladrilho, não por quadro.

Aplicando as regras 1, 2 e 4 ao cartucho, sem mudar a imagem nem as regras do jogo:

| Situação (openMSX) | Antes: média / pior | Depois: média / pior |
|---|---|---|
| Parado | 33 ms / 33 ms | 25 ms / 27 ms |
| Andando | 35 ms / 50 ms | 31 ms / 45 ms |
| Andando e girando | 39 ms / 50 ms | 31 ms / 53 ms |
| Andando, girando e atirando, com inimigos atacando | 47 ms / 67 ms | 33 ms / 57 ms |

De 21 a 30 quadros por segundo para 30 a 40. As 18 poses do teste continuam idênticas, byte
a byte, ao modelo de referência do Geo3D, nos perfis 98h e 88h.

O lançador de raios do Wolf3D **não** serve: num Z80, 256 raios por quadro custariam mais
que o quadro inteiro de hoje, e o Geo3D já faz a projeção e o preenchimento em hardware.

## Como o Wolf3D faz um quadro

`ThreeDRefresh` (`WL_DRAW.C`), nesta ordem:

| Passo | Onde | O que faz |
|---|---|---|
| 1 | `ThreeDRefresh` | Zera `spotvis[64][64]` (um byte por ladrilho: "um raio passou aqui") |
| 2 | `VGAClearScreen` | Teto e piso: **dois preenchimentos lisos** (`rep stosw`), metade de cima e metade de baixo |
| 3 | `WallRefresh` → `AsmRefresh` (`WL_DR_A.ASM`) | Um raio por coluna da tela, ver abaixo |
| 4 | `DrawScaleds` | Objetos e inimigos, do mais longe para o mais perto |
| 5 | `DrawPlayerWeapon` | A arma, sem recorte |
| 6 | fim de `ThreeDRefresh` | Troca de página: escreve só o byte alto do endereço no CRTC e passa para a página seguinte, sem esperar o retraço |

### O raio (`AsmRefresh`)

- O ângulo de cada coluna vem de `pixelangle[x]` (calculada uma vez em `CalcProjection`,
  com `atan`, o que já corrige a distorção de olho de peixe). `finetangent[]` tem a
  tangente de 900 ângulos finos por quadrante (`BuildTables`).
- O passo é um DDA na grade: `xstep`/`ystep` são tangentes em ponto fixo 16.16 e o laço
  central só soma e compara. As comparações `jle`/`jge` que dependem do quadrante são
  **regravadas no próprio código** antes do laço (`horizop`, `vertop`), para não testar o
  sinal a cada passo.
- A cada ladrilho livre atravessado, `spotvis` é marcado. É o único custo da visibilidade.
- Ao bater numa parede (`HitVertWall`, `HitHorizWall`): a coluna de textura sai dos bits
  do ponto de impacto (`(yintercept >> 4) & 0xfc0`), e a altura sai de `CalcHeight`: duas
  multiplicações (`gx*cos - gy*sin`) e **uma** divisão (`heightnumerator / (nx >> 8)`).
- **Colunas vizinhas iguais são juntadas**: se a coluna seguinte cai na mesma parede e na
  mesma coluna de textura, só incrementa `postwidth`; `ScalePost` desenha a faixa inteira
  de uma vez (até 8 pixels de largura por escrita, com as máscaras de plano do VGA).
- `wallheight[x]` guarda a altura da parede em cada coluna.
- Portas e paredes que deslizam são casos do mesmo laço (meio passo a mais).

### As rotinas de escala compiladas (`WL_SCALE.C`)

`BuildCompScale` gera, para cada altura de parede (de 2 em 2 pixels; de 6 em 6 acima da altura da
janela), uma rotina sem laço: `mov al,[si+n]` e um `mov [es:di+ofs],al` para cada pixel
de destino. Desenhar uma coluna é um `call` indireto por tabela (`fullscalefarcall`). Os
sprites usam as mesmas rotinas: `ScaleLine` grava um `RETF` no ponto onde o segmento
opaco termina e entra pelo ponto onde ele começa.

### Sprites (`DrawScaleds`, `ScaleShape`)

- Só entra na lista quem está num ladrilho marcado em `spotvis` (ou num dos 8 vizinhos).
- `TransformActor`: 4 multiplicações e 2 divisões por objeto visível. O centro é puxado
  0,25 ladrilho para a câmera (`ACTORSIZE`) para o sprite não entrar na parede ao lado.
- Ordenação só entre os sprites, por altura na tela (seleção simples, no máximo 50).
- **Oclusão por coluna**: cada coluna do sprite só é desenhada se `wallheight[x]` for
  menor que a altura do sprite. `wallheight` é um z-buffer de uma dimensão que as paredes
  deixaram pronto.

### Lógica (`WL_PLAY.C`, `WL_STATE.C`)

- `DoActor` começa com `if (!ob->active && !areabyplayer[ob->areanumber]) return;`. As
  áreas são salas; `areabyplayer` diz quais estão ligadas à do jogador por portas abertas.
  O resto do mapa não gasta nada.
- Cada ator é uma máquina de estados com contagem de tiques (`ticcount`); `think` só roda
  quando ela zera, nos estados de transição.
- Movimento em passos de ladrilho: `MoveObj` soma o deslocamento e desconta de
  `ob->distance`; a direção só é escolhida ao chegar no centro do ladrilho
  (`SelectChaseDir`: tenta os dois eixos na direção do jogador, depois os outros). Colisão
  é uma consulta a `tilemap` e `actorat[x][y]` do ladrilho de destino, uma vez por
  ladrilho. Não há teste entre pares de atores.
- Visão do inimigo (`CheckSight`): área ligada, distância mínima, lado para onde olha, e
  só então `CheckLine`, um DDA de ladrilho em ladrilho. Depois de ver, espera um tempo de
  reação (`temp2`). Tiro acorda a área (`madenoise`).
- Tempo adaptativo: `CalcTics` mede os tiques do último quadro, com teto (`MAXTICS`).

### Piso e teto texturizados (`WOLFHACK.C`, `WHACK_A.ASM`)

Não entrou no jogo, mas está no código: `DrawPlanes` usa `wallheight` para achar, em cada
linha da tela, o trecho de piso visível, e `MapRow` percorre a textura com passo
constante por linha (teto e piso ao mesmo tempo, espelhados). É o mesmo princípio de uma
linha LRMM do V9968. Fica como referência para texturizar o piso do cartucho: seriam cerca
de 180 comandos por quadro emitidos pelo Z80, caro demais; o caminho continua sendo
mandar os ladrilhos como faces ao Geo3D.

## O que serve ao Geo3D e o que não serve

| Técnica do Wolf3D | No cartucho | Resultado |
|---|---|---|
| Um raio por coluna, colunas juntadas em faixas | **Não serve.** O Geo3D projeta e preenche em hardware; o Z80 só precisa dizer quais faces existem. A visibilidade já é pré-calculada na build | — |
| Rotinas de escala compiladas | **Não serve.** O V9968 escala (LRMM) | — |
| `wallheight` como z-buffer de sprites | **Não serve.** Os inimigos são faces do mesmo RUN e a ordenação é do Geo3D | — |
| `ACTORSIZE` (sprite 0,25 ladrilho para a frente) | **Testado, não ajuda.** Nossos erros de ordem são parede contra parede: de 0,022 % para 0,020 % dos pixels em 400 poses (`tools/check_order.py`) | Descartado |
| Preparar antes tudo o que não muda a cada quadro | **Aplicado**: as paredes próximas viraram tiras fixas, enviadas ao entrar na célula. Por quadro, só a tira que cruza o plano próximo (ver abaixo) | Paredes próximas: de 7–10 ms para 3,5 ms por quadro |
| Três páginas, nunca esperar a tela | **Aplicado em parte.** Não há VRAM para a terceira página; em troca, a geometria do quadro seguinte é montada enquanto o anterior espera o retraço | Espera ociosa: de 4–10 ms para 1–4 ms |
| Dois preenchimentos lisos para teto e piso | **Medido, não aplicado** (muda o visual): 16 faixas custam 5,5 ms, 8 faixas 4,1 ms, 2 preenchimentos 3,2 ms | Decisão em aberto |
| Ator fora da área do jogador não é chamado | **Aplicado**: inimigo parado numa célula que a do jogador não vê retorna na primeira linha; a separação entre inimigos só roda se algum saiu do repouso; o teste de inimigo sólido descarta pela célula antes de calcular distância | Lógica: de 5,4–9 ms para 5–7,5 ms (no emulador fica escondido atrás do RUN) |
| Movimento e colisão por ladrilho, `actorat` | **Não aplicado** (muda o comportamento dos inimigos). O caminho já vem de tabela | Ver "O que ainda dá para ganhar" |
| Tabelas de trigonometria, ponto fixo | Já era assim (senos em Q2.14, sem divisão por quadro) | — |
| Tempo adaptativo com teto | Já era assim (`dt` de 1 a 8 retraços) | — |

## O que mudou no cartucho

### 1. Paredes próximas: tiras fixas, e por quadro só a que cruza o plano

Antes, a cada quadro o Z80 testava, recortava, dividia em tiras e reenviava todas as
paredes das 3x3 células em volta do jogador (até 8 paredes, até 32 faces).

Agora (`st_build`, `ns_wall`, `near_emit` em `src/render.asm`):

- Ao entrar numa célula, cada parede próxima vai ao Geo3D como **quatro tiras de 64
  unidades**, com os cantos compartilhados. Ficam na RAM do Geo3D enquanto o jogador
  estiver na célula.
- O próprio Geo3D descarta as tiras com vértice atrás do plano próximo e as que estão de
  costas. O Z80 não testa campo de visão nem escolhe quantas tiras usar.
- Por quadro, o Z80 calcula a profundidade dos 16 cantos (2 multiplicações e 16 somas) e,
  para cada parede que **cruza** Z = 16, emite uma face: do cruzamento até o fim da tira
  onde ele cai. É a única tira que o Geo3D pode ter descartado com um pedaço visível.
- As faces distantes vêm depois das tiras e são as únicas refeitas quando o jogador gira
  mais de 34 graus (`st_far`).

Custo: a entrada numa célula ficou uns 8 ms mais cara (20 a 25 ms num quadro, a cada 0,3 s
andando), e o Geo3D recebe mais faces (no máximo 67 fixas e 158 vértices, de 255).

### 2. Ordem do quadro sem espera ociosa

Antes: desenha, pede a troca de página, **espera o retraço**, começa o quadro seguinte.

Agora (`frame` em `src/game.asm`, `flip_ask` / `flip_sync` em `src/render.asm`):

```
pede a troca de página (acontece no próximo retraço)
  câmera, paredes próximas, objetos -> RAM do Geo3D     (enquanto o retraço não vem)
espera a troca, se ainda não aconteceu
  fundo (HMMV) -> RUN do Geo3D
  lógica do jogo                                         (enquanto o Geo3D desenha)
espera o RUN -> pistola, mira, barra de status
```

O Z80 só fica parado quando está adiantado em relação ao hardware.

### 3. Fundo com comandos prontos

Os 11 bytes de cada preenchimento, para cada página, ficam prontos na ROM (`bg_cmds`).
O ganho foi pequeno: no emulador o que domina é o tempo do V9968 para preencher (cerca de
3 ms para a janela inteira), não o envio.

### 4. Lógica

`enemy_tick`, `enemies_update` e `enemy_near`, como descrito na tabela. `cell_seen` passou
a usar máscara de bit em vez de laço de rotação.

## Onde o tempo vai agora

Média por quadro, em combate (33 ms):

| Etapa | Tempo | Limitada por |
|---|---|---|
| Câmera | 1,9 ms | Z80 (4 multiplicações de 16 bits) |
| Paredes próximas | 3,6 ms | Z80 |
| Objetos (inimigos, kits) | 4,5 ms | Z80 |
| Espera da troca de página | 2,2 ms | retraço |
| Fundo | 5,5 ms | V9968 (3 ms) + Z80 (2,5 ms para 16 comandos) |
| RUN do Geo3D, com a lógica do jogo dentro | 10 a 11 ms | Geo3D + V9968 (a lógica leva 7,5 ms) |
| Pistola, mira, barra | 1,9 ms | V9968 |
| Entrada em célula nova (rateado) | 2,3 ms | Z80 |

Mais da metade do quadro agora é espera de hardware **no emulador**. O fork do openMSX
aproxima a velocidade dos comandos e não cobra tempo pela geometria do Geo3D, então a
proporção no cartucho real pode ser outra; a parte do Z80 é a que a medida garante.

## O que ainda dá para ganhar

Em ordem de retorno, com o que cada um custa:

1. **Menos faixas no fundo** (decisão de visual). 8 faixas em vez de 16: cerca de 1,4 ms.
   Liso como no Wolf3D: 2,3 ms no envio, e até 3 ms no quadro médio em combate.
   Para experimentar: `BANDS=0,7,19,43,90 bash build.sh --data` ou `BANDS=0,90`.
2. **Coordenadas relativas à célula do jogador.** Com os vértices relativos ao canto da
   célula, a translação da câmera e a profundidade dos cantos saem de 4 produtos de
   16 x 8 bits (a fração da posição dentro da célula) em vez de 6 de 16 x 16. Estimativa:
   1,3 ms por quadro. Mexe em toda a emissão de vértices e no simulador.
3. **Descartar por direção os objetos atrás do jogador** antes de emitir. Hoje vai ao
   Geo3D todo objeto numa célula visível de qualquer direção, e é o Geo3D que descarta os
   de trás. Uma tabela pequena de arco-tangente por diferença de células resolve.
   Estimativa: 1 ms.
4. **Inimigos em passos de ladrilho com grade de ocupação** (`actorat`), como no Wolf3D.
   Tira o teste de parede por quadro e a separação par a par (2 ms). Muda o jeito de andar
   dos inimigos, e só rende se o RUN no hardware real for mais curto que a lógica.
5. **Sobrepor o preenchimento do fundo à emissão dos objetos.** Ganho líquido estimado em
   1 ms, porque a espera do retraço cresce quase o mesmo tanto.
6. **Janela 3D menor**, como o ajuste de tela do Wolf3D. Reduz texels e linhas LRMM na
   mesma proporção; não muda o tempo do Z80.

O pico ao entrar numa célula (20 a 25 ms) é agora o pior quadro. Tabelas de vértices e
faces já prontas na ROM por célula baixariam isso para uns 6 ms, ao custo de cerca de
160 KB de ROM.

## Arquivos do Wolf3D que valem a leitura

| Arquivo | Conteúdo |
|---|---|
| `WL_DRAW.C` | `ThreeDRefresh`, `WallRefresh`, `HitVertWall`, `CalcHeight`, `ScalePost`, `DrawScaleds`, `TransformActor` |
| `WL_DR_A.ASM` | `AsmRefresh`: o laço dos raios |
| `WL_SCALE.C` | `BuildCompScale`, `ScaleLine`, `ScaleShape` |
| `WL_MAIN.C` | `BuildTables`, `CalcProjection` |
| `WL_PLAY.C` | `PlayLoop`, `DoActor` |
| `WL_STATE.C` | `CheckSight`, `CheckLine`, `SelectChaseDir`, `MoveObj`, `TryWalk` |
| `WL_ACT1.C` | portas e ligação de áreas (`areabyplayer`) |
| `WOLFHACK.C`, `WHACK_A.ASM` | piso e teto texturizados por linha (experimento) |
