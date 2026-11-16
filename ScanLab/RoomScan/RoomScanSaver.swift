import Foundation
import RoomPlan
import ScanCore

/// Um cômodo já processado pelo RoomPlan, com a versão simplificada para a planta.
struct RoomResult: Identifiable {
    let id = UUID()
    let room: CapturedRoom
    let plan: PlanRoom
    let summary: RoomSummary
}

/// Grava na biblioteca o resultado de uma captura do RoomPlan.
///
/// Em `Documents/Scans/<id>/`:
/// - `rooms/comodo-N.json`: o `CapturedRoom` codificado (dado bruto, para reprocessar)
/// - `plan.json`: os cômodos nas estruturas simples do ScanCore
/// - `outputs/comodo-N-malha.usdz` e `comodo-N-parametrico.usdz`
/// - `outputs/apartamento-<id>.usdz`: todos os cômodos juntos (se houver mais de um)
/// - `outputs/planta-<id>.svg`: planta baixa com cotas e áreas
enum RoomScanSaver {
    static func save(_ results: [RoomResult]) async throws -> ScanMeta {
        let started = Date()
        let store = ScanStore.shared
        let id = try store.prepareScanFolder()
        let folder = store.directory(for: id)

        do {
            let roomsFolder = folder.appendingPathComponent("rooms", isDirectory: true)
            try AppPaths.ensureDirectory(roomsFolder)
            let outputs = store.outputsDirectory(for: id)
            let encoder = JSONEncoder()

            var planRooms: [PlanRoom] = []
            var summaries: [RoomSummary] = []
            var capturedRooms: [CapturedRoom] = []

            for position in 0..<results.count {
                let result = results[position]
                let number = position + 1
                planRooms.append(result.plan)
                summaries.append(result.summary)
                capturedRooms.append(result.room)

                try encoder.encode(result.room).write(to: roomsFolder.appendingPathComponent("comodo-\(number).json"), options: .atomic)

                // Dois USDZ por cômodo. "Malha" tem os vãos de porta e janela recortados
                // nas paredes e é o melhor para visualizar; "paramétrico" é feito de
                // caixas simples, mais fácil de editar em programas de modelagem.
                try result.room.export(to: outputs.appendingPathComponent("comodo-\(number)-malha.usdz"), exportOptions: .mesh)
                do {
                    try result.room.export(to: outputs.appendingPathComponent("comodo-\(number)-parametrico.usdz"), exportOptions: .parametric)
                } catch {
                    AppLog.warning(.export, "USDZ paramétrico do cômodo \(number) falhou: \(error.localizedDescription)")
                }
            }

            // Vários cômodos: junta tudo numa estrutura só. Funciona porque os cômodos
            // foram capturados na mesma sessão de AR e compartilham o mesmo mundo.
            if capturedRooms.count > 1 {
                do {
                    let builder = StructureBuilder(options: [.beautifyObjects])
                    let structure = try await builder.capturedStructure(from: capturedRooms)
                    try structure.export(to: outputs.appendingPathComponent("apartamento-\(id).usdz"), exportOptions: .mesh)
                } catch {
                    AppLog.warning(.export, "Junção dos cômodos em uma estrutura falhou: \(error.localizedDescription)")
                }
            }

            try JSONEncoder().encode(planRooms).write(to: folder.appendingPathComponent("plan.json"), options: .atomic)

            let nameFormatter = DateFormatter()
            nameFormatter.locale = Locale(identifier: "pt_BR")
            nameFormatter.dateFormat = "dd/MM/yyyy HH:mm"
            let now = Date()
            let title = results.count == 1 ? "Cômodo \(nameFormatter.string(from: now))" : "Planta \(nameFormatter.string(from: now))"

            let svg = FloorPlanSVG.render(rooms: planRooms, options: FloorPlanOptions(title: title))
            try Data(svg.utf8).write(to: outputs.appendingPathComponent("planta-\(id).svg"), options: .atomic)

            let meta = ScanMeta(id: id,
                                name: title,
                                createdAt: now,
                                deviceModel: DeviceInfo.modelIdentifier,
                                systemVersion: DeviceInfo.systemVersion,
                                appVersion: AppInfo.versionText,
                                durationSeconds: 0,
                                anchorCount: 0,
                                vertexCount: 0,
                                faceCount: 0,
                                reconstructionMode: "roomplan",
                                status: "processado",
                                keyframeCount: nil,
                                kind: ScanKind.room,
                                rooms: summaries)
            try store.saveMeta(meta)

            let seconds = Date().timeIntervalSince(started)
            AppLog.info(.export, "RoomPlan salvo: id=\(id) cômodos=\(results.count) tempo=\(String(format: "%.1f", seconds))s")
            return meta
        } catch {
            // Não deixa uma pasta pela metade.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
