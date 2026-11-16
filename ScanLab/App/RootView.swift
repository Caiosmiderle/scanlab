import SwiftUI

/// Abas principais do app.
struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem {
                    Label("Capturar", systemImage: "viewfinder")
                }

            RoomScanView()
                .tabItem {
                    Label("Cômodo", systemImage: "house")
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
