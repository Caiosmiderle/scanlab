import Foundation
import SceneKit
import UIKit
import ScanCore

/// Dono da cena do visualizador: malha, grade, caixa de dimensões, eixos e câmera.
/// Todos os métodos devem ser chamados na thread principal.
final class ViewerSceneController {
    let scene = SCNScene()

    private weak var view: SCNView?
    private weak var lookPan: UIPanGestureRecognizer?
    private var model: ViewerModel?

    private let meshRoot = SCNNode()
    private let gridNode = SCNNode()
    private let boxNode = SCNNode()
    private let axesNode = SCNNode()
    private let measureRoot = SCNNode()
    private let cameraNode = SCNNode()

    /// Toque simples na cena (usado pela medição). `nil` quando ninguém está ouvindo.
    var onTap: ((CGPoint) -> Void)?

    private var projection: ViewerProjection = .perspective
    /// Altura do corte do modo Planta, em metros acima do piso.
    private var planCutHeight: Float = 2.0

    // Modo caminhada.
    private(set) var isWalking = false
    private var walkTimer: Timer?
    private var walkYaw: Float = 0
    private var walkPitch: Float = 0
    private var walkPosition = SIMD3<Float>(0, 0, 0)
    private var walkInput = SIMD2<Float>(0, 0)
    private var eyeHeight: Float = 1.6
    private var lastWalkTick = Date()
    /// Velocidade de caminhada, em metros por segundo.
    private static let walkSpeed: Float = 1.4

    init() {
        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 200
        camera.fieldOfView = 60
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        // Luz ambiente suave para o modo Liso não ficar com sombras duras.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 350
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        scene.rootNode.addChildNode(meshRoot)
        scene.rootNode.addChildNode(gridNode)
        scene.rootNode.addChildNode(boxNode)
        scene.rootNode.addChildNode(axesNode)
        scene.rootNode.addChildNode(measureRoot)
    }

    deinit {
        walkTimer?.invalidate()
    }

    /// Chamado quando a `SCNView` é criada.
    func attach(view: SCNView, lookPan: UIPanGestureRecognizer) {
        self.view = view
        self.lookPan = lookPan
        view.pointOfView = cameraNode
    }

    /// A câmera em uso. Com o controle de câmera ligado, o SceneKit pode trocar o
    /// ponto de vista por uma cópia própria, então sempre perguntamos à view.
    private var activeCamera: SCNNode {
        return view?.pointOfView ?? cameraNode
    }

    // MARK: - Modelo

    func install(_ model: ViewerModel, mode: ViewerMode) {
        self.model = model
        for child in meshRoot.childNodes {
            child.removeFromParentNode()
        }
        for chunk in model.chunks {
            chunk.node.geometry = chunk.geometry(for: mode)
            meshRoot.addChildNode(chunk.node)
        }
        planCutHeight = max(0.5, model.extent.y - 0.4)
        rebuildGrid(model)
        rebuildBox(model)
        rebuildAxes()
        apply(projection: .perspective)
        show(.isometric)
    }

    func apply(mode: ViewerMode) {
        guard let model = model else {
            return
        }
        for chunk in model.chunks {
            chunk.node.geometry = chunk.geometry(for: mode)
        }
    }

    func setGridVisible(_ visible: Bool) {
        gridNode.isHidden = !visible
    }

    func setBoxVisible(_ visible: Bool) {
        boxNode.isHidden = !visible
    }

    func setAxesVisible(_ visible: Bool) {
        axesNode.isHidden = !visible
    }

    func setStatisticsVisible(_ visible: Bool) {
        view?.showsStatistics = visible
    }

    /// Texto com as dimensões da caixa: largura (X) x comprimento (Z) x altura (Y).
    var dimensionsText: String {
        guard let model = model else {
            return ""
        }
        let extent = model.extent
        return "L \(FloorPlanSVG.formatMeters(extent.x)) × C \(FloorPlanSVG.formatMeters(extent.z)) × A \(FloorPlanSVG.formatMeters(extent.y)) m"
    }

    var modelHeight: Float {
        return model?.extent.y ?? 2.5
    }

    // MARK: - Câmera

    func apply(projection newProjection: ViewerProjection) {
        guard let model = model, let view = view else {
            return
        }
        projection = newProjection
        let camera = activeCamera.camera ?? SCNCamera()
        activeCamera.camera = camera
        let controller = view.defaultCameraController

        switch newProjection {
        case .perspective:
            camera.usesOrthographicProjection = false
            camera.zNear = 0.02
            controller.interactionMode = .orbitTurntable
            show(.isometric)
        case .orthographic:
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(model.radius)
            camera.zNear = 0.02
            controller.interactionMode = .orbitTurntable
            show(.isometric)
        case .plan:
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(max(model.extent.x, model.extent.z) / 2 * 1.1)
            camera.zNear = 0.001
            // No modo Planta o arrasto desliza a vista em vez de girar.
            controller.interactionMode = .truck
            placePlanCamera()
        }
    }

    /// Altura do corte do modo Planta, em metros acima do piso.
    func setPlanCutHeight(_ height: Float) {
        planCutHeight = height
        if projection == .plan {
            placePlanCamera()
        }
    }

    var currentPlanCutHeight: Float {
        return planCutHeight
    }

    /// Põe a câmera olhando para baixo, na altura do corte. O que está acima da câmera
    /// (teto, parte alta das paredes) fica atrás dela e não é desenhado: é assim que o
    /// teto some sem precisar cortar a malha.
    private func placePlanCamera() {
        guard let model = model else {
            return
        }
        let center = model.center
        let cutY = model.boundsMin.y + planCutHeight
        let position = SIMD3<Float>(center.x, cutY, center.z)
        let target = SIMD3<Float>(center.x, model.boundsMin.y, center.z)
        place(position: position, target: target, up: SIMD3<Float>(0, 0, -1))
    }

    func show(_ standardView: ViewerStandardView) {
        guard let model = model else {
            return
        }
        if projection == .plan {
            placePlanCamera()
            return
        }
        let center = model.center
        let distance = model.radius * 2.4
        switch standardView {
        case .isometric:
            let direction = simd_normalize(SIMD3<Float>(1, 0.8, 1))
            place(position: center + direction * distance, target: center, up: SIMD3<Float>(0, 1, 0))
        case .top:
            place(position: center + SIMD3<Float>(0, distance, 0), target: center, up: SIMD3<Float>(0, 0, -1))
        case .front:
            place(position: center + SIMD3<Float>(0, 0, distance), target: center, up: SIMD3<Float>(0, 1, 0))
        case .side:
            place(position: center + SIMD3<Float>(distance, 0, 0), target: center, up: SIMD3<Float>(0, 1, 0))
        }
    }

    private func place(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        let node = activeCamera
        node.simdPosition = position
        node.simdLook(at: target, up: up, localFront: SIMD3<Float>(0, 0, -1))
        view?.defaultCameraController.target = SCNVector3(target.x, target.y, target.z)
    }

    /// Duplo toque: o ponto tocado na malha vira o centro de giro da câmera.
    func setFocus(at point: CGPoint) {
        guard let view = view, !isWalking else {
            return
        }
        let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
        for hit in hits {
            // Ignora a grade, a caixa e os eixos: só a malha serve de foco.
            if hit.node.parent === meshRoot {
                view.defaultCameraController.target = hit.worldCoordinates
                return
            }
        }
    }

    // MARK: - Planta em PNG

    /// Captura a vista atual. Em modo Planta, devolve também os pixels por metro.
    func snapshot() -> (image: UIImage, pixelsPerMeter: Double?)? {
        guard let view = view else {
            return nil
        }
        let image = view.snapshot()
        var pixelsPerMeter: Double? = nil
        if projection == .plan, let camera = activeCamera.camera, camera.orthographicScale > 0 {
            // Na projeção ortográfica, a altura da imagem cobre 2 x orthographicScale metros.
            let pixelHeight = Double(image.size.height * image.scale)
            pixelsPerMeter = pixelHeight / (2 * camera.orthographicScale)
        }
        return (image, pixelsPerMeter)
    }

    // MARK: - Caminhada

    func startWalking() {
        guard let model = model, let view = view, !isWalking else {
            return
        }
        isWalking = true
        view.allowsCameraControl = false
        lookPan?.isEnabled = true

        let camera = cameraNode.camera ?? SCNCamera()
        camera.usesOrthographicProjection = false
        camera.zNear = 0.02
        camera.fieldOfView = 70
        cameraNode.camera = camera
        view.pointOfView = cameraNode

        let center = model.center
        walkPosition = SIMD3<Float>(center.x, model.boundsMin.y + eyeHeight, center.z)
        walkYaw = 0
        walkPitch = 0
        walkInput = SIMD2<Float>(0, 0)
        applyWalkTransform()

        lastWalkTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.walkTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        walkTimer = timer
    }

    func stopWalking() {
        guard isWalking, let view = view else {
            return
        }
        isWalking = false
        walkTimer?.invalidate()
        walkTimer = nil
        lookPan?.isEnabled = false
        cameraNode.camera?.fieldOfView = 60
        view.allowsCameraControl = true
        view.pointOfView = cameraNode
        apply(projection: .perspective)
    }

    /// Direção do joystick: x para os lados, y para frente (positivo) e para trás.
    func setWalkInput(_ input: SIMD2<Float>) {
        walkInput = input
    }

    func setEyeHeight(_ height: Float) {
        eyeHeight = height
        if isWalking, let model = model {
            walkPosition.y = model.boundsMin.y + eyeHeight
            applyWalkTransform()
        }
    }

    /// Arrasto na tela durante a caminhada: gira a cabeça.
    func look(deltaX: Float, deltaY: Float) {
        guard isWalking else {
            return
        }
        walkYaw -= deltaX * 0.005
        walkPitch -= deltaY * 0.005
        // Limita o olhar para cima e para baixo a cerca de 80 graus.
        walkPitch = max(-1.4, min(1.4, walkPitch))
        applyWalkTransform()
    }

    private func walkTick() {
        guard isWalking, let model = model else {
            return
        }
        let now = Date()
        let elapsed = Float(min(0.1, now.timeIntervalSince(lastWalkTick)))
        lastWalkTick = now
        if walkInput.x == 0 && walkInput.y == 0 {
            return
        }
        // Frente e direita no plano do piso, de acordo com para onde a pessoa olha.
        let forward = SIMD3<Float>(-sin(walkYaw), 0, -cos(walkYaw))
        let right = SIMD3<Float>(cos(walkYaw), 0, -sin(walkYaw))
        let step = (forward * walkInput.y + right * walkInput.x) * ViewerSceneController.walkSpeed * elapsed
        walkPosition += step
        // A altura fica presa ao piso mais a altura dos olhos: não dá para atravessar
        // o chão nem sair voando. Um pouco de folga deixa passar pelas portas do scan.
        walkPosition.x = max(model.boundsMin.x - 1, min(model.boundsMax.x + 1, walkPosition.x))
        walkPosition.z = max(model.boundsMin.z - 1, min(model.boundsMax.z + 1, walkPosition.z))
        walkPosition.y = model.boundsMin.y + eyeHeight
        applyWalkTransform()
    }

    private func applyWalkTransform() {
        cameraNode.simdPosition = walkPosition
        cameraNode.simdEulerAngles = SIMD3<Float>(walkPitch, walkYaw, 0)
    }

    // MARK: - Elementos de apoio

    /// Grade no nível do piso, com uma linha a cada metro.
    private func rebuildGrid(_ model: ViewerModel) {
        let y = model.boundsMin.y
        let minX = model.boundsMin.x.rounded(.down) - 1
        let maxX = model.boundsMax.x.rounded(.up) + 1
        let minZ = model.boundsMin.z.rounded(.down) - 1
        let maxZ = model.boundsMax.z.rounded(.up) + 1
        var points: [SIMD3<Float>] = []
        var x = minX
        while x <= maxX {
            points.append(SIMD3<Float>(x, y, minZ))
            points.append(SIMD3<Float>(x, y, maxZ))
            x += 1
        }
        var z = minZ
        while z <= maxZ {
            points.append(SIMD3<Float>(minX, y, z))
            points.append(SIMD3<Float>(maxX, y, z))
            z += 1
        }
        gridNode.geometry = SceneGeometry.lines(points, color: UIColor(white: 0.32, alpha: 1))
    }

    /// Caixa delimitadora com as três dimensões escritas nas arestas.
    private func rebuildBox(_ model: ViewerModel) {
        for child in boxNode.childNodes {
            child.removeFromParentNode()
        }
        let a = model.boundsMin
        let b = model.boundsMax
        let corners = [
            SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(b.x, a.y, a.z), SIMD3<Float>(b.x, a.y, b.z), SIMD3<Float>(a.x, a.y, b.z),
            SIMD3<Float>(a.x, b.y, a.z), SIMD3<Float>(b.x, b.y, a.z), SIMD3<Float>(b.x, b.y, b.z), SIMD3<Float>(a.x, b.y, b.z)
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var points: [SIMD3<Float>] = []
        for edge in edges {
            points.append(corners[edge.0])
            points.append(corners[edge.1])
        }
        let color = UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)
        boxNode.geometry = SceneGeometry.lines(points, color: color)

        // Rótulos: largura (X) e comprimento (Z) nas arestas de baixo, altura (Y) numa quina.
        let extent = model.extent
        let labelHeight = max(0.08, model.radius * 0.035)
        addLabel("\(FloorPlanSVG.formatMeters(extent.x)) m",
                 at: SIMD3<Float>((a.x + b.x) / 2, a.y, b.z), height: labelHeight, color: color)
        addLabel("\(FloorPlanSVG.formatMeters(extent.z)) m",
                 at: SIMD3<Float>(b.x, a.y, (a.z + b.z) / 2), height: labelHeight, color: color)
        addLabel("\(FloorPlanSVG.formatMeters(extent.y)) m",
                 at: SIMD3<Float>(b.x, (a.y + b.y) / 2, b.z), height: labelHeight, color: color)
    }

    private func addLabel(_ string: String, at position: SIMD3<Float>, height: Float, color: UIColor) {
        boxNode.addChildNode(ViewerSceneController.labelNode(string, at: position, height: height, color: color))
    }

    /// Texto que fica sempre de frente para a câmera.
    /// - Parameter height: altura das letras, em metros.
    static func labelNode(_ string: String, at position: SIMD3<Float>, height: Float, color: UIColor, alwaysOnTop: Bool = false) -> SCNNode {
        let text = SCNText(string: string, extrusionDepth: 0)
        // O SCNText mede em pontos de fonte: desenhamos com fonte 10 e reduzimos o nó.
        text.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        text.flatness = 0.2
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        if alwaysOnTop {
            material.readsFromDepthBuffer = false
        }
        text.materials = [material]

        let textNode = SCNNode(geometry: text)
        if alwaysOnTop {
            textNode.renderingOrder = 200
        }
        // Centraliza o texto no próprio nó, para ele girar em torno do meio.
        let (lower, upper) = text.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((lower.x + upper.x) / 2, lower.y, 0)
        let scale = height / 10
        textNode.scale = SCNVector3(scale, scale, scale)

        let holder = SCNNode()
        holder.simdPosition = position
        // O rótulo fica sempre de frente para a câmera.
        holder.constraints = [SCNBillboardConstraint()]
        holder.addChildNode(textNode)
        return holder
    }

    // MARK: - Medição (M9)

    func handleTap(at point: CGPoint) {
        onTap?(point)
    }

    /// Ponto da malha sob o toque, no mundo do scan.
    /// - Parameter snapDistance: se maior que zero, o ponto gruda no vértice mais próximo
    ///   dentro dessa distância (metros). Ajuda a pegar quinas, onde há mais vértices.
    func surfacePoint(at point: CGPoint, snapDistance: Float) -> SIMD3<Float>? {
        guard let view = view, let model = model else {
            return nil
        }
        let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
        for hit in hits where hit.node.parent === meshRoot {
            let world = hit.worldCoordinates
            let surface = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
            if snapDistance > 0,
               let snapped = MeasureMath.nearestVertex(to: surface, positions: model.mesh.positions, maxDistance: snapDistance) {
                return snapped
            }
            return surface
        }
        return nil
    }

    /// Desenha as medidas salvas (laranja) e a que está sendo feita (ciano).
    /// Linhas, pontos e rótulos são desenhados por cima da malha, para não sumirem
    /// dentro das paredes.
    func showMeasurements(_ records: [MeasurementRecord], pending: [SIMD3<Float>], pendingClosed: Bool) {
        for child in measureRoot.childNodes {
            child.removeFromParentNode()
        }
        let size = model?.radius ?? 1
        let dotRadius = CGFloat(min(0.04, max(0.012, size * 0.008)))
        let labelHeight = max(0.06, size * 0.03)

        func addPath(_ points: [SIMD3<Float>], closed: Bool, color: UIColor) {
            for point in points {
                let sphere = SCNSphere(radius: dotRadius)
                let material = SCNMaterial()
                material.diffuse.contents = color
                material.lightingModel = .constant
                material.readsFromDepthBuffer = false
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.simdPosition = point
                node.renderingOrder = 150
                measureRoot.addChildNode(node)
            }
            if points.count < 2 {
                return
            }
            var segments: [SIMD3<Float>] = []
            for index in 1..<points.count {
                segments.append(points[index - 1])
                segments.append(points[index])
            }
            if closed && points.count > 2, let first = points.first, let last = points.last {
                segments.append(last)
                segments.append(first)
            }
            let geometry = SceneGeometry.lines(segments, color: color)
            geometry.firstMaterial?.readsFromDepthBuffer = false
            let lineNode = SCNNode(geometry: geometry)
            lineNode.renderingOrder = 140
            measureRoot.addChildNode(lineNode)
        }

        let saved = UIColor.systemOrange
        for record in records {
            addPath(record.points, closed: record.kind == .area, color: saved)
            // Rótulo um pouco acima do meio da medida.
            let position = record.labelPoint + SIMD3<Float>(0, labelHeight * 0.8, 0)
            measureRoot.addChildNode(ViewerSceneController.labelNode("\(record.name): \(record.formattedValue)",
                                                                     at: position, height: labelHeight, color: saved, alwaysOnTop: true))
        }
        addPath(pending, closed: pendingClosed, color: UIColor.systemCyan)
    }

    /// Esconde ou mostra as medidas sem apagá-las.
    func setMeasurementsVisible(_ visible: Bool) {
        measureRoot.isHidden = !visible
    }

    /// Eixos na origem do scan (onde a captura começou): X vermelho, Y verde, Z azul.
    private func rebuildAxes() {
        for child in axesNode.childNodes {
            child.removeFromParentNode()
        }
        let origin = SIMD3<Float>(0, 0, 0)
        let axes: [(SIMD3<Float>, UIColor)] = [
            (SIMD3<Float>(1, 0, 0), UIColor.systemRed),
            (SIMD3<Float>(0, 1, 0), UIColor.systemGreen),
            (SIMD3<Float>(0, 0, 1), UIColor.systemBlue)
        ]
        for axis in axes {
            let node = SCNNode(geometry: SceneGeometry.lines([origin, axis.0], color: axis.1))
            axesNode.addChildNode(node)
        }
    }
}
