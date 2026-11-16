import Foundation
import SceneKit
import UIKit
import ScanCore

/// Cena do editor de corte (marco M8): a malha, a caixa de corte e as seis alças.
///
/// Cada alça fica no centro de uma face da caixa. Arrastar uma alça move só aquela face,
/// ao longo do seu eixo. O arrasto funciona em qualquer vista: a direção do eixo na tela
/// é calculada projetando dois pontos do eixo, e o deslocamento do dedo (ou do Pencil) é
/// convertido em metros ao longo dele.
/// Todos os métodos devem ser chamados na thread principal.
final class EditorSceneController: NSObject, UIGestureRecognizerDelegate {
    let scene = SCNScene()

    /// Avisado a cada mudança da caixa feita pelas alças (para atualizar os controles).
    var onBoxChange: ((SIMD3<Float>, SIMD3<Float>) -> Void)?

    private weak var view: SCNView?
    private weak var handlePan: UIPanGestureRecognizer?

    private let meshRoot = SCNNode()
    private let boxRoot = SCNNode()
    private let cameraNode = SCNNode()

    private(set) var boxMin = SIMD3<Float>(-1, -1, -1)
    private(set) var boxMax = SIMD3<Float>(1, 1, 1)
    private var limitsMin = SIMD3<Float>(-1, -1, -1)
    private var limitsMax = SIMD3<Float>(1, 1, 1)
    private var radius: Float = 1

    // Arrasto de alça em andamento.
    private var pendingHandle: Int = -1
    private var dragHandle: Int = -1
    private var dragStartValue: Float = 0
    /// Deslocamento na tela, em pontos, que corresponde a 1 m ao longo do eixo da alça.
    private var dragScreenAxis = SIMD2<Float>(0, 0)

    /// Distância máxima, em pontos de tela, entre o toque e a alça para pegá-la.
    private static let grabDistance: Float = 40
    /// Menor tamanho permitido para a caixa em cada eixo, em metros.
    private static let minimumSize: Float = 0.05

    override init() {
        super.init()
        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 200
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(meshRoot)
        scene.rootNode.addChildNode(boxRoot)
    }

    func attach(view: SCNView) {
        self.view = view
        view.pointOfView = cameraNode

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        handlePan = pan

        // Os gestos de câmera do SceneKit esperam o arrasto de alça falhar. Ele falha na
        // hora quando o toque não começa perto de uma alça, então girar a câmera continua
        // imediato fora das alças.
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== pan {
            if recognizer is UIPanGestureRecognizer {
                recognizer.require(toFail: pan)
            }
        }
    }

    private var activeCamera: SCNNode {
        return view?.pointOfView ?? cameraNode
    }

    // MARK: - Malha e caixa

    /// Primeira carga: põe a malha e uma caixa que envolve tudo.
    func install(chunks: [ViewerChunk], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        limitsMin = boundsMin
        limitsMax = boundsMax
        radius = max(0.5, simd_length(boundsMax - boundsMin) / 2)
        replaceMesh(chunks: chunks)
        let margin = SIMD3<Float>(0.05, 0.05, 0.05)
        setBox(min: boundsMin - margin, max: boundsMax + margin)
        show(.isometric, orthographic: false)
    }

    /// Troca a malha (depois de um corte, desfazer ou refazer). A caixa continua onde estava.
    func replaceMesh(chunks: [ViewerChunk]) {
        for child in meshRoot.childNodes {
            child.removeFromParentNode()
        }
        for chunk in chunks {
            chunk.node.geometry = chunk.geometry(for: .flat)
            meshRoot.addChildNode(chunk.node)
        }
    }

    /// Caixa que envolve a malha inteira, com uma pequena folga.
    var fullBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let margin = SIMD3<Float>(0.05, 0.05, 0.05)
        return (limitsMin - margin, limitsMax + margin)
    }

    /// Limites para os controles de ajuste fino: a malha com 0,5 m de folga.
    var sliderRange: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let margin = SIMD3<Float>(0.5, 0.5, 0.5)
        return (limitsMin - margin, limitsMax + margin)
    }

    func setBox(min newMin: SIMD3<Float>, max newMax: SIMD3<Float>) {
        boxMin = newMin
        boxMax = newMax
        rebuildBox()
    }

    private func handlePosition(_ index: Int) -> SIMD3<Float> {
        let center = (boxMin + boxMax) / 2
        var position = center
        let axis = index / 2
        position[axis] = (index % 2 == 1) ? boxMax[axis] : boxMin[axis]
        return position
    }

    private func rebuildBox() {
        for child in boxRoot.childNodes {
            child.removeFromParentNode()
        }
        let size = simd_max(boxMax - boxMin, SIMD3<Float>(repeating: 0.001))
        let center = (boxMin + boxMax) / 2

        // Volume translúcido: deixa ver o que está dentro da caixa.
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let fill = SCNMaterial()
        fill.diffuse.contents = UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.12)
        fill.lightingModel = .constant
        fill.isDoubleSided = true
        fill.writesToDepthBuffer = false
        box.materials = [fill]
        let boxNode = SCNNode(geometry: box)
        boxNode.simdPosition = center
        boxNode.renderingOrder = 10
        boxRoot.addChildNode(boxNode)

        // Arestas.
        let a = boxMin
        let b = boxMax
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
        let lines = SCNNode(geometry: SceneGeometry.lines(points, color: UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)))
        boxRoot.addChildNode(lines)

        // Alças: X vermelha, Y verde, Z azul. Desenhadas por cima de tudo, para não
        // sumirem atrás das paredes.
        let colors = [UIColor.systemRed, UIColor.systemGreen, UIColor.systemBlue]
        let handleRadius = CGFloat(min(0.15, max(0.03, radius * 0.025)))
        for index in 0..<6 {
            let sphere = SCNSphere(radius: handleRadius)
            let material = SCNMaterial()
            material.diffuse.contents = colors[index / 2]
            material.lightingModel = .constant
            material.readsFromDepthBuffer = false
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.name = "alca-\(index)"
            node.simdPosition = handlePosition(index)
            node.renderingOrder = 100
            boxRoot.addChildNode(node)
        }
    }

    // MARK: - Câmera

    func show(_ standardView: ViewerStandardView, orthographic: Bool) {
        guard let view = view else {
            return
        }
        let camera = activeCamera.camera ?? SCNCamera()
        activeCamera.camera = camera
        camera.usesOrthographicProjection = orthographic
        camera.orthographicScale = Double(radius)

        let center = (limitsMin + limitsMax) / 2
        let distance = radius * 2.4
        var position = center
        var up = SIMD3<Float>(0, 1, 0)
        switch standardView {
        case .isometric:
            position = center + simd_normalize(SIMD3<Float>(1, 0.8, 1)) * distance
        case .top:
            position = center + SIMD3<Float>(0, distance, 0)
            up = SIMD3<Float>(0, 0, -1)
        case .front:
            position = center + SIMD3<Float>(0, 0, distance)
        case .side:
            position = center + SIMD3<Float>(distance, 0, 0)
        }
        let node = activeCamera
        node.simdPosition = position
        node.simdLook(at: center, up: up, localFront: SIMD3<Float>(0, 0, -1))
        view.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
    }

    // MARK: - Arrasto das alças

    private func screenPoint(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        guard let view = view else {
            return nil
        }
        let projected = view.projectPoint(SCNVector3(world.x, world.y, world.z))
        // z fora de 0...1 significa ponto atrás da câmera ou além do plano distante.
        if projected.z < 0 || projected.z > 1 {
            return nil
        }
        return SIMD2<Float>(Float(projected.x), Float(projected.y))
    }

    /// Alça mais próxima do ponto da tela, se estiver perto o bastante.
    private func handleIndex(near point: CGPoint) -> Int? {
        let touch = SIMD2<Float>(Float(point.x), Float(point.y))
        var best: Int? = nil
        var bestDistance = EditorSceneController.grabDistance
        for index in 0..<6 {
            guard let screen = screenPoint(handlePosition(index)) else {
                continue
            }
            let distance = simd_distance(screen, touch)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === handlePan, let view = view else {
            return true
        }
        // Começa só se o toque estiver em cima de uma alça; senão a câmera gira.
        if let index = handleIndex(near: gestureRecognizer.location(in: view)) {
            pendingHandle = index
            return true
        }
        return false
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let view = view else {
            return
        }
        switch recognizer.state {
        case .began:
            dragHandle = pendingHandle
            guard dragHandle >= 0 else {
                return
            }
            let axis = dragHandle / 2
            var direction = SIMD3<Float>(0, 0, 0)
            direction[axis] = 1
            let start = handlePosition(dragHandle)
            if let s0 = screenPoint(start), let s1 = screenPoint(start + direction) {
                dragScreenAxis = s1 - s0
            } else {
                dragScreenAxis = SIMD2<Float>(0, 0)
            }
            dragStartValue = (dragHandle % 2 == 1) ? boxMax[axis] : boxMin[axis]
        case .changed:
            guard dragHandle >= 0 else {
                return
            }
            let lengthSquared = simd_length_squared(dragScreenAxis)
            // Eixo apontando quase para a câmera: arrastar não tem direção útil.
            if lengthSquared < 4 {
                return
            }
            let translation = recognizer.translation(in: view)
            let moved = SIMD2<Float>(Float(translation.x), Float(translation.y))
            let meters = simd_dot(moved, dragScreenAxis) / lengthSquared
            let axis = dragHandle / 2
            var value = dragStartValue + meters
            if dragHandle % 2 == 1 {
                value = max(value, boxMin[axis] + EditorSceneController.minimumSize)
                value = min(value, limitsMax[axis] + 1)
                boxMax[axis] = value
            } else {
                value = min(value, boxMax[axis] - EditorSceneController.minimumSize)
                value = max(value, limitsMin[axis] - 1)
                boxMin[axis] = value
            }
            rebuildBox()
            onBoxChange?(boxMin, boxMax)
        default:
            dragHandle = -1
            pendingHandle = -1
        }
    }
}
