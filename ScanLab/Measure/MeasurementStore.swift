import Foundation
import SwiftUI
import ScanCore

/// Ferramenta de medição ativa no visualizador.
enum MeasureTool: String, CaseIterable, Identifiable {
    case distance
    case area

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .distance: return "Distância"
        case .area: return "Área do piso"
        }
    }

    var icon: String {
        switch self {
        case .distance: return "ruler"
        case .area: return "square.dashed"
        }
    }
}

/// Guarda as medidas de um scan em `measurements.json`, na pasta dele.
/// Assim elas continuam lá ao abrir o scan de novo e entram no ZIP de "todos os dados".
enum MeasurementStore {
    static func url(for scanID: String) -> URL {
        return ScanStore.shared.directory(for: scanID).appendingPathComponent("measurements.json")
    }

    static func load(scanID: String) -> [MeasurementRecord] {
        guard let data = try? Data(contentsOf: url(for: scanID)),
              let records = try? JSONDecoder().decode([MeasurementRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [MeasurementRecord], scanID: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(records).write(to: url(for: scanID), options: .atomic)
        } catch {
            AppLog.error(.processing, "Falha ao salvar as medidas do scan \(scanID): \(error.localizedDescription)")
        }
    }
}

/// Lista das medidas, com renomear e apagar.
struct MeasurementListSheet: View {
    @Binding var measurements: [MeasurementRecord]
    /// Chamado depois de qualquer mudança, para salvar.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: MeasurementRecord? = nil
    @State private var draftName = ""
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if measurements.isEmpty {
                    ContentUnavailableView("Nenhuma medida",
                                           systemImage: "ruler",
                                           description: Text("Toque em dois pontos da malha para medir uma distância."))
                } else {
                    List {
                        ForEach(measurements) { record in
                            Button {
                                draftName = record.name
                                renaming = record
                            } label: {
                                HStack {
                                    Image(systemName: record.kind == .distance ? "ruler" : "square.dashed")
                                        .foregroundStyle(.orange)
                                    Text(record.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(record.formattedValue)
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            measurements.remove(atOffsets: offsets)
                            onChange()
                        }
                    }
                }
            }
            .navigationTitle("Medidas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Apagar todas", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(measurements.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") {
                        dismiss()
                    }
                }
            }
            .alert("Renomear medida", isPresented: renameBinding) {
                TextField("Nome", text: $draftName)
                Button("Salvar") {
                    rename()
                }
                Button("Cancelar", role: .cancel) {
                }
            }
            .alert("Apagar todas as medidas?", isPresented: $showClearConfirmation) {
                Button("Apagar", role: .destructive) {
                    measurements.removeAll()
                    onChange()
                }
                Button("Cancelar", role: .cancel) {
                }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        return Binding(
            get: { renaming != nil },
            set: { isPresented in
                if !isPresented {
                    renaming = nil
                }
            }
        )
    }

    private func rename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renaming, !trimmed.isEmpty,
              let index = measurements.firstIndex(where: { $0.id == target.id }) else {
            return
        }
        measurements[index].name = trimmed
        onChange()
    }
}
