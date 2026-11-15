import SwiftUI

/// Ajustes → Logs: mostra os últimos eventos e exporta o arquivo de log (seção 6.5).
struct LogsView: View {
    @State private var text = ""
    @State private var showClearConfirmation = false

    private let maxLines = 400

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Sem registros." : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }

                ShareLink(item: AppLog.shared.fileURL) {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Limpar", systemImage: "trash")
                }
            }
        }
        .alert("Limpar os logs?", isPresented: $showClearConfirmation) {
            Button("Limpar", role: .destructive) {
                AppLog.shared.clear()
                reload()
            }
            Button("Cancelar", role: .cancel) {
            }
        }
        .onAppear {
            reload()
        }
    }

    private func reload() {
        text = AppLog.shared.readTail(maxLines: maxLines)
    }
}
