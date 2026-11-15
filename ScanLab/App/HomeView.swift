import SwiftUI
import ScanCore

/// Tela única do marco M0: prova que o caminho código → CI → .ipa → sideload funciona
/// e mostra se o aparelho tem LiDAR utilizável pelo ARKit.
struct HomeView: View {
    /// `nil` enquanto o botão ainda não foi tocado.
    @State private var lidarStatus: LidarStatus? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("ScanLab")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Versão \(AppInfo.versionText)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button {
                    lidarStatus = LidarSupport.check()
                } label: {
                    Label("Verificar LiDAR", systemImage: "dot.radiowaves.left.and.right")
                        .font(.title3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Verificar se o LiDAR está disponível")

                if let status = lidarStatus {
                    LidarStatusCard(status: status)
                }

                VStack(spacing: 4) {
                    Text("Aparelho: \(DeviceInfo.modelIdentifier)")
                    Text("Sistema: \(DeviceInfo.systemVersion)")
                    Text("ScanCore \(ScanCoreInfo.version)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Cartão com o resultado da verificação do LiDAR.
private struct LidarStatusCard: View {
    let status: LidarStatus

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(status.isAvailable ? Color.green : Color.red)
                .accessibilityHidden(true)

            Text(status.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .background(Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
