import SwiftUI
import ScanCore

/// Tela "Opções de exportação": o que gerar, com que eixo, limpeza e densidade.
/// As escolhas ficam salvas e valem para todos os scans (e para o export automático
/// ao finalizar uma captura).
struct ExportOptionsView: View {
    /// Se o scan tem fotos; sem fotos, as opções de cor não fazem efeito.
    let hasKeyframes: Bool

    @AppStorage(SettingsKeys.exportFormats) private var formatsText: String = AppSettings.defaultExportFormats
    @AppStorage(SettingsKeys.exportUpAxis) private var axisRaw: String = UpAxis.zUp.rawValue
    @AppStorage(SettingsKeys.cloudDensity) private var densityRaw: String = CloudDensity.vertices.rawValue
    @AppStorage(SettingsKeys.colorizeOnExport) private var colorize: Bool = true
    @AppStorage(SettingsKeys.useOcclusion) private var useOcclusion: Bool = true
    @AppStorage(SettingsKeys.weldVertices) private var weld: Bool = true
    @AppStorage(SettingsKeys.removeSmallComponents) private var removeSmall: Bool = true
    @AppStorage(SettingsKeys.textureProfile) private var textureRaw: String = TextureProfile.off.rawValue
    @AppStorage(SettingsKeys.reduceMesh) private var reduce: Bool = false
    @AppStorage(SettingsKeys.smoothMesh) private var smooth: Bool = false

    var body: some View {
        Form {
            Section {
                ForEach(ExportFormat.meshFormats) { format in
                    formatToggle(format)
                }
            } header: {
                Text("Malha")
            } footer: {
                Text("GLB, glTF e USDZ saem sempre com Y para cima, porque o próprio padrão desses formatos define o eixo.")
            }

            Section {
                ForEach(ExportFormat.cloudFormats) { format in
                    formatToggle(format)
                }
                Picker("Densidade", selection: $densityRaw) {
                    ForEach(CloudDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
            } header: {
                Text("Nuvem de pontos")
            } footer: {
                Text("\"Vértices da malha\" é a nuvem mais leve. As opções densas espalham pontos sobre as faces da malha: quanto menor o espaçamento, maior o arquivo e o tempo.")
            }

            Section {
                Picker("Eixo para cima", selection: $axisRaw) {
                    Text("Z (CAD, CloudCompare, Revit)").tag(UpAxis.zUp.rawValue)
                    Text("Y (ARKit, Blender)").tag(UpAxis.yUp.rawValue)
                }
            } header: {
                Text("Eixo")
            }

            Section {
                Toggle("Colorir com as fotos", isOn: $colorize)
                Toggle("Testar oclusão com a profundidade", isOn: $useOcclusion)
                    .disabled(!colorize)
            } header: {
                Text("Cor")
            } footer: {
                Text(hasKeyframes ? "A cor vem das fotos salvas durante o scan." : "Este scan não tem fotos salvas, então sai sem cor.")
            }

            Section {
                Picker("Textura", selection: $textureRaw) {
                    ForEach(TextureProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Reduzir a malha pela metade", isOn: $reduce)
                Toggle("Suavizar", isOn: $smooth)
            } header: {
                Text("Processamento")
            } footer: {
                Text("A textura cola as fotos sobre o modelo, com muito mais detalhe que a cor por vértice, e vale para OBJ, GLB e USDZ. Rápido usa uma imagem de 4096 px; HD usa 8192 px e demora mais. Reduzir corta cerca de metade dos triângulos. Suavizar tira o ruído do sensor e arredonda um pouco as quinas.")
            }

            Section {
                Toggle("Soldar vértices duplicados", isOn: $weld)
                Toggle("Remover pedaços soltos pequenos", isOn: $removeSmall)
            } header: {
                Text("Limpeza")
            } footer: {
                Text("Soldar junta os vértices repetidos na divisa dos blocos da malha. Pedaços com menos de \(ExportOptions.smallComponentFaces) triângulos são removidos. O bruto do scan nunca é alterado.")
            }
        }
        .navigationTitle("Opções de exportação")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selected: Set<String> {
        var result: Set<String> = []
        for name in formatsText.split(separator: ",") {
            result.insert(String(name))
        }
        return result
    }

    private func formatToggle(_ format: ExportFormat) -> some View {
        let binding = Binding<Bool>(
            get: { selected.contains(format.rawValue) },
            set: { isOn in
                var names = selected
                if isOn {
                    names.insert(format.rawValue)
                } else {
                    names.remove(format.rawValue)
                }
                // Grava na ordem fixa do enum, para o texto salvo ser estável.
                formatsText = ExportFormat.allCases.filter { names.contains($0.rawValue) }.map { $0.rawValue }.joined(separator: ",")
            }
        )
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(format.title)
                Text(format.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
