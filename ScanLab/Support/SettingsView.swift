import SwiftUI
import ScanCore

/// Aba "Ajustes": padrão de exportação, diagnóstico do aparelho e logs.
struct SettingsView: View {
    @AppStorage(SettingsKeys.exportUpAxis) private var axisRaw: String = UpAxis.zUp.rawValue
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
                } footer: {
                    Text("Usado nos arquivos gerados ao finalizar um scan. Dá para gerar de novo com outro eixo na tela do scan.")
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
