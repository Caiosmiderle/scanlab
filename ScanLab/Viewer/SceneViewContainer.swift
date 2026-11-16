import SwiftUI
import SceneKit
import QuickLook

/// A `SCNView` do SceneKit dentro do SwiftUI.
///
/// Girar, deslizar e aproximar ficam por conta do controle de câmera do próprio
/// SceneKit (`allowsCameraControl`), que responde igualmente ao dedo e ao Apple Pencil.
struct SceneViewContainer: UIViewRepresentable {
    let controller: ViewerSceneController

    func makeCoordinator() -> Coordinator {
        return Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = controller.scene
        view.backgroundColor = UIColor(white: 0.07, alpha: 1)
        view.antialiasingMode = .multisampling2X
        // Luz padrão que acompanha a câmera, usada pelo modo Liso.
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // Só fica ativo no modo caminhada, para girar o olhar.
        let lookPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLookPan(_:)))
        lookPan.isEnabled = false
        view.addGestureRecognizer(lookPan)

        controller.attach(view: view, lookPan: lookPan)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
    }

    final class Coordinator: NSObject {
        let controller: ViewerSceneController

        init(controller: ViewerSceneController) {
            self.controller = controller
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            controller.setFocus(at: recognizer.location(in: recognizer.view))
        }

        @objc func handleLookPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            controller.look(deltaX: Float(translation.x), deltaY: Float(translation.y))
            // Zera para o próximo evento trazer só o deslocamento novo.
            recognizer.setTranslation(.zero, in: recognizer.view)
        }
    }
}

/// Visualização do sistema (Quick Look) para um arquivo. Com `.usdz`, o Quick Look
/// oferece o modo AR, que coloca o modelo no ambiente real.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        return Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }
    }
}

/// Arquivo a mostrar no Quick Look (precisa ser identificável para o `.sheet(item:)`).
struct PreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
}
