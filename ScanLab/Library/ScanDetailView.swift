import SwiftUI
import UIKit
import ScanCore

/// Estado de uma exportação em andamento, observado pela tela de detalhe.
final class ExportJob: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var resultText: String? = nil
    @Published var errorMessage: String? = nil

    private var cancelFlag = CancelFlag()

    func start(scanID: String, options: ExportOptions) {
        if isRunning {
            return
        }
        isRunning = true
        progress = 0
        message = "Preparando..."
        resultText = nil
        errorMessage = nil
        let flag = CancelFlag()
        cancelFlag = flag

        // Trabalho pesado fora da thread principal; a interface só recebe o progresso.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try MeshExporter.export(scanID: scanID, options: options, cancel: flag) { fraction, text in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.message = text
                    }
                }
                var text = "\(result.files.count) arquivos gerados em \(String(format: "%.1f", result.seconds)) s."
                var failureText: String? = nil
                if !result.failures.isEmpty {
                    text += " \(result.failures.count) formato(s) falharam."
                    failureText = result.failures.joined(separator: "\n")
                }
                DispatchQueue.main.async {
                    self.resultText = text
                    self.errorMessage = failureText
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

    /// Pede para parar. A exportação para na próxima troca de etapa.
    func cancel() {
        cancelFlag.cancel()
        message = "Cancelando..."
    }
}

/// Detalhe de um item da biblioteca: informações, processamento e arquivos gerados.
struct ScanDetailView: View {
    let scanID: String

    @ObservedObject private var store = ScanStore.shared
    @StateObject private var job = ExportJob()
    @Environment(\.dismiss) private var dismiss

    // Só para a tela se redesenhar quando as opções mudarem na tela de opções.
    @AppStorage(SettingsKeys.exportFormats) private var formatsText: String = AppSettings.defaultExportFormats
    @AppStorage(SettingsKeys.exportUpAxis) private var axisRaw: String = UpAxis.zUp.rawValue
    @AppStorage(SettingsKeys.textureProfile) private var textureRaw: String = TextureProfile.off.rawValue
    @AppStorage(SettingsKeys.reduceMesh) private var reduceMesh: Bool = false
    @AppStorage(SettingsKeys.smoothMesh) private var smoothMesh: Bool = false

    @State private var outputFiles: [URL] = []
    @State private var diskSize: Int64 = 0
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showDeleteConfirmation = false
    @State private var showClearConfirmation = false
    @State private var shareRequest: ShareRequest? = nil
    @State private var zippingKind: String? = nil
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
                store.reload()
                refreshFiles()
            }
        }
    }

    private func content(_ scan: ScanMeta) -> some View {
        List {
            if scan.isRoomScan {
                roomSection(scan)
            } else {
                viewerSection(scan)
                infoSection(scan)
                exportSection(scan)
            }
            filesSection(scan)
            manageSection(scan)
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
        .alert("Renomear", isPresented: $showRename) {
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
        .alert("Apagar este item?", isPresented: $showDeleteConfirmation) {
            Button("Apagar", role: .destructive) {
                store.delete(id: scan.id)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {
            }
        } message: {
            Text("O bruto e todos os arquivos exportados serão apagados do aparelho.")
        }
        .alert("Apagar os arquivos gerados?", isPresented: $showClearConfirmation) {
            Button("Apagar arquivos", role: .destructive) {
                clearOutputs(scan)
            }
            Button("Cancelar", role: .cancel) {
            }
        } message: {
            Text("Só os arquivos exportados são apagados. O bruto do scan continua e dá para gerar tudo de novo.")
        }
    }

    // MARK: - Seções

    /// Item do RoomPlan: não há malha para exportar, só as medidas dos cômodos.
    private func roomSection(_ scan: ScanMeta) -> some View {
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
    }

    private func viewerSection(_ scan: ScanMeta) -> some View {
        Section {
            NavigationLink {
                ScanViewerScreen(scanID: scan.id, scanName: scan.name)
            } label: {
                Label("Ver em 3D e medir", systemImage: "cube.transparent")
                    .font(.headline)
            }
            .disabled(job.isRunning)

            NavigationLink {
                EditorScreen(scanID: scan.id, scanName: scan.name)
            } label: {
                Label("Cortar (editor)", systemImage: "crop")
            }
            .disabled(job.isRunning)

            if let sourceID = scan.sourceScanID {
                let sourceName = store.scans.first(where: { $0.id == sourceID })?.name ?? "um scan apagado"
                Label("Versão cortada de \(sourceName)", systemImage: "arrow.triangle.branch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func infoSection(_ scan: ScanMeta) -> some View {
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
    }

    private func exportSection(_ scan: ScanMeta) -> some View {
        let options = AppSettings.exportOptions
        return Section {
            NavigationLink {
                ExportOptionsView(hasKeyframes: (scan.keyframeCount ?? 0) > 0)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opções de exportação")
                    Text(optionsSummary(options))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(job.isRunning)

            if job.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: job.progress)
                    Text(job.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Cancelar", role: .destructive) {
                        job.cancel()
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    job.start(scanID: scan.id, options: AppSettings.exportOptions)
                } label: {
                    Label("Gerar arquivos", systemImage: "square.and.arrow.down.on.square")
                        .font(.headline)
                }
                .disabled(options.formats.isEmpty)

                if !options.formats.isEmpty {
                    Text(estimateText(options, scan))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            Text("Processar e exportar")
        } footer: {
            Text("Os arquivos são gerados a partir do bruto do scan, que nunca é alterado. Dá para gerar de novo quantas vezes quiser, com outras opções. Medidas aproximadas: confira com a trena.")
        }
    }

    private func filesSection(_ scan: ScanMeta) -> some View {
        Section {
            if outputFiles.isEmpty {
                Text("Nenhum arquivo gerado ainda.")
                    .foregroundStyle(.secondary)
            } else {
                zipButton(title: "Compartilhar arquivos gerados (ZIP)", icon: "doc.zipper", kind: "outputs", scanID: scan.id)

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
            Text("O ZIP leva os arquivos com os nomes originais; é o jeito mais seguro de mandar formatos que vêm em mais de um arquivo (OBJ + MTL, glTF + BIN).")
        }
    }

    private func manageSection(_ scan: ScanMeta) -> some View {
        Section {
            zipButton(title: "Compartilhar todos os dados (ZIP)", icon: "archivebox", kind: "all", scanID: scan.id)

            Button {
                openInFiles(scan)
            } label: {
                Label("Abrir no app Arquivos", systemImage: "folder")
            }

            if !outputFiles.isEmpty {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Apagar arquivos gerados", systemImage: "eraser")
                }
                .disabled(job.isRunning)
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Apagar item", systemImage: "trash")
            }
            .disabled(job.isRunning)
        } header: {
            Text("Dados do scan")
        } footer: {
            Text("\"Todos os dados\" leva a pasta inteira: bruto, fotos, profundidade, frames.json e arquivos gerados. Pode ter centenas de megabytes.")
        }
    }

    private func zipButton(title: String, icon: String, kind: String, scanID: String) -> some View {
        Button {
            shareZip(scanID: scanID, kind: kind)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if zippingKind == kind {
                    ProgressView()
                }
            }
        }
        .disabled(zippingKind != nil || job.isRunning)
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

    private func optionsSummary(_ options: ExportOptions) -> String {
        if options.formats.isEmpty {
            return "Nenhum formato marcado"
        }
        let names = ExportFormat.allCases.filter { options.formats.contains($0) }.map { $0.title }
        var parts = [names.joined(separator: ", "), options.axis == .zUp ? "Z para cima" : "Y para cima"]
        if options.texture != .off {
            parts.append("textura \(options.texture.title)")
        }
        if options.reduce {
            parts.append("reduzida")
        }
        if options.smooth {
            parts.append("suavizada")
        }
        return parts.joined(separator: " · ")
    }

    /// Tempo estimado do processamento, só como ordem de grandeza.
    private func estimateText(_ options: ExportOptions, _ scan: ScanMeta) -> String {
        let seconds = options.estimatedSeconds(vertexCount: scan.vertexCount,
                                               faceCount: scan.faceCount,
                                               keyframeCount: scan.keyframeCount ?? 0)
        if seconds < 90 {
            return "Tempo estimado: cerca de \(max(1, Int(seconds.rounded()))) s"
        }
        return "Tempo estimado: cerca de \(Int((seconds / 60).rounded())) min"
    }

    // MARK: - Compartilhamento

    /// Arquivos que acompanham outro e precisam ir junto: o `.mtl` (e a textura `.jpg`)
    /// do OBJ e o `.bin` do glTF. Todos têm o mesmo nome, com outra extensão.
    private func companionFiles(for file: URL) -> [URL] {
        var extensions: [String] = []
        switch file.pathExtension.lowercased() {
        case "obj":
            extensions = ["mtl", "jpg"]
        case "gltf":
            extensions = ["bin"]
        default:
            extensions = []
        }
        var companions: [URL] = []
        for ext in extensions {
            let companion = file.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: companion.path) {
                companions.append(companion)
            }
        }
        return companions
    }

    private func fileDetail(_ file: URL) -> String {
        let size = AppPaths.formatBytes(AppPaths.fileSize(file))
        let companions = companionFiles(for: file)
        if !companions.isEmpty {
            let names = companions.map { "." + $0.pathExtension }.joined(separator: " e ")
            return "\(size) · vai junto com \(names)"
        }
        return size
    }

    private func share(_ file: URL) {
        shareError = nil
        // Esses formatos referenciam os outros arquivos pelo nome: precisam ir juntos.
        shareRequest = ShareRequest(urls: [file] + companionFiles(for: file))
    }

    private func shareZip(scanID: String, kind: String) {
        if zippingKind != nil {
            return
        }
        zippingKind = kind
        shareError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = kind == "all" ? try ZipArchiver.zipWholeScan(scanID: scanID) : try ZipArchiver.zipOutputs(scanID: scanID)
                DispatchQueue.main.async {
                    zippingKind = nil
                    shareRequest = ShareRequest(urls: [zipURL])
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.export, "Falha ao gerar o ZIP (\(kind)) do scan \(scanID): \(text)")
                DispatchQueue.main.async {
                    zippingKind = nil
                    shareError = "Não foi possível gerar o ZIP: \(text)"
                }
            }
        }
    }

    /// Abre a pasta do scan no app Arquivos do sistema.
    private func openInFiles(_ scan: ScanMeta) {
        let path = store.directory(for: scan.id).path
        // "shareddocuments://" é o esquema que o app Arquivos usa para abrir uma pasta local.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://" + encoded) {
            UIApplication.shared.open(url)
        }
    }

    private func clearOutputs(_ scan: ScanMeta) {
        for file in outputFiles {
            try? FileManager.default.removeItem(at: file)
        }
        AppLog.info(.export, "Arquivos gerados do scan \(scan.id) apagados")
        refreshFiles()
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
