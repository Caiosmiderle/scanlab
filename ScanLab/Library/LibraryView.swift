import SwiftUI
import UIKit

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
                                ScanRow(scan: scan, sizeBytes: store.sizes[scan.id])
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

    /// Tamanho em disco, quando já foi medido.
    var sizeBytes: Int64? = nil

    private var detailText: String {
        var parts: [String] = []
        if scan.isRoomScan {
            let count = scan.rooms?.count ?? 0
            parts.append(count == 1 ? "1 cômodo" : "\(count) cômodos")
            parts.append("planta e USDZ")
        } else {
            parts.append("\(scan.faceCount) triângulos")
            parts.append(scan.status)
        }
        if let sizeBytes = sizeBytes {
            parts.append(AppPaths.formatBytes(sizeBytes))
        }
        return parts.joined(separator: " · ")
    }

    /// Foto do scan, se houver; senão um ícone.
    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: ScanStore.shared.thumbnailURL(for: scan.id).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: scan.isRoomScan ? "house" : "cube.transparent")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.headline)
                Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
