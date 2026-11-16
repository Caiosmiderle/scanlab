import ARKit
import AVFoundation
import RoomPlan
import ScanCore

enum RoomScanState {
    /// Nada em andamento.
    case idle
    /// Escaneando um cômodo.
    case scanning
    /// O RoomPlan está montando o modelo do cômodo.
    case processing
    /// Cômodo pronto: o usuário decide entre adicionar outro, salvar ou descartar.
    case review
    /// Gravando os arquivos na biblioteca.
    case saving
}

/// Controla a captura de cômodos com o RoomPlan (marco M3).
///
/// Vários cômodos podem ser capturados em sequência. Entre um e outro a sessão de AR
/// NÃO é pausada (`stop(pauseARSession: false)`), então todos ficam no mesmo sistema
/// de coordenadas e podem ser juntados numa planta só.
final class RoomScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published private(set) var state: RoomScanState = .idle
    @Published private(set) var rooms: [RoomResult] = []
    @Published private(set) var lastSavedSummary: String? = nil
    @Published var alertMessage: String? = nil

    private weak var captureView: RoomCaptureView?
    /// Quando verdadeiro, o resultado da parada em andamento é jogado fora (cancelamento).
    private var discardNextResult = false
    private var roomStartedAt: Date?

    override init() {
        super.init()
    }

    // O protocolo RoomCaptureViewDelegate herda de NSCoding, então estes dois membros
    // são obrigatórios mesmo sem o controlador ser arquivado em lugar nenhum.
    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {
    }

    /// Chamado pela tela quando a `RoomCaptureView` é criada.
    func attach(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
    }

    // MARK: - Ações do usuário

    func start() {
        guard state == .idle || state == .review else {
            return
        }
        lastSavedSummary = nil

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginRoom()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginRoom()
                    } else {
                        self.showCameraDenied()
                    }
                }
            }
        default:
            showCameraDenied()
        }
    }

    /// Termina o cômodo atual e pede ao RoomPlan para processá-lo.
    func finishRoom() {
        guard state == .scanning, let captureView = captureView else {
            return
        }
        state = .processing
        discardNextResult = false
        // Sem pausar a sessão de AR: o próximo cômodo continua no mesmo mundo.
        captureView.captureSession.stop(pauseARSession: false)
        AppLog.info(.capture, "RoomPlan: cômodo \(rooms.count + 1) encerrado pelo usuário")
    }

    /// Abandona o cômodo que está sendo escaneado. Os anteriores continuam.
    func cancelRoom() {
        guard state == .scanning, let captureView = captureView else {
            return
        }
        discardNextResult = true
        state = .processing
        captureView.captureSession.stop(pauseARSession: false)
        AppLog.info(.capture, "RoomPlan: cômodo \(rooms.count + 1) cancelado")
    }

    /// Joga fora todos os cômodos capturados e volta ao início.
    func discardAll() {
        guard state == .review else {
            return
        }
        rooms.removeAll()
        pauseARSession()
        state = .idle
        AppLog.info(.capture, "RoomPlan: captura descartada")
    }

    func save() {
        guard state == .review, !rooms.isEmpty else {
            return
        }
        state = .saving
        pauseARSession()
        let results = rooms

        Task {
            do {
                let meta = try await RoomScanSaver.save(results)
                await MainActor.run {
                    self.finishSaving(meta: meta, errorText: nil)
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.export, "RoomPlan: falha ao salvar: \(text)")
                await MainActor.run {
                    self.finishSaving(meta: nil, errorText: text)
                }
            }
        }
    }

    // MARK: - Interno

    private func beginRoom() {
        guard let captureView = captureView else {
            alertMessage = "A tela de captura ainda não está pronta. Tente de novo."
            return
        }
        guard state == .idle || state == .review else {
            return
        }
        roomStartedAt = Date()
        discardNextResult = false
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        state = .scanning
        AppLog.info(.capture, "RoomPlan: cômodo \(rooms.count + 1) iniciado")
    }

    private func showCameraDenied() {
        alertMessage = "O ScanLab não tem permissão para usar a câmera. Abra Ajustes → ScanLab e ative Câmera."
        AppLog.error(.capture, "RoomPlan: permissão de câmera negada")
    }

    private func pauseARSession() {
        captureView?.captureSession.arSession.pause()
    }

    private func finishSaving(meta: ScanMeta?, errorText: String?) {
        if let meta = meta {
            rooms.removeAll()
            state = .idle
            lastSavedSummary = "\(meta.name) salvo com \(meta.rooms?.count ?? 0) cômodo(s). Veja na aba Biblioteca."
            ScanStore.shared.reload()
        } else {
            // Os cômodos continuam na memória para o usuário tentar salvar de novo.
            state = .review
            alertMessage = "Não foi possível salvar: \(errorText ?? "erro desconhecido")"
        }
    }

    /// Volta ao estado certo depois de um cômodo que não entrou na lista.
    private func returnAfterDroppedRoom() {
        if rooms.isEmpty {
            pauseARSession()
            state = .idle
        } else {
            state = .review
        }
    }

    private func handleProcessed(_ room: CapturedRoom, errorText: String?) {
        if let errorText = errorText {
            alertMessage = "O RoomPlan não conseguiu montar este cômodo: \(errorText)"
            returnAfterDroppedRoom()
            return
        }

        let name = "Cômodo \(rooms.count + 1)"
        let plan = RoomPlanConverter.planRoom(from: room, name: name)
        let summary = RoomPlanConverter.summary(of: plan, room: room)
        rooms.append(RoomResult(room: room, plan: plan, summary: summary))
        state = .review

        var duration = 0.0
        if let started = roomStartedAt {
            duration = Date().timeIntervalSince(started)
        }
        // Registra as duas áreas (pelo piso e pelas paredes) para comparar com a trena.
        let wallOutlineArea = PlanGeometry.orderedPolygon(from: plan.walls).map { PlanGeometry.polygonArea($0) }
        AppLog.info(.processing, "RoomPlan: \(name) paredes=\(room.walls.count) portas=\(room.doors.count) janelas=\(room.windows.count) vãos=\(room.openings.count) pisos=\(room.floors.count) objetos=\(room.objects.count) área usada=\(describe(plan.area)) m² área pelas paredes=\(describe(wallOutlineArea)) m² cantos do piso=\(plan.floorPolygon.count) perímetro=\(describe(plan.perimeter)) m pé-direito=\(describe(plan.ceilingHeight)) m duração=\(Int(duration)) s")
    }

    private func describe(_ value: Float?) -> String {
        guard let value = value else {
            return "?"
        }
        return String(format: "%.2f", value)
    }

    // MARK: - RoomCaptureViewDelegate

    /// O RoomPlan pergunta se deve processar e mostrar o cômodo que acabou de ser capturado.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error = error {
            let text = error.localizedDescription
            AppLog.error(.capture, "RoomPlan: captura terminou com erro: \(text)")
            DispatchQueue.main.async {
                if !self.discardNextResult {
                    self.alertMessage = "A captura do cômodo falhou: \(text)"
                }
                self.discardNextResult = false
                self.returnAfterDroppedRoom()
            }
            return false
        }
        if discardNextResult {
            DispatchQueue.main.async {
                self.discardNextResult = false
                self.returnAfterDroppedRoom()
            }
            return false
        }
        return true
    }

    /// O RoomPlan terminou de processar o cômodo.
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let errorText = error?.localizedDescription
        DispatchQueue.main.async {
            self.handleProcessed(processedResult, errorText: errorText)
        }
    }
}
