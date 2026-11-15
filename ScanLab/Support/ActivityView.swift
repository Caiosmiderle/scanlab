import SwiftUI
import UIKit

/// Pedido de compartilhamento: quais arquivos abrir na folha de compartilhar.
struct ShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Folha de compartilhamento do sistema (`UIActivityViewController`).
///
/// Usamos esta em vez do `ShareLink` do SwiftUI para os arquivos de scan porque aqui
/// entregamos as URLs dos arquivos reais: o destino recebe o arquivo com o nome
/// original (o OBJ referencia o `.mtl` pelo nome) e dá para mandar vários de uma vez.
struct ActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = urls
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
