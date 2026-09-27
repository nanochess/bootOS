# bootOS — patch de engenharia e aceleração opcional

**Entrega experimental de 27/09/2026. Não é uma alegação de “sistema inteiro 5× mais rápido”.**

O endereço fornecido, `nanochess/bootOSC`, retornou 404. Este trabalho assume explicitamente
que o alvo pretendido é **nanochess/bootOS**, commit
`e54fffe4243bb77e487798801a3bc4c3e60cb01e` (24/09/2026).
Nenhum repositório remoto foi alterado. O pacote é um conjunto de fontes, ferramentas,
testes e imagens de demonstração; **não é um clone completo do upstream**. Jogos e demais
aplicações de terceiros não foram auditados ou certificados.

## Resultado verificável

| 100 operações lógicas | Upstream: chamadas BIOS de disco | Core: chamadas | Core + fast: chamadas |
|---|---:|---:|---:|
| Ler repetidamente o mesmo arquivo | 200 | 200 | 2 |
| Sobrescrever o mesmo arquivo | 400 | 200 | 200 |
| Alternar a leitura entre dois arquivos | 200 | 200 | 200 |
| Procurar nome inexistente | 100 | 100 | 100 |

A primeira leitura fria está incluída. Instalação do acelerador e boot estão fora da janela.
São contagens de chamadas INT 13h observadas na execução do binário por um runner local
parcial de 8086, com BIOS e disco simulados deterministicamente. **Não são milissegundos,
ciclos de CPU, medições em disquete físico ou resultados de QEMU.**

A redução de 200 para 2 significa 100× menos operações de disco (99% eliminadas),
não 100× menos tempo. Um número maior de repetições pode aumentar essa razão sem melhorar
a primeira leitura: ela depende do workload e do estado do cache.

No caso desfavorável de alternar dois arquivos, a instrumentação conta **4,34× mais unidades
de trabalho do guest** com fast, sem economizar chamadas de disco. Essa unidade é a soma
arbitrada de instruções decodificadas e iterações de instruções de string; **não equivale a
ciclos nem prova regressão de 4,34× no tempo**. O JSON mantém essas duas contagens separadas.

O core também paga pelo limite de nomes: nas 100 leituras repetidas, sobe de 9.100 para
10.100 instruções decodificadas. Segurança de limites não foi apresentada como ganho de CPU.

## O que mudou

### Core, mantendo 512 bytes

`os.asm` foi refatorado, não substituído por outro sistema. Preserva CPU 8086, assinatura
55 aa, posições de memória, seis serviços INT 20h–25h e layout CHS dos arquivos.
O payload montado ocupa 509 bytes; há 1 byte de preenchimento e 2 de assinatura.

* A realocação copia 256 words, em vez de 512 bytes por iterações separadas.
* Sobrescrever arquivo existente mantém seu slot e grava somente os dados: elimina duas
  gravações de diretório por operação. Não passa mais por delete seguido de recriação.
* A busca examina no máximo 16 bytes do nome: nomes com 16 ou mais caracteres sem NUL
  nesse limite retornam CF=1, sem escrita no disco. O limite válido é 15 + NUL.
* CLD protege as operações de string quando o chamador entrou no serviço com DF=1;
  IRET restaura o DF do chamador.

A rejeição ocorre depois da leitura do diretório: não elimina I/O de entrada inválida e
não resolve o retry infinito se o disco estiver indisponível.

### `fast.asm`, opcional

Programa normal de 512 bytes, payload 269 bytes. Executá-lo como `fast` instala um
acelerador residente que **reserva 2 KiB adicionais** no topo da memória convencional
reportada pela BIOS. O núcleo continua 512 bytes, mas a solução acelerada obviamente usa
mais memória e um arquivo extra no disco; não é “cache grátis dentro de 512 bytes”.

Mantém um único arquivo completo de 512 bytes em memória. Intercepta INT 23h para
atender acertos sem disco e INT 13h para invalidar o cache em **qualquer** operação BIOS.
Save, delete, format e escrita BIOS direta foram exercitados nos testes. BX no retorno
é compatível com o caminho de execução do shell, que salta para BX.

**Contrato e riscos:** usar preferencialmente com uma imagem fixa no emulador. Uma troca
física de mídia sem uma chamada BIOS intermediária não é detectada em um acerto de cache.
Executar `fast` novamente invalida o cache, sem reservar outra região. Para mídia removível,
a opção mais segura é reiniciar após a troca, sem acelerador. Programas precisam respeitar
a memória convencional reservada e não sobrescrever os vetores. O ambiente não tem
proteção de memória: essa reserva é cooperativa, não isolamento de segurança. Reiniciar
remove o acelerador. Ele não altera o boot sector nem o layout do disco.

**O cache não é ativado por padrão.** Alternância de arquivos e workloads sem reutilização
não são beneficiados. Não foi feita certificação de compatibilidade dos jogos do upstream.

## Build, testes e demonstração

Requer Linux, Python 3.10+ e GNU binutils (`as`, `ld`, `objcopy`, `nm`); `make` é usado
como conveniência. O build original com NASM continua disponível no Makefile original.
O tradutor alternativo aceita apenas o subconjunto NASM usado por estas fontes.

```sh
make -f Makefile.engineering verify
make -f Makefile.engineering benchmark
```

A baseline vendorizada foi verificada pelos hashes de blob Git:

```text
os.asm: 7365e404118f5a8bcf245447dfe0df5fffa69963
os.img: e48996807e07a128e7861587aebf86d6f2063fa7
```

**O assembler alternativo reproduziu byte a byte o binário upstream publicado.** Isso
valida esta baseline; não substitui a comparação independente do novo código com NASM.

No ambiente desta entrega: **43 testes concluídos com sucesso**, inclusive duas sequências
pseudoaleatórias reprodutíveis de 600 operações cada e um caminho completo
shell → `fast` → `demo` → `demo`. Cinco testes são diagnósticos que reproduzem defeitos ou
limitações; sua aprovação não significa que essas limitações foram resolvidas.

Com NASM e QEMU instalados, executar os gates independentes:

```sh
make -f Makefile.engineering nasm-check
make -f Makefile.engineering qemu-smoke
```

Na execução original desta entrega, NASM e QEMU não estavam disponíveis. Em uma validação
posterior, ambos foram executados: NASM confirmou 4/4 binários idênticos e o smoke test QEMU
passou pelo boot, instalação do `fast` e duas execuções do demo. Veja `reports/validation.json`
e `reports/qemu.json`. O smoke test não prova compatibilidade temporal ou elétrica com um PC real.

Para abrir manualmente a imagem de demonstração que acompanha o ZIP:

```sh
qemu-system-i386 -drive file=build/demo-disk.img,format=raw,if=floppy -boot a -snapshot
```

No shell do bootOS:

```text
dir
demo
fast
demo
demo
```

A imagem já está inicializada; não precisa de `format`. São imagens de laboratório,
não instaladores para seu disco de trabalho. O modo snapshot evita persistir modificações.

Para gerar outra imagem, o gerador recusa sobrescrever um arquivo existente:

```sh
python3 tools/demo_image.py --output build/minha-demo.img
```

## Ferramentas de imagem, sem escrever em dispositivos

```sh
python3 tools/image.py check build/demo-disk.img
python3 tools/image.py ls build/demo-disk.img
python3 tools/image.py create build/novo.img --boot build/core.img --size 360
python3 tools/image.py put build/novo.img fast build/fast.img --output build/com-fast.img
python3 tools/image.py upgrade osall.img --boot build/core.img --output build/osall-core.img
```

O último comando preserva todos os bytes posteriores ao boot sector; só deve ser usado
com uma imagem bootOS válida. Não converte FAT, não instala em USB, não reordena slots.
Entradas duplicadas, sem terminador ou não imprimíveis são recusadas. Novos nomes precisam
ser ASCII imprimível, sem espaços, com 1–15 caracteres. O utilitário não corrige a regra de
prefixos do shell: evite nomes iniciados por `dir`, `del`, `ver`, `format` ou `enter`.

O utilitário aceita somente arquivos regulares, rejeita symlinks e dispositivos, exige
saída separada e publica via arquivo temporário. Saídas existentes exigem `--force`.
Essa publicação atômica **no host** não deve ser confundida com atomicidade do sistema de
arquivos **dentro do bootOS**, que continua limitada.

## Aplicar e reverter o patch

O patch completo é aplicado sobre o upstream; o patch menor contém somente `os.asm`.
Eles são alternativas: **não aplique os dois na mesma árvore**.
Faça backup ou use um worktree limpo. Partindo do clone do repositório correto:

```sh
git rev-parse HEAD
# Base desta entrega: e54fffe4243bb77e487798801a3bc4c3e60cb01e
git status --short
git apply --check /caminho/bootOS-Engineering.patch
git apply /caminho/bootOS-Engineering.patch
make -f Makefile.engineering verify
```

A distribuição preserva o Makefile, README, jogos e imagens rastreadas do upstream.
O patch não atualiza seu `os.img` rastreado; use o novo `build/core.img` ou recompile.
Não use `--reject` para mascarar divergências de base.

Reversão do patch, sem alterações posteriores conflitantes:

```sh
git apply -R --check /caminho/bootOS-Engineering.patch
git apply -R /caminho/bootOS-Engineering.patch
```

A reversão não apaga imagens geradas posteriormente em `build/`. Não há comandos
`git reset --hard`, formatação de dispositivos ou alteração remota neste fluxo.

## Limites que continuam abertos

A interface de linha ainda admite overflow e backspace abaixo do buffer. O editor
hexadecimal ainda não tem limites/validação completos. Nome vazio ainda é aceito pela
API. A BIOS de disco ainda é chamada em loop infinito de retry e força drive A.
O retorno original dos serviços desloca outros bits aritméticos de FLAGS.
A criação ainda publica metadados antes dos dados e não é transacional; sobrescrita
in-place também não é atômica contra queda de energia. O parser ainda compara prefixos
de comandos. Não há segurança contra programas hostis no mesmo espaço de memória.

Esses pontos estão no relatório técnico. Não use esta entrega como sistema endurecido
para dados importantes ou como prova de uma melhora global de cinco vezes.

## Evidências e licença

`reports/benchmark.json`: contagens e hashes; `reports/tests.log`: saída dos testes;
`reports/qemu.json`: NOT_RUN neste ambiente; `docs/AUDITORIA.md`: análise e próximos gates.
`tests/minipc.py` executa bytes reais, mas é um runner parcial criado neste trabalho.
Falha em instruções não implementadas; não é um emulador 8086 completo ou independente.
Todos os fontes são distribuídos sob a licença BSD-2-Clause incluída em `LICENSE`,
preservando os créditos e termos do upstream.
