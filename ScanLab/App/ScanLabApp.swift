import SwiftUI

@main
struct ScanLabApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                // Tema escuro por padrão (seção 7 da especificação).
                .preferredColorScheme(.dark)
        }
    }
}
