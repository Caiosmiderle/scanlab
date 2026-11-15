import SwiftUI

@main
struct ScanLabApp: App {
    init() {
        // Se o app foi fechado à força no meio de um scan, sobram fotos na pasta de captura.
        KeyframeRecorder.removeStaleCaptures()
        AppLog.info(.app, "App iniciado: versão=\(AppInfo.versionText) aparelho=\(DeviceInfo.modelIdentifier) sistema=\(DeviceInfo.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Tema escuro por padrão (seção 7 da especificação).
                .preferredColorScheme(.dark)
        }
    }
}
