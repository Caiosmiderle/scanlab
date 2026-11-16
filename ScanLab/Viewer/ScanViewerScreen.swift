import SwiftUI
import UIKit
import ScanCore

/// Visualizador 3D de um scan (marco M5).
struct ScanViewerScreen: View {
    let scanID: String
    let scanName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var controller = ViewerSceneController()

    /// Tela estreita (iPhone em pé, iPad em tela dividida): controles mais enxutos.
    private var isCompact: Bool {
        return horizontalSizeClass == .compact
    }

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

    // Medição (M9)
    @State private var measureTool: MeasureTool? = nil
    @State private var pendingPoints: [SIMD3<Float>] = []
    @State private var measurements: [MeasurementRecord] = []
    @State private var snapToCorners = true
    @State private var showMeasureList = false

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
                    } else if measureTool != nil {
                        if let notice = notice {
                            Text(notice)
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        measurePanel
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
            controller.onTap = { point in
                handleMeasureTap(point)
            }
            load()
        }
        .onDisappear {
            controller.stopWalking()
        }
        .onChange(of: measurements) { _, _ in
            renderMeasurements()
        }
        .onChange(of: pendingPoints) { _, _ in
            renderMeasurements()
        }
        .sheet(isPresented: $showMeasureList) {
            MeasurementListSheet(measurements: $measurements, onChange: {
                MeasurementStore.save(measurements, scanID: scanID)
            })
            .presentationDetents([.medium, .large])
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
                    measurements = MeasurementStore.load(scanID: id)
                    renderMeasurements()
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

    @ViewBuilder
    private var topControls: some View {
        if isCompact {
            compactTopControls
        } else {
            regularTopControls
        }
    }

    /// iPhone: os quatro modos e um botão que abre projeção e vistas rápidas num menu.
    /// Assim os controles ocupam uma linha só e não cobrem o modelo.
    private var compactTopControls: some View {
        HStack(spacing: 8) {
            Picker("Modo", selection: $mode) {
                ForEach(ViewerMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if !isWalking {
                Menu {
                    Picker("Projeção", selection: $projection) {
                        ForEach(ViewerProjection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if projection != .plan {
                        Divider()
                        Button("Vista de topo") {
                            controller.show(.top)
                        }
                        Button("Vista de frente") {
                            controller.show(.front)
                        }
                        Button("Vista de lado") {
                            controller.show(.side)
                        }
                        Button("Vista 3D") {
                            controller.show(.isometric)
                        }
                    }
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .accessibilityLabel("Projeção e vistas")
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var regularTopControls: some View {
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
        // No iPhone o aviso vai para baixo das medidas, em vez de ao lado.
        FlowLayout(spacing: 12, lineSpacing: 8) {
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

            if let notice = notice {
                Text(notice)
                    .font(isCompact ? .footnote : .callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var planControls: some View {
        if isCompact {
            // iPhone: texto e botão numa linha, o controle de altura embaixo, largo.
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .accessibilityHidden(true)
                    Text("Corte a \(FloorPlanSVG.formatMeters(planCutHeight)) m do piso")
                        .font(.footnote.monospacedDigit())
                    Spacer()
                    Button {
                        savePlanImage()
                    } label: {
                        Label("PNG", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                Slider(value: $planCutHeight, in: 0.3...max(0.4, modelHeight), step: 0.05)
                    .accessibilityLabel("Altura do corte da planta")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else {
            regularPlanControls
        }
    }

    private var regularPlanControls: some View {
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
                Text("Olhos a \(FloorPlanSVG.formatMeters(eyeHeight)) m")
                    .font((isCompact ? Font.footnote : Font.callout).monospacedDigit())
                Slider(value: $eyeHeight, in: 1.0...2.0, step: 0.05)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Altura dos olhos")
                Text("Arraste na tela para olhar em volta")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                Button {
                    controller.stopWalking()
                    isWalking = false
                    projection = .perspective
                } label: {
                    Label(isCompact ? "Sair" : "Sair da caminhada", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(isCompact ? 10 : 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Joystick virtual: arrastar o botão do centro move a pessoa.
    private var joystick: some View {
        let radius: CGFloat = isCompact ? 48 : 60
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: isCompact ? 44 : 52, height: isCompact ? 44 : 52)
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
        HStack(spacing: isCompact ? 0 : 4) {
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

            NavigationLink {
                EditorScreen(scanID: scanID, scanName: scanName)
            } label: {
                barLabel("Editar", icon: "crop")
            }
            .disabled(isWalking || isBusy)

            Button {
                toggleMeasuring()
            } label: {
                barLabel(measureTool == nil ? "Medir" : "Sair", icon: measureTool == nil ? "ruler" : "ruler.fill")
            }
            .hoverEffect(.highlight)
            .disabled(isWalking)
            .accessibilityLabel(measureTool == nil ? "Medir" : "Sair da medição")

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
            // No iPhone o texto some: seis botões com legenda não cabem na largura.
            // O nome continua disponível para o VoiceOver.
            if !isCompact {
                Text(title)
                    .font(.caption2)
            }
        }
        .frame(minWidth: isCompact ? 46 : 64, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }

    private func barButton(_ title: String, icon: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            barLabel(title, icon: icon)
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
    }

    // MARK: - Ações

    // MARK: - Medição (M9)

    private var measurePanel: some View {
        VStack(spacing: 10) {
            FlowLayout(spacing: 12, lineSpacing: 8) {
                Picker("Ferramenta", selection: Binding(get: { measureTool ?? .distance }, set: { tool in
                    measureTool = tool
                    pendingPoints = []
                })) {
                    ForEach(MeasureTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.icon).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Toggle("Ímã nos cantos", isOn: $snapToCorners)
                    .fixedSize()
            }

            Text(measureInstruction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            FlowLayout(spacing: 10, lineSpacing: 8) {
                if measureTool == .area {
                    Button {
                        finishArea()
                    } label: {
                        Label("Concluir área", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingPoints.count < 3)
                }
                Button {
                    if !pendingPoints.isEmpty {
                        pendingPoints.removeLast()
                    }
                } label: {
                    Label("Desfazer ponto", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(pendingPoints.isEmpty)

                Button {
                    showMeasureList = true
                } label: {
                    Label("Medidas (\(measurements.count))", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)

                Button {
                    exportMeasurements()
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(measurements.isEmpty || isBusy)
            }
            .hoverEffect(.highlight)

            Text("Medidas aproximadas (LiDAR). Confira com a trena.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var measureInstruction: String {
        switch measureTool {
        case .distance:
            return pendingPoints.isEmpty ? "Toque no primeiro ponto da malha." : "Toque no segundo ponto."
        case .area:
            if pendingPoints.count < 3 {
                return "Toque nos cantos do piso, em ordem. Faltam \(3 - pendingPoints.count) ponto(s) no mínimo."
            }
            let area = MeasureMath.horizontalArea(pendingPoints)
            return "\(pendingPoints.count) cantos, \(FloorPlanSVG.formatMeters(area)) m² até agora. Toque em mais cantos ou conclua."
        case .none:
            return ""
        }
    }

    private func toggleMeasuring() {
        if measureTool == nil {
            measureTool = .distance
            pendingPoints = []
            notice = nil
        } else {
            measureTool = nil
            pendingPoints = []
            notice = nil
        }
    }

    private func handleMeasureTap(_ point: CGPoint) {
        guard let tool = measureTool, !isWalking else {
            return
        }
        guard let surface = controller.surfacePoint(at: point, snapDistance: snapToCorners ? 0.03 : 0) else {
            notice = "Toque em cima da malha."
            return
        }
        notice = nil
        pendingPoints.append(surface)
        if tool == .distance && pendingPoints.count == 2 {
            addMeasurement(kind: .distance)
        }
    }

    private func finishArea() {
        guard pendingPoints.count >= 3 else {
            return
        }
        addMeasurement(kind: .area)
    }

    private func addMeasurement(kind: MeasurementKind) {
        let number = measurements.count + 1
        let name = kind == .distance ? "Distância \(number)" : "Área \(number)"
        let record = MeasurementRecord(name: name, kind: kind, points: pendingPoints)
        measurements.append(record)
        pendingPoints = []
        MeasurementStore.save(measurements, scanID: scanID)
        notice = "\(name): \(record.formattedValue)"
        AppLog.info(.processing, "Medida no scan \(scanID): \(name) = \(record.formattedValue) pontos=\(record.points.count) ímã=\(snapToCorners)")
    }

    private func renderMeasurements() {
        controller.showMeasurements(measurements, pending: pendingPoints, pendingClosed: measureTool == .area)
    }

    /// Grava as medidas em CSV e uma imagem da vista atual, e abre o compartilhamento.
    private func exportMeasurements() {
        let outputs = ScanStore.shared.outputsDirectory(for: scanID)
        let csvURL = outputs.appendingPathComponent("medidas-\(scanID).csv")
        let imageURL = outputs.appendingPathComponent("medidas-\(scanID).png")
        do {
            try AppPaths.ensureDirectory(outputs)
            try Data(MeasureMath.csv(measurements).utf8).write(to: csvURL, options: .atomic)
            var urls = [csvURL]
            if let shot = controller.snapshot(), let png = shot.image.pngData() {
                try png.write(to: imageURL, options: .atomic)
                urls.append(imageURL)
            }
            AppLog.info(.export, "Medidas do scan \(scanID) exportadas: \(measurements.count) medidas")
            shareRequest = ShareRequest(urls: urls)
        } catch {
            notice = "Não foi possível exportar as medidas: \(error.localizedDescription)"
        }
    }

    private func startWalking() {
        measureTool = nil
        pendingPoints = []
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
