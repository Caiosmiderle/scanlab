import SwiftUI
import UIKit
import RoomPlan
import ScanCore

/// A `RoomCaptureView` do RoomPlan dentro do SwiftUI. Ela já traz a câmera, o desenho
/// do cômodo em tempo real e as instruções para o usuário.
struct RoomCaptureViewContainer: UIViewRepresentable {
    let controller: RoomScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
    }
}

/// Aba "Cômodo": captura paramétrica com o RoomPlan e planta baixa.
struct RoomScanView: View {
    var body: some View {
        if RoomCaptureSession.isSupported {
            RoomScanSupportedView()
        } else {
            ContentUnavailableView("RoomPlan indisponível",
                                   systemImage: "house.slash",
                                   description: Text("Este aparelho não suporta a captura de cômodos. É preciso um iPad ou iPhone com sensor LiDAR."))
        }
    }
}

private struct RoomScanSupportedView: View {
    @StateObject private var controller = RoomScanController()
    @State private var showDiscardConfirmation = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack {
            RoomCaptureViewContainer(controller: controller)
                .ignoresSafeArea()

            if controller.state == .idle {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                Spacer()

                switch controller.state {
                case .idle:
                    idleCard
                    bigButton(title: "Iniciar cômodo", icon: "record.circle", tint: .accentColor) {
                        controller.start()
                    }
                case .scanning:
                    HStack(spacing: 16) {
                        smallButton(title: "Cancelar", icon: "xmark") {
                            controller.cancelRoom()
                        }
                        bigButton(title: "Concluir cômodo", icon: "checkmark.circle.fill", tint: .green) {
                            controller.finishRoom()
                        }
                    }
                case .processing:
                    progressCard("Montando o cômodo...")
                case .review:
                    reviewCard
                case .saving:
                    progressCard("Salvando USDZ e planta...")
                }
            }
            .padding()
        }
        .onChange(of: controller.state) { _, newState in
            // Tela ligada enquanto houver captura ou processamento.
            UIApplication.shared.isIdleTimerDisabled = (newState != .idle)
        }
        .confirmationDialog("Descartar os cômodos capturados?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Descartar tudo", role: .destructive) {
                controller.discardAll()
            }
            Button("Voltar", role: .cancel) {
            }
        } message: {
            Text("Nada foi salvo ainda. Os cômodos desta captura serão perdidos.")
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

    // MARK: - Cartões

    private var idleCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "house")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Planta do cômodo")
                .font(.title2)
                .fontWeight(.semibold)

            if let summary = controller.lastSavedSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Aponte para as paredes e contorne o cômodo inteiro", systemImage: "lightbulb")
                    Label("Siga as instruções que aparecem na tela", systemImage: "lightbulb")
                    Label("Para o apartamento todo, conclua um cômodo e adicione o próximo sem sair desta tela", systemImage: "lightbulb")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Text("Medidas aproximadas: confira com a trena.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func progressCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.callout)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var reviewCard: some View {
        VStack(spacing: 14) {
            // Com vários cômodos a lista pode passar da altura da tela (iPhone): nesse
            // caso ela rola dentro do cartão.
            ViewThatFits(in: .vertical) {
                roomList
                ScrollView {
                    roomList
                }
                .frame(maxHeight: verticalSizeClass == .compact ? 120 : 260)
            }

            Text("Medidas aproximadas: confira com a trena.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Quebra em duas linhas quando não cabe (iPhone).
            FlowLayout(spacing: 12, lineSpacing: 10) {
                smallButton(title: "Descartar", icon: "trash") {
                    showDiscardConfirmation = true
                }
                smallButton(title: "Outro cômodo", icon: "plus") {
                    controller.start()
                }
                bigButton(title: "Salvar", icon: "square.and.arrow.down", tint: .accentColor) {
                    controller.save()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 640)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var roomList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controller.rooms) { result in
                RoomSummaryRow(summary: result.summary)
            }
        }
    }

    // MARK: - Botões (alvos de 44 pt e hover, para dedo e Apple Pencil)

    private func bigButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 130, minHeight: 44)
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
}

/// Linha com as medidas de um cômodo. Usada na revisão e no detalhe da biblioteca.
struct RoomSummaryRow: View {
    let summary: RoomSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.name)
                .font(.headline)
            // Lado a lado quando cabe; um embaixo do outro numa tela estreita.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    measures
                }
                VStack(alignment: .leading, spacing: 2) {
                    measures
                }
            }
            .font(.callout)
            Text("\(summary.wallCount) paredes · \(summary.doorCount) portas · \(summary.windowCount) janelas")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var measures: some View {
        measure(icon: "square.dashed", label: "Área", value: areaText)
        measure(icon: "ruler", label: "Perímetro", value: "\(FloorPlanSVG.formatMeters(Float(summary.perimeter))) m")
        measure(icon: "arrow.up.and.down", label: "Pé-direito", value: heightText)
    }

    private var areaText: String {
        if let area = summary.area {
            return "\(FloorPlanSVG.formatMeters(Float(area))) m²"
        }
        return "contorno aberto"
    }

    private var heightText: String {
        if let height = summary.ceilingHeight {
            return "\(FloorPlanSVG.formatMeters(Float(height))) m"
        }
        return "?"
    }

    private func measure(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
