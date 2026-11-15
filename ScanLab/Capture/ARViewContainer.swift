import SwiftUI
import RealityKit
import ARKit

/// Exibe a câmera e a malha do LiDAR usando a `ARView` do RealityKit.
struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController

    func makeUIView(context: Context) -> ARView {
        // automaticallyConfigureSession = false: quem configura e roda a sessão é o
        // CaptureController, com reconstrução de cena. A ARView só desenha.
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = controller.session
        controller.attachDelegate()

        // Desenha a malha reconstruída por cima da câmera enquanto o scan acontece,
        // para o usuário ver o que já foi coberto.
        view.debugOptions.insert(.showSceneUnderstanding)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
    }
}
