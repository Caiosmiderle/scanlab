import SwiftUI
import SceneKit
import ScanCore

/// A `SCNView` do editor.
struct EditorSceneViewContainer: UIViewRepresentable {
    let controller: EditorSceneController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = controller.scene
        view.backgroundColor = UIColor(white: 0.07, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        // Liga o controle de câmera ANTES de anexar: o controlador precisa ver os gestos
        // de câmera para fazê-los esperar pelo arrasto das alças.
        controller.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
    }
}

/// Malha pronta para a cena do editor.
struct EditorMesh {
    var chunks: [ViewerChunk]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var faceCount: Int
}

enum EditorError: Error, LocalizedError {
    case emptyMesh
    case wouldRemoveEverything

    var errorDescription: String? {
        switch self {
        case .emptyMesh:
            return "A malha deste scan está vazia."
        case .wouldRemoveEverything:
            return "Este corte apagaria a malha inteira. Ajuste a caixa e tente de novo."
        }
    }
}

/// Editor de corte (marco M8): caixa com alças, apagar dentro ou fora, desfazer e refazer,
/// salvar como nova versão. O scan original nunca é alterado.
struct EditorScreen: View {
    let scanID: String
    let scanName: String

    @Environment(\.dismiss) private var dismiss
    @State private var controller = EditorSceneController()

    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var isWorking = false
    @State private var notice: String? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Tela estreita (iPhone em pé, iPad em tela dividida): controles mais enxutos.
    private var isCompact: Bool {
        return horizontalSizeClass == .compact
    }

    /// Blocos da malha no estado atual da edição.
    @State private var anchors: [MeshAnchorData] = []
    @State private var undoStack: [[MeshAnchorData]] = []
    @State private var redoStack: [[MeshAnchorData]] = []
    @State private var faceCount = 0
    @State private var originalFaceCount = 0

    @State private var boxMin = SIMD3<Float>(-1, -1, -1)
    @State private var boxMax = SIMD3<Float>(1, 1, 1)
    @State private var rangeMin = SIMD3<Float>(-2, -2, -2)
    @State private var rangeMax = SIMD3<Float>(2, 2, 2)
    @State private var orthographic = false
    @State private var showFineTune = false
    @State private var showLeaveConfirmation = false

    /// Quantos estados o desfazer guarda. Cada um é uma cópia da malha bruta.
    private static let undoLimit = 15

    private var hasChanges: Bool {
        return !undoStack.isEmpty
    }

    var body: some View {
        ZStack {
            EditorSceneViewContainer(controller: controller)
                .ignoresSafeArea(edges: .bottom)

            if isLoading {
                ProgressView("Abrindo a malha...")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            } else if let loadError = loadError {
                ContentUnavailableView("Não foi possível abrir o editor",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                VStack(spacing: 10) {
                    viewControls
                    Spacer()
                    if let notice = notice {
                        Text(notice)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    editPanel
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Cortar: \(scanName)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if hasChanges {
                        showLeaveConfirmation = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Label("Voltar", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveVersion()
                } label: {
                    Label("Salvar como nova versão", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasChanges || isWorking)
            }
        }
        .confirmationDialog("Sair sem salvar?", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
            Button("Descartar cortes", role: .destructive) {
                dismiss()
            }
            Button("Continuar editando", role: .cancel) {
            }
        } message: {
            Text("Os cortes feitos aqui ainda não foram salvos. O scan original continua intacto.")
        }
        .onAppear {
            controller.onBoxChange = { newMin, newMax in
                boxMin = newMin
                boxMax = newMax
            }
            load()
        }
        .onChange(of: boxMin) { _, _ in
            pushBoxToScene()
        }
        .onChange(of: boxMax) { _, _ in
            pushBoxToScene()
        }
        .onChange(of: orthographic) { _, value in
            controller.show(.isometric, orthographic: value)
        }
    }

    // MARK: - Controles

    private var viewControls: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            viewButton("Frente") {
                controller.show(.front, orthographic: orthographic)
            }
            viewButton("Topo") {
                controller.show(.top, orthographic: orthographic)
            }
            viewButton("Lado") {
                controller.show(.side, orthographic: orthographic)
            }
            viewButton("3D") {
                controller.show(.isometric, orthographic: orthographic)
            }
            Toggle("Ortográfica", isOn: $orthographic)
                .toggleStyle(.button)
                .hoverEffect(.highlight)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func viewButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(minWidth: 52, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .hoverEffect(.highlight)
        .accessibilityLabel("Vista \(title)")
    }

    private var editPanel: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    faceCountText
                    Spacer()
                    dragHint
                }
                VStack(spacing: 2) {
                    faceCountText
                    dragHint
                }
            }

            FlowLayout(spacing: 10, lineSpacing: 8) {
                actionButton("Apagar dentro", icon: "minus.square.fill", prominent: true) {
                    cut(removeInside: true)
                }
                actionButton("Apagar fora", icon: "square.dashed.inset.filled", prominent: true) {
                    cut(removeInside: false)
                }
                actionButton("Desfazer", icon: "arrow.uturn.backward", prominent: false) {
                    undo()
                }
                .disabled(undoStack.isEmpty)
                actionButton("Refazer", icon: "arrow.uturn.forward", prominent: false) {
                    redo()
                }
                .disabled(redoStack.isEmpty)
                actionButton("Caixa inteira", icon: "arrow.up.left.and.arrow.down.right", prominent: false) {
                    let full = controller.fullBox
                    boxMin = full.min
                    boxMax = full.max
                }
            }
            .disabled(isWorking)

            DisclosureGroup("Ajuste fino da caixa", isExpanded: $showFineTune) {
                if isCompact {
                    // No iPhone os controles ficam empilhados e rolam, para o painel não
                    // cobrir a tela inteira.
                    ScrollView {
                        fineTuneSliders
                    }
                    .frame(maxHeight: 230)
                } else {
                    fineTuneSliders
                }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: 760)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var faceCountText: some View {
        Text("\(faceCount) de \(originalFaceCount) triângulos")
            .font(.callout.monospacedDigit())
    }

    private var dragHint: some View {
        Text("Arraste as bolinhas para mover as faces da caixa")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var fineTuneSliders: some View {
        VStack(spacing: isCompact ? 10 : 6) {
            axisSliders("X", axis: 0)
            axisSliders("Y (altura)", axis: 1)
            axisSliders("Z", axis: 2)
        }
        .padding(.top, 6)
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if isCompact && !prominent {
                // No iPhone os botões secundários ficam só com o ícone.
                Button(action: action) {
                    Image(systemName: icon)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.bordered)
            } else if prominent {
                Button(action: action) {
                    Label(title, systemImage: icon)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: icon)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .hoverEffect(.lift)
        .accessibilityLabel(title)
    }

    /// Dois controles por eixo: onde a caixa começa e onde termina.
    private func axisSliders(_ title: String, axis: Int) -> some View {
        let lower = rangeMin[axis]
        let upper = max(rangeMax[axis], lower + 0.1)
        let minBinding = Binding<Float>(
            get: { boxMin[axis] },
            set: { value in
                var updated = boxMin
                updated[axis] = min(value, boxMax[axis] - 0.05)
                boxMin = updated
            }
        )
        let maxBinding = Binding<Float>(
            get: { boxMax[axis] },
            set: { value in
                var updated = boxMax
                updated[axis] = max(value, boxMin[axis] + 0.05)
                boxMax = updated
            }
        )
        return Group {
            if isCompact {
                // iPhone: título e valores numa linha, um controle por linha embaixo.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                        Spacer()
                        Text("\(FloorPlanSVG.formatMeters(boxMin[axis])) a \(FloorPlanSVG.formatMeters(boxMax[axis])) m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: minBinding, in: lower...upper)
                        .accessibilityLabel("Início da caixa em \(title)")
                    Slider(value: maxBinding, in: lower...upper)
                        .accessibilityLabel("Fim da caixa em \(title)")
                }
            } else {
                HStack(spacing: 10) {
                    Text(title)
                        .frame(width: 80, alignment: .leading)
                    Text(FloorPlanSVG.formatMeters(boxMin[axis]))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                    Slider(value: minBinding, in: lower...upper)
                        .accessibilityLabel("Início da caixa em \(title)")
                    Slider(value: maxBinding, in: lower...upper)
                        .accessibilityLabel("Fim da caixa em \(title)")
                    Text(FloorPlanSVG.formatMeters(boxMax[axis]))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                }
            }
        }
    }

    private func pushBoxToScene() {
        if controller.boxMin != boxMin || controller.boxMax != boxMax {
            controller.setBox(min: boxMin, max: boxMax)
        }
    }

    // MARK: - Malha

    /// Monta a malha para a cena. Síncrono e pesado: fora da thread principal.
    private static func buildMesh(_ anchors: [MeshAnchorData]) throws -> EditorMesh {
        var mesh = MeshBuilder.worldMesh(from: anchors)
        mesh.removeUnusedAndInvalid()
        guard mesh.faceCount > 0, let limits = mesh.bounds() else {
            throw EditorError.emptyMesh
        }
        // O editor mostra a malha cinza (sem cor) para abrir e atualizar rápido.
        let pieces = MeshChunker.split(mesh, cellSize: 2.5)
        var chunks: [ViewerChunk] = []
        chunks.reserveCapacity(pieces.count)
        for piece in pieces {
            chunks.append(ViewerChunk(mesh: piece))
        }
        return EditorMesh(chunks: chunks, boundsMin: limits.min, boundsMax: limits.max, faceCount: mesh.faceCount)
    }

    private func load() {
        guard isLoading else {
            return
        }
        let id = scanID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try RawMeshFile.read(contentsOf: ScanStore.shared.rawMeshURL(for: id))
                let built = try EditorScreen.buildMesh(loaded)
                DispatchQueue.main.async {
                    anchors = loaded
                    faceCount = built.faceCount
                    originalFaceCount = built.faceCount
                    controller.install(chunks: built.chunks, boundsMin: built.boundsMin, boundsMax: built.boundsMax)
                    boxMin = controller.boxMin
                    boxMax = controller.boxMax
                    let range = controller.sliderRange
                    rangeMin = range.min
                    rangeMax = range.max
                    isLoading = false
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.processing, "Editor: falha ao abrir o scan \(id): \(text)")
                DispatchQueue.main.async {
                    loadError = text
                    isLoading = false
                }
            }
        }
    }

    /// Mostra um novo estado da malha (depois de cortar, desfazer ou refazer).
    private func apply(_ newAnchors: [MeshAnchorData], onSuccess: @escaping () -> Void) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let built = try EditorScreen.buildMesh(newAnchors)
                DispatchQueue.main.async {
                    onSuccess()
                    anchors = newAnchors
                    faceCount = built.faceCount
                    controller.replaceMesh(chunks: built.chunks)
                    isWorking = false
                }
            } catch {
                let text = error.localizedDescription
                DispatchQueue.main.async {
                    notice = text
                    isWorking = false
                }
            }
        }
    }

    private func cut(removeInside: Bool) {
        let current = anchors
        let lower = boxMin
        let upper = boxMax
        isWorking = true
        notice = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let cropped = MeshCropper.crop(anchors: current, boxMin: lower, boxMax: upper, removeInside: removeInside)
            let before = MeshCropper.faceCount(current)
            let after = MeshCropper.faceCount(cropped)
            DispatchQueue.main.async {
                isWorking = false
                if after == 0 {
                    notice = EditorError.wouldRemoveEverything.localizedDescription
                    return
                }
                if after == before {
                    notice = removeInside ? "Não há nada dentro da caixa para apagar." : "Não há nada fora da caixa para apagar."
                    return
                }
                AppLog.info(.processing, "Editor do scan \(scanID): apagar \(removeInside ? "dentro" : "fora") faces \(before) → \(after)")
                apply(cropped) {
                    undoStack.append(current)
                    if undoStack.count > EditorScreen.undoLimit {
                        undoStack.removeFirst()
                    }
                    redoStack.removeAll()
                    notice = "\(before - after) triângulos apagados."
                }
            }
        }
    }

    private func undo() {
        guard let previous = undoStack.last else {
            return
        }
        let current = anchors
        apply(previous) {
            undoStack.removeLast()
            redoStack.append(current)
            notice = nil
        }
    }

    private func redo() {
        guard let next = redoStack.last else {
            return
        }
        let current = anchors
        apply(next) {
            redoStack.removeLast()
            undoStack.append(current)
            notice = nil
        }
    }

    private func saveVersion() {
        let edited = anchors
        let id = scanID
        isWorking = true
        notice = "Salvando a nova versão..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let meta = try ScanStore.shared.createVersion(from: id, anchors: edited, label: "recorte")
                DispatchQueue.main.async {
                    ScanStore.shared.reload()
                    isWorking = false
                    // Sem alterações pendentes: o voltar não pede confirmação.
                    undoStack.removeAll()
                    redoStack.removeAll()
                    notice = "Salvo na Biblioteca como \"\(meta.name)\"."
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.processing, "Editor: falha ao salvar versão do scan \(id): \(text)")
                DispatchQueue.main.async {
                    isWorking = false
                    notice = "Não foi possível salvar: \(text)"
                }
            }
        }
    }
}
