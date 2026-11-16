import ARKit
import AVFoundation
import UIKit
import ScanCore

enum CaptureState {
    /// Sem sessão rodando.
    case idle
    /// Escaneando.
    case scanning
    /// Sessão pausada pelo usuário; a malha capturada continua guardada.
    case paused
    /// Gravando o bruto e gerando os arquivos de saída.
    case saving
}

/// Controla a sessão do ARKit e o ciclo de vida de um scan.
///
/// O controlador é dono do `ARSession`; a `ARView` (em `ARViewContainer`) só exibe
/// essa sessão. Assim toda a lógica de captura fica aqui, sem depender da tela.
/// Os callbacks do ARKit chegam na thread principal (fila padrão do delegate).
final class CaptureController: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var anchorCount: Int = 0
    @Published private(set) var triangleCount: Int = 0
    @Published private(set) var keyframeCount: Int = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var memoryWarning: Bool = false
    @Published private(set) var trackingMessage: String? = nil
    /// Aviso de que o scan está rodando sem gerar malha (LiDAR coberto, por exemplo).
    @Published private(set) var meshWarning: String? = nil
    @Published private(set) var savingProgress: Double = 0
    @Published private(set) var savingMessage: String = ""
    @Published private(set) var lastSavedSummary: String? = nil
    @Published var alertMessage: String? = nil

    let session = ARSession()

    /// Estado mais recente de cada âncora de malha, por identificador.
    /// O ARKit reenvia a MESMA âncora várias vezes à medida que refina a malha;
    /// guardar por `identifier` e sobrescrever garante que, ao finalizar, cada pedaço
    /// da sala apareça uma única vez, na versão final.
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]

    /// Grava os keyframes (fotos e poses) do scan em andamento. `nil` fora de um scan
    /// ou se a pasta de captura não pôde ser criada (o scan segue, só sem cor).
    private var recorder: KeyframeRecorder?

    private var configuration: ARWorldTrackingConfiguration?
    private var reconstructionMode: String = "mesh"
    private var timer: Timer?
    /// Tempo acumulado de trechos anteriores (antes de pausas).
    private var accumulatedSeconds: Double = 0
    /// Início do trecho atual; `nil` quando pausado.
    private var segmentStart: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Diagnóstico: já aconteceu de um scan de 3 minutos terminar com zero blocos de
    // malha. Estes campos servem para avisar na hora e deixar rastro no log.
    private var firstMeshLogged = false
    private var lastProgressLogSeconds: Double = 0
    private var lastTrackingText = "normal"
    /// Depois de quantos segundos sem malha o aviso aparece.
    private static let meshWarningDelay: Double = 6
    /// De quanto em quanto tempo o andamento do scan vai para o log.
    private static let progressLogInterval: Double = 15

    /// Espaço livre mínimo para começar um scan.
    private static let minimumFreeBytes: Int64 = 300_000_000

    override init() {
        super.init()
        session.delegate = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(thermalStateChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(memoryWarningReceived),
                           name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.addObserver(self, selector: #selector(appEnteredBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// A `ARView` chama isto depois de receber a sessão, para garantir que o delegate
    /// continua sendo este controlador.
    func attachDelegate() {
        session.delegate = self
    }

    // MARK: - Ações do usuário

    func start() {
        guard state == .idle else {
            return
        }
        lastSavedSummary = nil

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginScan()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginScan()
                    } else {
                        self.showCameraDenied()
                    }
                }
            }
        default:
            showCameraDenied()
        }
    }

    func pause() {
        guard state == .scanning else {
            return
        }
        session.pause()
        closeTimeSegment()
        state = .paused
        trackingMessage = nil
        AppLog.info(.capture, "Scan pausado aos \(Int(elapsedSeconds)) s")
    }

    func resume() {
        guard state == .paused, let configuration = configuration else {
            return
        }
        // Sem opções de reset: o ARKit mantém as âncoras e tenta se relocalizar.
        session.run(configuration)
        segmentStart = Date()
        state = .scanning
        AppLog.info(.capture, "Scan retomado")
    }

    func cancel() {
        guard state == .scanning || state == .paused else {
            return
        }
        session.pause()
        stopTimer()
        meshAnchors.removeAll()
        recorder?.discard()
        recorder = nil
        resetCounters()
        state = .idle
        AppLog.info(.capture, "Scan cancelado pelo usuário")
    }

    /// Encerra a captura e grava o scan. `reason` vai para o log.
    func finish(reason: String) {
        guard state == .scanning || state == .paused else {
            return
        }
        session.pause()
        closeTimeSegment()
        stopTimer()

        let anchors = Array(meshAnchors.values)
        let duration = accumulatedSeconds
        let mode = reconstructionMode
        state = .saving
        savingProgress = 0
        savingMessage = "Preparando..."
        trackingMessage = nil
        AppLog.info(.capture, "Finalizando scan (\(reason)): âncoras=\(anchors.count) duração=\(Int(duration)) s")

        // Pede tempo extra ao sistema: se o app for para segundo plano no meio da
        // gravação, o iOS deixa terminar em vez de suspender com o arquivo pela metade.
        beginBackgroundTask()

        let axisRaw = UserDefaults.standard.string(forKey: SettingsKeys.exportUpAxis) ?? UpAxis.zUp.rawValue
        let axis = UpAxis(rawValue: axisRaw) ?? .zUp

        let activeRecorder = recorder
        recorder = nil
        if let activeRecorder = activeRecorder {
            // Espera o último keyframe terminar de ser gravado antes de salvar o scan.
            activeRecorder.finalize { records in
                AppLog.info(.capture, "Keyframes: salvos=\(records.count) descartados por fila ocupada=\(activeRecorder.droppedCount) falhas=\(activeRecorder.failedCount) profundidade: \(activeRecorder.depthSummary)")
                let captureDirectory = activeRecorder.directory
                DispatchQueue.global(qos: .userInitiated).async {
                    self.saveScan(anchors: anchors, duration: duration, mode: mode, axis: axis,
                                  captureDirectory: captureDirectory, keyframes: records)
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                self.saveScan(anchors: anchors, duration: duration, mode: mode, axis: axis,
                              captureDirectory: nil, keyframes: [])
            }
        }
    }

    func dismissSummary() {
        lastSavedSummary = nil
    }

    // MARK: - Início da sessão

    private func beginScan() {
        guard state == .idle else {
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            reconstructionMode = "meshWithClassification"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            reconstructionMode = "mesh"
        } else {
            alertMessage = "Este aparelho não tem LiDAR. O ScanLab precisa de um iPad ou iPhone com sensor LiDAR."
            AppLog.error(.capture, "Reconstrução de cena não suportada neste aparelho")
            return
        }
        // Sem textura de ambiente: é para reflexos de objetos virtuais e só gastaria
        // CPU e memória durante o scan.
        configuration.environmentTexturing = .none

        if let free = AppPaths.freeDiskBytes(), free < CaptureController.minimumFreeBytes {
            alertMessage = "Pouco espaço livre no aparelho (\(AppPaths.formatBytes(free))). Libere espaço antes de escanear."
            AppLog.error(.capture, "Scan bloqueado por falta de espaço: \(free) bytes livres")
            return
        }

        // Profundidade do LiDAR em cada quadro, para salvar junto dos keyframes.
        // A versão suavizada no tempo tem menos ruído; se não houver, usa a direta.
        let saveDepth = AppSettings.saveDepth
        if saveDepth {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }

        let keyframeSettings = AppSettings.keyframeSettings
        do {
            recorder = try KeyframeRecorder(settings: keyframeSettings, saveDepth: saveDepth)
        } catch {
            recorder = nil
            AppLog.error(.capture, "Não foi possível preparar a gravação de keyframes: \(error.localizedDescription). O scan ficará sem cor.")
        }
        AppLog.info(.capture, "Keyframes: intervalo=\(keyframeSettings.minInterval) s distância=\(keyframeSettings.minDistance) m ângulo=\(keyframeSettings.minAngleDegrees) graus teto=\(keyframeSettings.maxCount) profundidade=\(saveDepth)")

        self.configuration = configuration
        meshAnchors.removeAll()
        resetCounters()
        memoryWarning = false

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
        segmentStart = Date()
        startTimer()
        state = .scanning
        AppLog.info(.capture, "Scan iniciado: modo=\(reconstructionMode) aparelho=\(DeviceInfo.modelIdentifier) térmico=\(ThermalMonitor.label(thermalState))")
    }

    private func showCameraDenied() {
        alertMessage = "O ScanLab não tem permissão para usar a câmera. Abra Ajustes → ScanLab e ative Câmera."
        AppLog.error(.capture, "Permissão de câmera negada")
    }

    // MARK: - Gravação (fila de background)

    private func saveScan(anchors: [ARMeshAnchor], duration: Double, mode: String, axis: UpAxis,
                          captureDirectory: URL?, keyframes: [KeyframeRecord]) {
        let started = Date()
        reportSaving(0.05, "Lendo a malha do sensor...")

        var extracted: [MeshAnchorData] = []
        extracted.reserveCapacity(anchors.count)
        var skipped = 0
        for anchor in anchors {
            if let data = MeshExtractor.extract(anchor) {
                extracted.append(data)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            AppLog.warning(.capture, "\(skipped) âncoras ignoradas por formato inesperado de buffer")
        }

        do {
            reportSaving(0.15, "Salvando dados brutos...")
            let meta = try ScanStore.shared.createScan(anchors: extracted,
                                                      durationSeconds: duration,
                                                      reconstructionMode: mode,
                                                      captureDirectory: captureDirectory,
                                                      keyframes: keyframes)
            let rawSeconds = Date().timeIntervalSince(started)
            AppLog.info(.capture, "Bruto salvo: id=\(meta.id) âncoras=\(meta.anchorCount) vértices=\(meta.vertexCount) faces=\(meta.faceCount) keyframes=\(meta.keyframeCount ?? 0) tempo=\(String(format: "%.1f", rawSeconds))s")

            // O bruto já está em disco. Se a exportação falhar, o scan continua na
            // biblioteca e pode ser exportado de novo por lá.
            var exportNote = ""
            do {
                _ = try MeshExporter.exportPLYAndOBJ(scanID: meta.id, axis: axis, colorize: AppSettings.colorizeOnExport) { fraction, text in
                    self.reportSaving(0.25 + 0.75 * fraction, text)
                }
            } catch {
                exportNote = " A exportação falhou (\(error.localizedDescription)); tente de novo pela Biblioteca."
                AppLog.error(.export, "Falha ao exportar o scan \(meta.id): \(error.localizedDescription)")
            }

            let summary = "\(meta.name) salvo: \(meta.faceCount) triângulos, \(meta.vertexCount) vértices.\(exportNote)"
            DispatchQueue.main.async {
                self.finishSaving(summary: summary, errorMessage: nil)
            }
        } catch {
            AppLog.error(.capture, "Falha ao salvar o scan: \(error.localizedDescription)")
            if let captureDirectory = captureDirectory {
                try? FileManager.default.removeItem(at: captureDirectory)
            }
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.finishSaving(summary: nil, errorMessage: message)
            }
        }
    }

    private func reportSaving(_ fraction: Double, _ message: String) {
        DispatchQueue.main.async {
            self.savingProgress = fraction
            self.savingMessage = message
        }
    }

    private func finishSaving(summary: String?, errorMessage: String?) {
        meshAnchors.removeAll()
        resetCounters()
        state = .idle
        lastSavedSummary = summary
        if let errorMessage = errorMessage {
            alertMessage = errorMessage
        }
        ScanStore.shared.reload()
        endBackgroundTask()
    }

    // MARK: - Tempo e contadores

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Modo .common: o contador continua andando enquanto o usuário arrasta algo na tela.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func closeTimeSegment() {
        if let start = segmentStart {
            accumulatedSeconds += Date().timeIntervalSince(start)
        }
        segmentStart = nil
        elapsedSeconds = accumulatedSeconds
    }

    private func resetCounters() {
        accumulatedSeconds = 0
        segmentStart = nil
        elapsedSeconds = 0
        anchorCount = 0
        triangleCount = 0
        keyframeCount = 0
        trackingMessage = nil
        meshWarning = nil
        firstMeshLogged = false
        lastProgressLogSeconds = 0
        lastTrackingText = "normal"
    }

    private func tick() {
        guard state == .scanning else {
            return
        }
        var elapsed = accumulatedSeconds
        if let start = segmentStart {
            elapsed += Date().timeIntervalSince(start)
        }
        elapsedSeconds = elapsed

        var triangles = 0
        for anchor in meshAnchors.values {
            triangles += anchor.geometry.faces.count
        }
        anchorCount = meshAnchors.count
        triangleCount = triangles
        keyframeCount = recorder?.records.count ?? 0

        // Sem nenhum bloco de malha depois de alguns segundos: avisa em vez de deixar
        // o usuário descobrir só no fim.
        if meshAnchors.isEmpty && elapsed > CaptureController.meshWarningDelay {
            meshWarning = "Nenhuma malha até agora. Confira se a mão ou a capa não cobre o sensor LiDAR, ao lado das câmeras."
        } else {
            meshWarning = nil
        }

        if elapsed - lastProgressLogSeconds >= CaptureController.progressLogInterval {
            lastProgressLogSeconds = elapsed
            var depthText = "sem gravador"
            if let recorder = recorder {
                let fraction = recorder.lastDepthValidFraction
                let last = fraction < 0 ? "?" : "\(Int((fraction * 100).rounded()))%"
                depthText = "\(recorder.depthSummary) último=\(last)"
            }
            AppLog.info(.capture, "Andamento: t=\(Int(elapsed)) s blocos=\(meshAnchors.count) triângulos=\(triangles) fotos=\(keyframeCount) rastreamento=\(lastTrackingText) profundidade: \(depthText)")
        }
    }

    // MARK: - Notificações do sistema

    @objc private func thermalStateChanged() {
        // Esta notificação pode chegar fora da thread principal.
        DispatchQueue.main.async {
            let newState = ProcessInfo.processInfo.thermalState
            self.thermalState = newState
            AppLog.info(.capture, "Estado térmico: \(ThermalMonitor.label(newState))")
            if newState == .critical && (self.state == .scanning || self.state == .paused) {
                self.alertMessage = "O aparelho esquentou demais. O scan foi finalizado e salvo para não perder o que já foi capturado."
                self.finish(reason: "temperatura crítica")
            }
        }
    }

    @objc private func memoryWarningReceived() {
        DispatchQueue.main.async {
            self.memoryWarning = true
            AppLog.warning(.capture, "Aviso de pouca memória: triângulos=\(self.triangleCount)")
        }
    }

    @objc private func appEnteredBackground() {
        DispatchQueue.main.async {
            // Em segundo plano o ARKit perde a câmera e o rastreamento. Em vez de
            // arriscar perder tudo, salvamos o que já foi capturado.
            if self.state == .scanning || self.state == .paused {
                self.finish(reason: "app foi para segundo plano")
            }
        }
    }

    private func beginBackgroundTask() {
        if backgroundTask != .invalid {
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SalvarScan") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask == .invalid {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        storeMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        storeMeshAnchors(anchors)
    }

    /// Chamado a cada quadro da câmera (até 60 por segundo), na thread principal.
    /// Tem de ser rápido e NÃO pode guardar o `ARFrame`: quem segura quadros faz o
    /// ARKit ficar sem buffers e a câmera travar. O gravador decide em microssegundos
    /// se o quadro interessa e só então copia o que precisa.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard state == .scanning, let recorder = recorder else {
            return
        }
        recorder.consider(frame)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if anchor is ARMeshAnchor {
                meshAnchors.removeValue(forKey: anchor.identifier)
            }
        }
    }

    private func storeMeshAnchors(_ anchors: [ARAnchor]) {
        guard state == .scanning else {
            return
        }
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors[meshAnchor.identifier] = meshAnchor
            }
        }
        if !firstMeshLogged && !meshAnchors.isEmpty {
            firstMeshLogged = true
            var elapsed = accumulatedSeconds
            if let start = segmentStart {
                elapsed += Date().timeIntervalSince(start)
            }
            AppLog.info(.capture, "Primeira malha recebida após \(String(format: "%.1f", elapsed)) s")
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard state == .scanning else {
            return
        }
        switch camera.trackingState {
        case .normal:
            trackingMessage = nil
        case .notAvailable:
            trackingMessage = "Rastreamento indisponível"
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingMessage = "Iniciando o rastreamento..."
            case .excessiveMotion:
                trackingMessage = "Mova o aparelho mais devagar"
            case .insufficientFeatures:
                trackingMessage = "Poucos detalhes visíveis: aponte para áreas com textura e luz"
            case .relocalizing:
                trackingMessage = "Relocalizando: aponte para uma área já escaneada"
            default:
                trackingMessage = "Rastreamento limitado"
            }
        }

        // Só registra quando muda, para o log mostrar a sequência de estados.
        let text = trackingMessage ?? "normal"
        if text != lastTrackingText {
            lastTrackingText = text
            AppLog.info(.capture, "Rastreamento: \(text)")
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        AppLog.warning(.capture, "Sessão do ARKit interrompida")
        if state == .scanning {
            trackingMessage = "Câmera interrompida pelo sistema"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        AppLog.info(.capture, "Interrupção da sessão do ARKit terminou")
        if state == .scanning {
            trackingMessage = "Relocalizando: aponte para uma área já escaneada"
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        AppLog.error(.capture, "Sessão do ARKit falhou: \(error.localizedDescription)")
        if state == .scanning || state == .paused {
            alertMessage = "A sessão de captura falhou (\(error.localizedDescription)). O que já foi capturado foi salvo."
            finish(reason: "falha da sessão")
        } else {
            alertMessage = "A sessão de captura falhou: \(error.localizedDescription)"
        }
    }
}
