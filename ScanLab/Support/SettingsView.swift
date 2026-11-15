import SwiftUI
import ScanCore

/// Aba "Ajustes": padrão de exportação, diagnóstico do aparelho e logs.
struct SettingsView: View {
    @AppStorage(SettingsKeys.exportUpAxis) private var axisRaw: String = UpAxis.zUp.rawValue
    @AppStorage(SettingsKeys.colorizeOnExport) private var colorizeOnExport: Bool = true
    @AppStorage(SettingsKeys.saveDepth) private var saveDepth: Bool = true
    @AppStorage(SettingsKeys.keyframeInterval) private var keyframeInterval: Double = AppSettings.defaultKeyframeInterval
    @AppStorage(SettingsKeys.keyframeDistanceCm) private var keyframeDistanceCm: Double = AppSettings.defaultKeyframeDistanceCm
    @AppStorage(SettingsKeys.keyframeAngle) private var keyframeAngle: Double = AppSettings.defaultKeyframeAngle
    @AppStorage(SettingsKeys.keyframeMaxCount) private var keyframeMaxCount: Double = AppSettings.defaultKeyframeMaxCount
    @State private var lidarStatus: LidarStatus = LidarSupport.check()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Eixo para cima", selection: $axisRaw) {
                        Text("Z (CAD, CloudCompare, Revit)").tag(UpAxis.zUp.rawValue)
                        Text("Y (ARKit, Blender)").tag(UpAxis.yUp.rawValue)
                    }
                } header: {
                    Text("Exportação")
                    Toggle("Colorir a malha com as fotos", isOn: $colorizeOnExport)
                } footer: {
                    Text("Usado nos arquivos gerados ao finalizar um scan. Dá para gerar de novo com outro eixo na tela do scan.")
                }

                Section {
                    Stepper("Intervalo mínimo: \(String(format: "%.1f", keyframeInterval)) s",
                            value: $keyframeInterval, in: 0.2...2.0, step: 0.1)
                    Stepper("Deslocamento mínimo: \(Int(keyframeDistanceCm)) cm",
                            value: $keyframeDistanceCm, in: 5...50, step: 5)
                    Stepper("Rotação mínima: \(Int(keyframeAngle)) graus",
                            value: $keyframeAngle, in: 5...45, step: 5)
                    Stepper("Máximo por scan: \(Int(keyframeMaxCount))",
                            value: $keyframeMaxCount, in: 100...1000, step: 50)
                    Toggle("Salvar profundidade do LiDAR", isOn: $saveDepth)
                    Button("Restaurar padrões") {
                        keyframeInterval = AppSettings.defaultKeyframeInterval
                        keyframeDistanceCm = AppSettings.defaultKeyframeDistanceCm
                        keyframeAngle = AppSettings.defaultKeyframeAngle
                        keyframeMaxCount = AppSettings.defaultKeyframeMaxCount
                        saveDepth = true
                    }
                } header: {
                    Text("Fotos para cor (keyframes)")
                } footer: {
                    Text("Durante o scan o app guarda uma foto quando passou o intervalo mínimo e a câmera andou ou girou o bastante. Mais fotos dão cor melhor e ocupam mais espaço (cerca de 0,5 a 1 MB por foto). Ao atingir o máximo, o app mantém uma foto sim, outra não, e passa a espaçar mais.")
                }

                Section("Diagnóstico") {
                    HStack {
                        Label(lidarStatus.title, systemImage: lidarStatus.isAvailable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(lidarStatus.isAvailable ? Color.green : Color.red)
                        Spacer()
                        Button("Verificar") {
                            lidarStatus = LidarSupport.check()
                        }
                    }
                    Text(lidarStatus.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    row("Aparelho", DeviceInfo.modelIdentifier)
                    row("Sistema", DeviceInfo.systemVersion)
                    row("Espaço livre", freeSpaceText)
                }

                Section {
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    Text("Registro dos últimos eventos do app. Exporte o arquivo quando algo der errado.")
                }

                Section("Sobre") {
                    row("ScanLab", AppInfo.versionText)
                    row("ScanCore", ScanCoreInfo.version)
                    Text("As medidas são aproximadas. O LiDAR do aparelho acumula erro ao longo do ambiente e não substitui a trena.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    private var freeSpaceText: String {
        if let free = AppPaths.freeDiskBytes() {
            return AppPaths.formatBytes(free)
        }
        return "desconhecido"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
