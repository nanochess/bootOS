# Auditoria técnica e trilha de evolução

## Proveniência e escopo

Consulta em 27/09/2026. O URL original `https://github.com/nanochess/bootOSC` retornou
404. Base explicitamente assumida: `https://github.com/nanochess/bootOS`, commit
`e54fffe4243bb77e487798801a3bc4c3e60cb01e`. A análise e as alterações concentram-se no
núcleo `os.asm`, no build e nas ferramentas novas. Não representam auditoria dos jogos
em `patch/`, de programas externos ou de todos os firmwares em que o projeto pode rodar.

Fontes primárias:
- README e árvore: https://github.com/nanochess/bootOS/tree/e54fffe4243bb77e487798801a3bc4c3e60cb01e
- Núcleo: https://github.com/nanochess/bootOS/blob/e54fffe4243bb77e487798801a3bc4c3e60cb01e/os.asm
- Commit: https://github.com/nanochess/bootOS/commit/e54fffe4243bb77e487798801a3bc4c3e60cb01e
- Protocolo usado pelo gate QEMU: https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html

## O que torna a otimização difícil e interessante

O projeto tem uma restrição explícita de tamanho. Seu caminho de execução está acoplado
à disposição dos bytes: endereços reais, flags retornadas, valores implícitos de BX/CX e
reuso de rotinas economizam espaço. Acrescentar abstrações usuais de sistemas grandes
sem contabilizar bytes destruiria a propriedade central que queremos preservar.

O patch mantém 512 bytes e a API, mas não atribui ao kernel sozinho ganhos de um módulo
que consome mais memória. Core e acelerador são entregues e medidos separadamente.

## Achados com localização no original

| Área / símbolo | Observação | Tratamento nesta entrega |
|---|---|---|
| start | 512 iterações MOVSB na realocação | 256 MOVSW; não estimamos ciclos |
| save_file | Delete + procura de slot + recriação para sobrescrever | Sobrescrita no slot encontrado; elimina 2 escritas de diretório |
| filename_length / rep movsb | Contagem e cópia sem limite de 16 bytes | Limite em todos os serviços que procuram nome; CF=1 quando longo |
| find_file | DF do chamador pode alterar direção de string | CLD interno; IRET preserva o DF original |
| read_dir / find_file | Nova leitura de diretório em cada busca | Core mantém política; fast evita todo o caminho apenas em cache hit |
| input_line | Overflow e backspace abaixo do início | Reproduzidos; não corrigidos |
| enter_command / xdigit | Bytes além de 512 e hexadecimal permissivo | Inspeção de fonte; não corrigidos nem totalmente cobertos por testes |
| disk | Retry infinito, sem reset/backoff, drive A fixo | Retry reproduzido sob falha; comportamento não alterado |
| ret_cf | RCL sobre byte de FLAGS altera mais que CF | Herdado no core; wrapper fast preserva os demais bits do chamador |
| save_file, criação | Diretório escrito antes do setor de dados | Não transacional; não corrigido |
| os11 / commands | Parser por prefixo, não token exato | Mantido por compatibilidade; não corrigido |
| nome vazio | Interpretação como entrada vazia | Reproduzido; não corrigido |

## Análise de custo do salvamento

Existente, upstream: ler diretório → gravar diretório para excluir → gravar diretório
para recriar → gravar dados. Total: quatro chamadas BIOS; duas escritas de metadados.

Existente, core: ler diretório → localizar → gravar dados no mesmo cilindro. Total: duas
chamadas BIOS; nenhuma escrita de metadados. Uma entrada localizada depois de um slot
vazio continua no mesmo local, evitando movimento desnecessário e preservando o layout.

Arquivo novo: ler diretório → criar entrada → gravar diretório → gravar dados.
Total permanece três chamadas. A operação não ganhou atomicidade: falha ou queda de energia
entre escrita do diretório e dos dados pode deixar nome publicado com conteúdo antigo.

## Contrato do acelerador

Hook INT 23h, encadeado ao serviço anterior; hook INT 13h, encadeado à BIOS anterior.
Instalação atualiza os vetores com interrupções desabilitadas. A tabela BDA informa
2 KiB a menos de memória convencional. Reinstalação reconhece seu próprio hook e apenas
invalida o cache. Não há compactação de disco, migração de metadados ou novo formato.

Somente um nome+conteúdo ficam em cache. O cache não omite a primeira leitura fria.
Qualquer operação BIOS invalida: esta política reduz oportunidades, mas evita manter
conteúdo após save/delete/format/escrita BIOS direta nos testes. Não existe mecanismo de
detecção de troca física de mídia em um hit sem I/O, nem proteção contra programas que
escrevam sobre a região residente ou substituam os vetores. DMA, controladores e firmware
reais não foram simulados completamente. A compatibilidade é condicional e experimental.

Um programa que espera que o kernel sempre faça uma leitura física não pode supor essa
propriedade depois de ativar fast. Para workflows de mídia intercambiável, deixe-o desligado.

## Medidas, não inferências

`reports/benchmark.json` é gerado executando os mesmos workloads sobre os binários montados.
A baseline montada coincide com o os.img upstream pelo hash de blob Git, e a fonte baseline
coincide byte a byte. Conteúdo de leituras é comparado integralmente, não só o primeiro byte.

As contagens não incluem o tempo dentro de BIOS real. Uma instrução REP é uma instrução
decodificada com múltiplas iterações; por isso reportamos ambos os números. A soma desses
números é apenas uma unidade artificial de trabalho, útil para expor overhead, não um relógio.

Reduzir I/O pode melhorar latência quando I/O domina. Não permite provar uma aceleração
global: o custo das cópias de memória, firmware, mídia, taxa de acerto, tamanho de sequência
e outros caminhos precisa ser medido. Nem “100× menos I/O” nem “43 testes” equivalem a
“5× melhor engenharia” ou “5× mais rápido em tudo”. Não há medição p50/p95/p99 nesta entrega.

## Estado dos gates

| Gate | Resultado nesta entrega |
|---|---|
| Hash da fonte original | PASS |
| Hash do binário original reconstruído | PASS, byte idêntico ao publicado |
| Core, fast e demo com assinatura e 512 bytes | PASS via GNU binutils |
| Testes locais do binário / BIOS doubles / utilitários | PASS, 43 testes |
| Sequências reprodutíveis de filesystem | PASS, 600 sem cache + 600 com cache |
| Shell → fast → demo → demo | PASS no runner parcial |
| Rejeição de nomes longos e preservação de disco | PASS no runner parcial |
| Erro de I/O persistente | Limitação confirmada: retry infinito |
| Comparação NASM × GNU as dos novos fontes | PASS: 4/4 binários byte-idênticos |
| QEMU/SeaBIOS, gate independente | PASS: boot, instalação de `fast` e duas execuções do demo |
| Hardware 8088/8086 e várias BIOS | NOT_RUN |
| Compatibilidade de todos os jogos upstream | NOT_RUN |

Os gates NASM e QEMU foram executados após a entrega original. QEMU verificou a sequência
interativa por QMP, a memória convencional reportada, a instalação do acelerador e a saída
de duas execuções do demo. Isso é um smoke test funcional, não uma medição de desempenho nem
uma prova de equivalência com hardware físico. Resultados detalhados estão em
`reports/validation.json` e `reports/qemu.json`.

## Próximos ataques — propostos, não implementados

### 1. Fechar a validação independente antes de promover o patch

Comparar traces contra outro emulador. Rodar todas as aplicações da imagem upstream, com e sem o cache. Gate: nenhuma regressão funcional,
512 bytes no core, sem alteração de setores não solicitados. Isso trata o risco de o
runner local e o código novo compartilharem a mesma suposição errada.

### 2. Endurecer entrada sem perder o orçamento

Reservar bytes para limite da linha, piso do backspace, nome vazio e fim do buffer de
enter. Testes: todos os tamanhos de nome/linha próximos da borda, sequência longa de
backspaces e 511/512/513 bytes de conteúdo. Não alegar que o suporte a 15 caracteres
na API já resolveu o parser da linha. Se o orçamento não fechar, mover editor para
um programa setorial opcional antes de retirar funcionalidades silenciosamente.

### 3. I/O com falhas finitas e retorno de erro

Definir drive de boot, tentativas limitadas, reset quando apropriado e propagação do erro
até comandos/serviços. Não basta trocar jc disk por ret: o core atual assume que disco
sempre acaba tendo sucesso em múltiplos caminhos. Gate: falha em cada operação de cada
serviço nunca publica sucesso falso, não corrompe metadados e retorna em limite conhecido.

### 4. Consistência dos dados, sem fingir transações

Escrever dados antes de publicar nome reduz um modo de corrupção na criação. Sobrescrita
in-place exige uma decisão explícita sobre cópia alternativa/journal/commit ou aceitação
de não atomicidade. Copiar dados primeiro, isoladamente, não torna sobrescrita atômica.
Manter o formato clássico como modo compatível; um modo transacional novo é outro contrato.

### 5. Cache dimensionado pelo workload

Medir hit rate, reutilização e bytes de RAM antes de expandir para múltiplas entradas ou
pré-carregamento. Expor teste de dois e 32 arquivos; nunca remover benchmarks desfavoráveis.
Comparar 0/2/4/8 KiB com custo de instalação incluído e desligar quando não compensa.
Resolver coerência de mídia removível antes de ativação automática.

### 6. Provar ou rejeitar os 5× de tempo

Usar workloads definidos previamente: boot frio, primeira execução, repetição quente,
execuções alternadas, criação, sobrescrita, diretório cheio, mídia com erro. Separar
QEMU/host-cached image de mídia física. Medir distribuição de latência e média geométrica
somente sobre tarefas comparáveis, incluindo instalação quando relevante. A meta de 5×
é um critério de aceitação, não uma conclusão escolhida antes das medições.

## Integridade do pacote

Os patches são alternativas: core-only contém apenas a modificação de os.asm; full
contém a mesma alteração e acrescenta ferramentas, testes e documentação. Não aplicar
ambos sequencialmente. As evidências de apply/reverse constam em reports/patch-validation.json.
O ZIP contém os fontes de engenharia e imagens prontas, não .git nem o catálogo completo
de programas do upstream. Preserve LICENSE na redistribuição.
