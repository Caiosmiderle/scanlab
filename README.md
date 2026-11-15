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
| M0 | Pipeline código → CI → `.ipa` → sideload, tela com status do LiDAR | em teste |
| M1 | Captura da malha LiDAR, export PLY e OBJ | a fazer |
| M2 a M10 | Cor, RoomPlan, biblioteca, viewer, exportações, processamento, editor, medição | a fazer |

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
ScanLab/App/                   ponto de entrada e tela inicial
ScanLab/Support/               utilitários (LiDAR, dados do aparelho)
.github/workflows/             CI que gera o .ipa
```

## Limitações conhecidas

- Só funciona em aparelhos com LiDAR (iPad Pro 2020 em diante, iPhone 12 Pro em diante, linha Pro).
- Somente interiores. Sem GNSS, sem georreferenciamento.
- Sem assinatura própria: depende de sideload e da reinstalação semanal.
