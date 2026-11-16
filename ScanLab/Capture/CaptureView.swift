import SwiftUI
import UIKit

/// Aba "Capturar": câmera em tela cheia, HUD discreto e controles grandes.
struct CaptureView: View {
    @StateObject private var controller = CaptureController()
    @State private var showCancelConfirmation = false

    private let tips = [
        "Mova o aparelho devagar",
        "Feche o laço voltando ao ponto de partida",
        "Evite espelhos e vidros",
        "Mantenha de 1 a 3 metros das superfícies"
    ]

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            // Antes de iniciar não há imagem da câmera: fundo escuro em vez de tela vazia.
            if controller.state == .idle {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                if controller.state != .idle {
                    hud
                }

                Spacer()

                if controller.state == .idle {
                    idleCard
                }
                if controller.state == .scanning {
                    statusBanner
                }
                if controller.state == .saving {
                    savingCard
                }

                controls
            }
            .padding()
        }
        .onChange(of: controller.state) { _, newState in
            // Tela sempre ligada durante o scan e a gravação; volta ao normal ao sair.
            UIApplication.shared.isIdleTimerDisabled = (newState != .idle)
        }
        .confirmationDialog("Descartar este scan?", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            Button("Descartar scan", role: .destructive) {
                controller.cancel()
            }
            Button("Continuar escaneando", role: .cancel) {
            }
        } message: {
            Text("A malha capturada até agora será perdida.")
        }
        .alert("Aviso", isPresented: alertBinding) {
            Button("OK", role: .cancel) {
            }
        } message: {
            Text(controller.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        return Binding(
            get: { controller.alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    controller.alertMessage = nil
                }
            }
        )
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 16) {
            hudItem(icon: "timer", text: formatDuration(controller.elapsedSeconds), label: "Tempo de scan")
            hudItem(icon: "square.grid.3x3", text: "\(controller.anchorCount)", label: "Blocos de malha")
            hudItem(icon: "triangle", text: formatCount(controller.triangleCount), label: "Triângulos")
            hudItem(icon: "photo.on.rectangle", text: "\(controller.keyframeCount)", label: "Fotos para cor")
            hudItem(icon: "thermometer.medium",
                    text: ThermalMonitor.label(controller.thermalState),
                    label: "Temperatura do aparelho",
                    highlighted: ThermalMonitor.isWarning(controller.thermalState))
            if controller.memoryWarning {
                hudItem(icon: "memorychip", text: "Memória baixa", label: "Aviso de memória", highlighted: true)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func hudItem(icon: String, text: String, label: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .foregroundStyle(highlighted ? Color.orange : Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(text)")
    }

    // MARK: - Cartões

    private var idleCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Pronto para escanear")
                .font(.title2)
                .fontWeight(.semibold)

            if let summary = controller.lastSavedSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
                Text("Veja o scan na aba Biblioteca.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb")
                            .font(.callout)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Text("Medidas aproximadas: o LiDAR do aparelho não substitui a trena.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var statusBanner: some View {
        // Prioridade: aviso de scan sem malha, depois aviso de rastreamento; sem aviso,
        // as dicas se revezam.
        let tracking = controller.meshWarning ?? controller.trackingMessage
        let tipIndex = Int(controller.elapsedSeconds / 6) % tips.count
        let text = tracking ?? tips[tipIndex]
        return Label(text, systemImage: tracking == nil ? "lightbulb" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(tracking == nil ? Color.primary : Color.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var savingCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: controller.savingProgress)
                .frame(maxWidth: 320)
            Text(controller.savingMessage)
                .font(.callout)
            Text("Não feche o app até terminar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Controles

    @ViewBuilder
    private var controls: some View {
        switch controller.state {
        case .idle:
            bigButton(title: "Iniciar", icon: "record.circle", tint: .accentColor) {
                controller.start()
            }
        case .scanning:
            HStack(spacing: 16) {
                smallButton(title: "Cancelar", icon: "xmark") {
                    showCancelConfirmation = true
                }
                bigButton(title: "Finalizar", icon: "stop.circle.fill", tint: .red) {
                    controller.finish(reason: "usuário")
                }
                smallButton(title: "Pausar", icon: "pause.fill") {
                    controller.pause()
                }
            }
        case .paused:
            HStack(spacing: 16) {
                smallButton(title: "Cancelar", icon: "xmark") {
                    showCancelConfirmation = true
                }
                bigButton(title: "Finalizar", icon: "stop.circle.fill", tint: .red) {
                    controller.finish(reason: "usuário")
                }
                smallButton(title: "Continuar", icon: "play.fill") {
                    controller.resume()
                }
            }
        case .saving:
            EmptyView()
        }
    }

    /// Botão principal. Alvo grande e efeito de hover para funcionar bem com o dedo
    /// e com o Apple Pencil (o iPad Pro M2 mostra o hover do Pencil antes do toque).
    private func bigButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 150, minHeight: 44)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(tint)
        .hoverEffect(.lift)
        .accessibilityLabel(title)
    }

    private func smallButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
                .frame(minWidth: 96, minHeight: 44)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .hoverEffect(.lift)
        .accessibilityLabel(title)
    }

    // MARK: - Formatação

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2f mi", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f mil", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
