import SwiftUI

@main
struct ScanLabApp: App {
    init() {
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
