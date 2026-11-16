import SwiftUI
import UIKit
import ScanCore

/// Visualizador 3D de um scan (marco M5).
struct ScanViewerScreen: View {
    let scanID: String
    let scanName: String

    @Environment(\.dismiss) private var dismiss
    @State private var controller = ViewerSceneController()

    // Carregamento
    @State private var isLoading = true
    @State private var loadProgress: Double = 0
    @State private var loadMessage = "Abrindo..."
    @State private var loadError: String? = nil
    @State private var hasColors = false
    @State private var dimensionsText = ""
    @State private var modelHeight: Float = 2.5
    /// A malha carregada (Y-up), usada para gerar o USDZ do modo AR.
    @State private var loadedMesh: WorldMesh? = nil

    // Aparência
    @State private var mode: ViewerMode = .textured
    @State private var projection: ViewerProjection = .perspective
    @State private var showGrid = true
    @State private var showBox = true
    @State private var showAxes = false
    @State private var showStatistics = false
    @State private var planCutHeight: Float = 2.0

    // Caminhada
    @State private var isWalking = false
    @State private var eyeHeight: Float = 1.6
    @State private var joystickOffset: CGSize = .zero

    // Ações
    @State private var notice: String? = nil
    @State private var isBusy = false
    @State private var showDeleteConfirmation = false
    @State private var previewRequest: PreviewRequest? = nil
    @State private var shareRequest: ShareRequest? = nil

    var body: some View {
        ZStack {
            SceneViewContainer(controller: controller)
                .ignoresSafeArea(edges: .bottom)

            if isLoading {
                loadingCard
            } else if let loadError = loadError {
                ContentUnavailableView("Não foi possível abrir o scan",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                VStack(spacing: 10) {
                    topControls
                    Spacer()
                    if isWalking {
                        walkControls
                    } else {
                        if projection == .plan {
                            planControls
                        }
                        bottomInfo
                    }
                    bottomBar
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(scanName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            load()
        }
        .onDisappear {
            controller.stopWalking()
        }
        .onChange(of: mode) { _, newMode in
            controller.apply(mode: newMode)
        }
        .onChange(of: projection) { _, newProjection in
            controller.apply(projection: newProjection)
        }
        .onChange(of: showGrid) { _, visible in
            controller.setGridVisible(visible)
        }
        .onChange(of: showBox) { _, visible in
            controller.setBoxVisible(visible)
        }
        .onChange(of: showAxes) { _, visible in
            controller.setAxesVisible(visible)
        }
        .onChange(of: showStatistics) { _, visible in
            controller.setStatisticsVisible(visible)
        }
        .onChange(of: planCutHeight) { _, height in
            controller.setPlanCutHeight(height)
        }
        .onChange(of: eyeHeight) { _, height in
            controller.setEyeHeight(height)
        }
        .alert("Apagar este scan?", isPresented: $showDeleteConfirmation) {
            Button("Apagar", role: .destructive) {
                ScanStore.shared.delete(id: scanID)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {
            }
        } message: {
            Text("O bruto e todos os arquivos exportados serão apagados do aparelho.")
        }
        .sheet(item: $previewRequest) { request in
            QuickLookPreview(url: request.url)
                .ignoresSafeArea()
        }
        .sheet(item: $shareRequest) { request in
            ActivityView(urls: request.urls)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Carregamento

    private func load() {
        guard isLoading else {
            return
        }
        let id = scanID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let model = try ViewerModelLoader.load(scanID: id) { fraction, text in
                    DispatchQueue.main.async {
                        loadProgress = fraction
                        loadMessage = text
                    }
                }
                DispatchQueue.main.async {
                    hasColors = model.hasColors
                    loadedMesh = model.mesh
                    // Sem cor, o modo Cor mostraria só cinza: começa em Liso.
                    let initialMode: ViewerMode = model.hasColors ? .textured : .flat
                    mode = initialMode
                    controller.install(model, mode: initialMode)
                    controller.setGridVisible(showGrid)
                    controller.setBoxVisible(showBox)
                    controller.setAxesVisible(showAxes)
                    dimensionsText = controller.dimensionsText
                    modelHeight = controller.modelHeight
                    planCutHeight = controller.currentPlanCutHeight
                    isLoading = false
                }
            } catch {
                let text = error.localizedDescription
                AppLog.error(.processing, "Visualizador: falha ao abrir o scan \(id): \(text)")
                DispatchQueue.main.async {
                    loadError = text
                    isLoading = false
                }
            }
        }
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: loadProgress)
                .frame(maxWidth: 280)
            Text(loadMessage)
                .font(.callout)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Controles de cima

    private var topControls: some View {
        VStack(spacing: 8) {
            Picker("Modo", selection: $mode) {
                ForEach(ViewerMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            if !isWalking {
                HStack(spacing: 8) {
                    Picker("Projeção", selection: $projection) {
                        ForEach(ViewerProjection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)

                    if projection != .plan {
                        viewButton("Topo", icon: "arrow.down.to.line") {
                            controller.show(.top)
                        }
                        viewButton("Frente", icon: "square") {
                            controller.show(.front)
                        }
                        viewButton("Lado", icon: "sidebar.right") {
                            controller.show(.side)
                        }
                        viewButton("3D", icon: "cube") {
                            controller.show(.isometric)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func viewButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleOnly)
                .font(.callout.weight(.medium))
                .frame(minWidth: 48, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .hoverEffect(.highlight)
        .accessibilityLabel("Vista \(title)")
    }

    // MARK: - Informações e controles de baixo

    private var bottomInfo: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dimensionsText)
                    .font(.callout.monospacedDigit())
                Text("Medidas aproximadas")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            if let notice = notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var planControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .accessibilityHidden(true)
            Text("Corte a \(FloorPlanSVG.formatMeters(planCutHeight)) m do piso")
                .font(.callout.monospacedDigit())
            Slider(value: $planCutHeight, in: 0.3...max(0.4, modelHeight), step: 0.05)
                .frame(maxWidth: 320)
                .accessibilityLabel("Altura do corte da planta")
            Button {
                savePlanImage()
            } label: {
                Label("Salvar PNG", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var walkControls: some View {
        HStack(alignment: .bottom) {
            joystick
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text("Altura dos olhos: \(FloorPlanSVG.formatMeters(eyeHeight)) m")
                    .font(.callout.monospacedDigit())
                Slider(value: $eyeHeight, in: 1.0...2.0, step: 0.05)
                    .frame(width: 220)
                    .accessibilityLabel("Altura dos olhos")
                Text("Arraste na tela para olhar em volta")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    controller.stopWalking()
                    isWalking = false
                    projection = .perspective
                } label: {
                    Label("Sair da caminhada", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Joystick virtual: arrastar o botão do centro move a pessoa.
    private var joystick: some View {
        let radius: CGFloat = 60
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 52, height: 52)
                .offset(joystickOffset)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let length = sqrt(dx * dx + dy * dy)
                    if length > radius {
                        dx = dx / length * radius
                        dy = dy / length * radius
                    }
                    joystickOffset = CGSize(width: dx, height: dy)
                    // Para cima na tela é "para frente".
                    controller.setWalkInput(SIMD2<Float>(Float(dx / radius), Float(-dy / radius)))
                }
                .onEnded { _ in
                    joystickOffset = .zero
                    controller.setWalkInput(SIMD2<Float>(0, 0))
                }
        )
        .accessibilityLabel("Joystick de caminhada")
    }

    // MARK: - Barra inferior

    private var bottomBar: some View {
        HStack(spacing: 4) {
            barButton("Apagar", icon: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }

            Menu {
                Toggle("Grade no piso", isOn: $showGrid)
                Toggle("Caixa de dimensões", isOn: $showBox)
                Toggle("Eixos na origem", isOn: $showAxes)
                Toggle("Mostrar FPS", isOn: $showStatistics)
                Divider()
                Button {
                    startWalking()
                } label: {
                    Label("Caminhar pelo scan", systemImage: "figure.walk")
                }
                Button {
                    openInAR()
                } label: {
                    Label("Ver em AR", systemImage: "arkit")
                }
            } label: {
                barLabel("Mais", icon: "ellipsis.circle")
            }
            .disabled(isBusy)

            NavigationLink {
                ExportOptionsView(hasKeyframes: hasColors)
            } label: {
                barLabel("Processar", icon: "slider.horizontal.3")
            }

            // Editor (M8) e medição (M9) ainda não existem: os botões ficam desativados.
            barButton("Editar", icon: "crop", role: nil) {
            }
            .disabled(true)
            barButton("Medir", icon: "ruler", role: nil) {
            }
            .disabled(true)

            barButton("Compartilhar", icon: "square.and.arrow.up", role: nil) {
                shareOutputs()
            }
            .disabled(isBusy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func barLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.caption2)
        }
        .frame(minWidth: 64, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func barButton(_ title: String, icon: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            barLabel(title, icon: icon)
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
    }

    // MARK: - Ações

    private func startWalking() {
        mode = hasColors ? .textured : .flat
        controller.startWalking()
        isWalking = controller.isWalking
    }

    /// Gera um USDZ temporário do modelo e abre no Quick Look, que oferece o modo AR.
    private func openInAR() {
        guard let mesh = loadedMesh else {
            return
        }
        isBusy = true
        notice = "Preparando o modelo para AR..."
        let id = scanID
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanLabShare", isDirectory: true)
            let url = folder.appendingPathComponent("scan-\(id).usdz")
            var errorText: String? = nil
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try USDZExporter.write(mesh, to: url)
            } catch {
                errorText = error.localizedDescription
                AppLog.error(.export, "Visualizador: falha ao gerar USDZ para AR: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                isBusy = false
                if let errorText = errorText {
                    notice = "Não foi possível abrir em AR: \(errorText)"
                } else {
                    notice = nil
                    previewRequest = PreviewRequest(url: url)
                }
            }
        }
    }

    private func savePlanImage() {
        guard let shot = controller.snapshot(), let data = shot.image.pngData() else {
            notice = "Não foi possível capturar a planta."
            return
        }
        let store = ScanStore.shared
        let outputs = store.outputsDirectory(for: scanID)
        let url = outputs.appendingPathComponent("planta-\(scanID).png")
        do {
            try AppPaths.ensureDirectory(outputs)
            try data.write(to: url, options: .atomic)
            var scaleText = ""
            if let pixelsPerMeter = shot.pixelsPerMeter {
                scaleText = String(format: " (%.0f px por metro)", pixelsPerMeter)
            }
            notice = "Planta salva nos arquivos do scan\(scaleText)."
            AppLog.info(.export, "Planta PNG do scan \(scanID): corte=\(planCutHeight) m\(scaleText)")
        } catch {
            notice = "Não foi possível salvar a planta: \(error.localizedDescription)"
        }
    }

    private func shareOutputs() {
        if ScanStore.shared.outputFiles(for: scanID).isEmpty {
            notice = "Ainda não há arquivos gerados. Use Processar e depois Gerar arquivos na tela do scan."
            return
        }
        isBusy = true
        let id = scanID
        DispatchQueue.global(qos: .userInitiated).async {
            var zipURL: URL? = nil
            var errorText: String? = nil
            do {
                zipURL = try ZipArchiver.zipOutputs(scanID: id)
            } catch {
                errorText = error.localizedDescription
            }
            DispatchQueue.main.async {
                isBusy = false
                if let zipURL = zipURL {
                    shareRequest = ShareRequest(urls: [zipURL])
                } else {
                    notice = "Não foi possível gerar o ZIP: \(errorText ?? "erro desconhecido")"
                }
            }
        }
    }
}
