import SwiftUI

/// Abas principais do app. A aba "Cômodo" (RoomPlan) entra no marco M3.
struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem {
                    Label("Capturar", systemImage: "viewfinder")
                }

            LibraryView()
                .tabItem {
                    Label("Biblioteca", systemImage: "square.stack.3d.up")
                }

            SettingsView()
                .tabItem {
                    Label("Ajustes", systemImage: "gearshape")
                }
        }
    }
}
