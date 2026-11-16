# ScanLab

App pessoal para iPad e iPhone com LiDAR: escaneia interiores, salva o bruto, processa
no próprio aparelho e exporta em formatos abertos (PLY, OBJ, LAS, USDZ e outros), sem
paywall, sem login e sem enviar nada para servidor.

Construído só com APIs públicas da Apple (ARKit, RealityKit, RoomPlan, ModelIO,
SceneKit, Metal). Interface, textos e identidade próprios.

> **Medidas aproximadas.** O LiDAR de iPad/iPhone não é instrumento de medição: o erro
> cresce com o tamanho do ambiente e a deriva se acumula. Use trena para o que importa.

## Estado atual

| Marco | Conteúdo | Situação |
|---|---|---|
| M0 | Pipeline código → CI → `.ipa` → sideload, tela com status do LiDAR | aceito (iPad Pro M2 e iPhone 15 Pro, sistema 27) |
| M1 | Captura da malha LiDAR, bruto `mesh.bin`, export PLY e OBJ, biblioteca básica, logs | aceito |
| M2A | Keyframes (foto + pose) durante o scan e cor por vértice no PLY e no OBJ | aceito |
| M2B | Teste de oclusão com o mapa de profundidade e mistura das melhores fotos | aceito |
| M3 | Aba Cômodo (RoomPlan): USDZ, JSON do cômodo, vários cômodos e planta baixa em SVG | em teste |
| M4 a M10 | Biblioteca completa, viewer, exportações, processamento, editor, medição | a fazer |

## Cômodo e planta baixa (M3)

A aba **Cômodo** usa o RoomPlan da Apple: você contorna o cômodo com o iPad e ele
reconhece paredes, portas, janelas e vãos. Ao tocar em **Concluir cômodo** aparecem a
área, o perímetro e o pé-direito aproximados. Daí dá para:

- **Outro cômodo:** continuar no cômodo seguinte sem sair da tela. Como a sessão de AR
  não é interrompida, todos ficam no mesmo sistema de coordenadas e entram na mesma planta.
- **Salvar:** grava o item na Biblioteca.

O que é gravado em `Documents/Scans/<id>/`:

| Arquivo | Conteúdo |
|---|---|
| `rooms/comodo-N.json` | o cômodo como o RoomPlan entregou (`CapturedRoom` em JSON) |
| `plan.json` | paredes, aberturas e contorno em estruturas simples, usadas para a planta |
| `outputs/planta-<id>.svg` | planta baixa: paredes, portas (laranja), janelas (azul), vãos (tracejado), cota de cada parede, nome e área de cada cômodo, barra de escala de 1 m |
| `outputs/comodo-N-malha.usdz` | modelo 3D com os vãos recortados nas paredes |
| `outputs/comodo-N-parametrico.usdz` | modelo 3D em caixas simples, mais fácil de editar |
| `outputs/apartamento-<id>.usdz` | todos os cômodos juntos (quando há mais de um) |

A área vem do contorno do piso que o RoomPlan entrega; se não houver, do polígono
formado pelas paredes; se as paredes não fecharem, a planta mostra só as cotas.

## Como usar (M1)

1. Aba **Capturar** → **Iniciar**. Na primeira vez o iPad pede permissão de câmera.
2. Ande devagar pelo ambiente. A malha aparece desenhada por cima da câmera; o topo da tela mostra tempo, blocos de malha, triângulos e temperatura.
3. **Finalizar** grava o bruto e gera PLY e OBJ. **Pausar** segura a sessão; **Cancelar** descarta.
4. Aba **Biblioteca** → toque no scan para ver os dados, gerar de novo com outro eixo, compartilhar ou apagar.
5. Aba **Ajustes** → eixo padrão de exportação, diagnóstico e **Logs** (com botão de exportar o arquivo).

O que é gravado para cada scan, em `Documents/Scans/<id>/`:

| Arquivo | Conteúdo |
|---|---|
| `meta.json` | nome, data, aparelho, versão do app, contagens |
| `mesh.bin` | malha bruta do LiDAR, por bloco, no formato próprio `SLMESH01` (nunca é sobrescrita) |
| `frames/000012.jpg` | fotos (keyframes) em JPEG, na orientação nativa do sensor |
| `frames.json` | para cada foto: índice, timestamp, pose da câmera (16 floats), intrínsecas (9 floats) e resolução |
| `depth/000012.bin` | mapa de profundidade do LiDAR da mesma foto (formato `SLDEPTH1`: milímetros em 16 bits + confiança) |
| `outputs/scan-<id>-zup.ply` | malha em PLY binário, com normais, cor por vértice e classificação por face |
| `outputs/scan-<id>-zup.obj` + `.mtl` | a mesma malha em OBJ, com cor por vértice (`v x y z r g b`) |

### Como a cor é calculada (M2A)

Durante o scan o app salva uma foto quando passaram 0,4 s desde a última **e** a câmera
andou mais de 15 cm **ou** girou mais de 15 graus (valores ajustáveis em Ajustes; teto de
400 fotos). Na exportação, cada vértice da malha recebe a cor da foto que o vê melhor:
de frente (normal apontando para a câmera), de perto e longe da borda da imagem.

**Oclusão (M2B).** Uma foto é descartada para um vértice se o LiDAR mediu, naquele pixel,
uma superfície mais próxima que o vértice (tolerância de 5 cm + 3% da distância): há um
móvel ou uma parede na frente, e a cor ali não é a do vértice. O teste usa a superfície
mais próxima numa janela de 3 x 3 pixels, para a cor do objeto da frente não vazar para
a parede atrás dele. Onde não há medida confiável, a foto ainda vale, com metade da nota.

**Mistura.** A cor final é a média ponderada de até 3 fotos (as que têm pelo menos 60% da
melhor nota), o que suaviza as diferenças de exposição entre fotos vizinhas.

Dá para desligar o teste de oclusão em Ajustes e gerar de novo, para comparar.

O sufixo é `zup` (Z para cima, padrão de CAD e CloudCompare) ou `yup` (Y para cima, como no ARKit).
A conversão é `(x, y, z) → (x, -z, y)`.

## Princípios de interface

- iPad primeiro, funciona no iPhone. Tema escuro, textos em português, ícones SF Symbols.
- **Apple Pencil:** todo controle precisa funcionar bem com o Pencil, não só com o dedo. Alvos de toque de pelo menos 44 pt, efeito de hover nos botões (o iPad Pro M2 mostra o hover do Pencil) e campos de texto que aceitam escrita à mão. Nas telas de precisão que ainda vêm (visualizador, editor de corte, medição), o Pencil é a ferramenta principal de apontar.

## Como o app é compilado

Não há Mac no projeto. Todo build acontece no GitHub Actions (runner macOS):

1. `swift test` roda os testes do pacote `Packages/ScanCore` (lógica sem ARKit).
2. O [XcodeGen](https://github.com/yonaskolb/XcodeGen) gera o `ScanLab.xcodeproj` a partir do `project.yml` (o `.xcodeproj` não é commitado).
3. `xcodebuild` compila para `iphoneos` **sem assinatura**.
4. O `.app` é empacotado em `ScanLab.ipa` e publicado como artifact `ScanLab-ipa`.

O workflow está em [.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml) e roda
a cada push na `main`, em pull requests e manualmente (aba Actions → build-ipa → Run workflow).

## Baixar o `.ipa`

Pelo navegador (precisa estar logado no GitHub):

1. Abra a aba **Actions** do repositório e clique na execução verde mais recente de `build-ipa`.
2. No fim da página, em **Artifacts**, baixe `ScanLab-ipa`.
3. Extraia o zip baixado: dentro dele está o `ScanLab.ipa`.

Pelo terminal, com o GitHub CLI:

```bash
gh run download --repo Caiosmiderle/scanlab --name ScanLab-ipa --dir scanlab-ipa
```

## Instalar no iPad pelo Windows

O `.ipa` sai do CI sem assinatura. A ferramenta de sideload assina com o seu Apple ID
na hora de instalar.

### Sideloadly (caminho principal)

1. Instale o **iTunes** e o **iCloud** pelos instaladores do site da Apple (não os da Microsoft Store), como o Sideloadly pede.
2. Instale e abra o [Sideloadly](https://sideloadly.io).
3. Conecte o iPad por cabo, desbloqueie e toque em **Confiar** neste computador.
4. Arraste o `ScanLab.ipa` para a janela do Sideloadly, escolha o iPad e informe o seu Apple ID.
5. Clique em **Start** e aguarde a mensagem de conclusão.
6. No iPad: **Ajustes → Geral → VPN e Gerenciamento de Dispositivos** → toque no seu Apple ID → **Confiar**.
7. Se o app não abrir, ative **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor** (o iPad reinicia) e abra de novo.

### AltStore (alternativa)

1. Instale o AltServer no Windows (site do AltStore) e, por ele, instale o AltStore no iPad.
2. No iPad, abra o AltStore → **My Apps** → **+** e escolha o `ScanLab.ipa` (copie o arquivo para o iPad antes, pelo app Arquivos).
3. Confie no perfil do desenvolvedor como no passo 6 acima.

### Limites do Apple ID gratuito

- O app **expira em 7 dias**. Depois disso ele não abre até ser reinstalado (ou renovado pela ferramenta de sideload).
- Reinstalar por cima, com o mesmo Apple ID e o mesmo bundle id (`com.caio.scanlab`), **mantém os scans** guardados no app. Apagar o app apaga os scans.
- A Apple limita a 3 apps de sideload ativos por aparelho e a 10 identificadores de app novos a cada 7 dias.

## Tirar os scans do aparelho

A pasta **Documents** do app aparece no app **Arquivos** do iPad, em
*No Meu iPad → ScanLab*. A partir do M1 os scans ficam em `Scans/<id>/`.

## Estrutura

```
project.yml                    definição do projeto (XcodeGen)
Packages/ScanCore/             lógica testável, só Foundation e simd
                               (mesh.bin, PLY, OBJ, eixos, montagem da malha)
ScanLab/App/                   ponto de entrada e abas
ScanLab/Capture/               sessão ARKit, leitura da malha, HUD
ScanLab/Library/               lista de scans, detalhe, armazenamento em disco
ScanLab/Export/                geração dos arquivos de saída
ScanLab/Support/               logs, caminhos, ajustes, LiDAR, estado térmico
ScanLab/Resources/             ícone do app
.github/workflows/             CI que gera o .ipa
```

## Limitações conhecidas

- Só funciona em aparelhos com LiDAR (iPad Pro 2020 em diante, iPhone 12 Pro em diante, linha Pro).
- Somente interiores. Sem GNSS, sem georreferenciamento.
- Sem assinatura própria: depende de sideload e da reinstalação semanal.
