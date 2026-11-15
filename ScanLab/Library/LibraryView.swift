import SwiftUI

/// Aba "Biblioteca": lista básica dos scans salvos (a versão completa é o marco M4).
struct LibraryView: View {
    @ObservedObject private var store = ScanStore.shared
    @State private var pendingDelete: ScanMeta? = nil

    var body: some View {
        NavigationStack {
            Group {
                if store.scans.isEmpty {
                    ContentUnavailableView("Nenhum scan ainda",
                                           systemImage: "square.stack.3d.up.slash",
                                           description: Text("Faça um scan na aba Capturar. Ele aparece aqui quando você finalizar."))
                } else {
                    List {
                        ForEach(store.scans) { scan in
                            NavigationLink {
                                ScanDetailView(scanID: scan.id)
                            } label: {
                                ScanRow(scan: scan)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = scan
                                } label: {
                                    Label("Apagar", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Biblioteca")
            .onAppear {
                store.reload()
            }
            .alert("Apagar este scan?", isPresented: deleteBinding, presenting: pendingDelete) { scan in
                Button("Apagar", role: .destructive) {
                    store.delete(id: scan.id)
                }
                Button("Cancelar", role: .cancel) {
                }
            } message: { scan in
                Text("\"\(scan.name)\" e todos os arquivos exportados dele serão apagados do aparelho.")
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        return Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        )
    }
}

private struct ScanRow: View {
    let scan: ScanMeta

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.headline)
                Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(scan.faceCount) triângulos · \(scan.status)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
