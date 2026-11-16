import SwiftUI
import ScanCore

/// Estado de uma exportação em andamento, observado pela tela de detalhe.
final class ExportJob: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var resultText: String? = nil
    @Published var errorMessage: String? = nil

    func start(scanID: String, axis: UpAxis) {
        if isRunning {
            return
        }
        isRunning = true
        progress = 0
        message = "Preparando..."
        resultText = nil
        errorMessage = nil

        // Trabalho pesado fora da thread principal; a interface só recebe o progresso.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try MeshExporter.exportPLYAndOBJ(scanID: scanID, axis: axis, colorize: AppSettings.colorizeOnExport) { fraction, text in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.message = text
                    }
                }
                let text = "Arquivos gerados em \(String(format: "%.1f", result.seconds)) s."
                DispatchQueue.main.async {
                    self.resultText = text
                    self.isRunning = false
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.export, "Falha ao exportar o scan \(scanID): \(text)")
                DispatchQueue.main.async {
                    self.errorMessage = text
                    self.isRunning = false
                }
            }
        }
    }
}

/// Detalhe de um scan: informações, exportação e arquivos gerados.
struct ScanDetailView: View {
    let scanID: String

    @ObservedObject private var store = ScanStore.shared
    @StateObject private var job = ExportJob()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.exportUpAxis) private var axisRaw: String = UpAxis.zUp.rawValue
    @State private var outputFiles: [URL] = []
    @State private var diskSize: Int64 = 0
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showDeleteConfirmation = false
    @State private var shareRequest: ShareRequest? = nil
    @State private var isZipping = false
    @State private var shareError: String? = nil

    private var scan: ScanMeta? {
        return store.scans.first { $0.id == scanID }
    }

    var body: some View {
        Group {
            if let scan = scan {
                content(scan)
            } else {
                ContentUnavailableView("Scan não encontrado",
                                       systemImage: "questionmark.folder",
                                       description: Text("Ele pode ter sido apagado."))
            }
        }
        .onAppear {
            refreshFiles()
        }
        .onChange(of: job.isRunning) { _, running in
            if !running {
                refreshFiles()
            }
        }
    }

    private func content(_ scan: ScanMeta) -> some View {
        List {
            if scan.isRoomScan {
                // Item do RoomPlan: não há malha para exportar, só as medidas dos cômodos.
                Section {
                    infoRow("Data", scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(scan.rooms ?? [], id: \.name) { summary in
                        RoomSummaryRow(summary: summary)
                            .padding(.vertical, 4)
                    }
                    infoRow("Tamanho em disco", AppPaths.formatBytes(diskSize))
                } header: {
                    Text("Cômodos")
                } footer: {
                    Text("Medidas aproximadas, calculadas pelo RoomPlan. Confira com a trena. A planta está no arquivo .svg e o modelo 3D nos arquivos .usdz.")
                }
            } else {
            Section("Informações") {
                infoRow("Data", scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                infoRow("Duração", formatDuration(scan.durationSeconds))
                infoRow("Triângulos", "\(scan.faceCount)")
                infoRow("Vértices", "\(scan.vertexCount)")
                infoRow("Blocos de malha", "\(scan.anchorCount)")
                infoRow("Fotos para cor", (scan.keyframeCount ?? 0) > 0 ? "\(scan.keyframeCount ?? 0)" : "nenhuma (scan sem cor)")
                infoRow("Classificação", scan.reconstructionMode == "meshWithClassification" ? "Sim" : "Não")
                infoRow("Tamanho em disco", AppPaths.formatBytes(diskSize))
                infoRow("Situação", scan.status)
            }

            Section {
                Picker("Eixo para cima", selection: $axisRaw) {
                    Text("Z (CAD, CloudCompare)").tag(UpAxis.zUp.rawValue)
                    Text("Y (ARKit, Blender)").tag(UpAxis.yUp.rawValue)
                }
                .pickerStyle(.segmented)
                .disabled(job.isRunning)

                if job.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: job.progress)
                        Text(job.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        job.start(scanID: scan.id, axis: UpAxis(rawValue: axisRaw) ?? .zUp)
                    } label: {
                        Label("Gerar PLY e OBJ", systemImage: "square.and.arrow.down.on.square")
                    }
                }

                if let resultText = job.resultText {
                    Label(resultText, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let errorMessage = job.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Exportar")
            } footer: {
                Text("Os arquivos são gerados a partir do bruto do scan, que nunca é alterado. Medidas aproximadas: confira com a trena.")
            }
            }

            Section {
                if outputFiles.isEmpty {
                    Text("Nenhum arquivo gerado ainda.")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        shareZip(scanID: scan.id)
                    } label: {
                        HStack {
                            Label("Compartilhar tudo em ZIP", systemImage: "doc.zipper")
                            Spacer()
                            if isZipping {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isZipping || job.isRunning)

                    ForEach(outputFiles, id: \.self) { file in
                        Button {
                            share(file)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.lastPathComponent)
                                        .font(.callout)
                                    Text(fileDetail(file))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(job.isRunning)
                    }
                }

                if let shareError = shareError {
                    Label(shareError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Arquivos")
            } footer: {
                Text("O ZIP leva todos os arquivos com os nomes originais; é o jeito mais seguro de mandar o OBJ, que precisa do .mtl ao lado. Eles também estão no app Arquivos, em No Meu iPad → ScanLab → Scans → \(scan.id) → outputs.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Apagar scan", systemImage: "trash")
                }
                .disabled(job.isRunning)
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draftName = scan.name
                    showRename = true
                } label: {
                    Label("Renomear", systemImage: "pencil")
                }
            }
        }
        .alert("Renomear scan", isPresented: $showRename) {
            TextField("Nome", text: $draftName)
            Button("Salvar") {
                store.rename(id: scan.id, to: draftName)
            }
            Button("Cancelar", role: .cancel) {
            }
        }
        .sheet(item: $shareRequest) { request in
            ActivityView(urls: request.urls)
                .presentationDetents([.medium, .large])
        }
        .alert("Apagar este scan?", isPresented: $showDeleteConfirmation) {
            Button("Apagar", role: .destructive) {
                store.delete(id: scan.id)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {
            }
        } message: {
            Text("O bruto e todos os arquivos exportados serão apagados do aparelho.")
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Compartilhamento

    /// O `.mtl` que acompanha um `.obj` (mesmo nome, outra extensão), se existir.
    private func materialFile(for file: URL) -> URL? {
        guard file.pathExtension.lowercased() == "obj" else {
            return nil
        }
        let material = file.deletingPathExtension().appendingPathExtension("mtl")
        return FileManager.default.fileExists(atPath: material.path) ? material : nil
    }

    private func fileDetail(_ file: URL) -> String {
        let size = AppPaths.formatBytes(AppPaths.fileSize(file))
        if materialFile(for: file) != nil {
            return "\(size) · vai junto com o .mtl"
        }
        return size
    }

    private func share(_ file: URL) {
        shareError = nil
        var urls = [file]
        // O OBJ referencia o material pelo nome do arquivo: os dois precisam ir juntos.
        if let material = materialFile(for: file) {
            urls.append(material)
        }
        shareRequest = ShareRequest(urls: urls)
    }

    private func shareZip(scanID: String) {
        if isZipping {
            return
        }
        isZipping = true
        shareError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = try ZipArchiver.zipOutputs(scanID: scanID)
                DispatchQueue.main.async {
                    isZipping = false
                    shareRequest = ShareRequest(urls: [zipURL])
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.export, "Falha ao gerar o ZIP do scan \(scanID): \(text)")
                DispatchQueue.main.async {
                    isZipping = false
                    shareError = "Não foi possível gerar o ZIP: \(text)"
                }
            }
        }
    }

    private func refreshFiles() {
        outputFiles = store.outputFiles(for: scanID)
        diskSize = store.diskSize(of: scanID)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d min %02d s", total / 60, total % 60)
    }
}
