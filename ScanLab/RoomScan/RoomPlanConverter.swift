import Foundation
import RoomPlan
import simd
import ScanCore

/// Converte um `CapturedRoom` do RoomPlan nas estruturas simples do ScanCore.
///
/// A geração da planta fica no ScanCore, sem tipos do RoomPlan, para poder ser testada
/// no CI. Este arquivo é a única ponte entre os dois mundos.
enum RoomPlanConverter {
    static func planRoom(from room: CapturedRoom, name: String) -> PlanRoom {
        // Cada superfície vertical tem a pose do seu centro (`transform`) e uma caixa
        // (`dimensions`): x é a largura ao longo da parede e y é a altura.
        var walls: [PlanSegment] = []
        var heightSum: Float = 0
        for wall in room.walls {
            walls.append(PlanGeometry.segment(transform: wall.transform, width: wall.dimensions.x))
            heightSum += wall.dimensions.y
        }

        var openings: [PlanOpening] = []
        for door in room.doors {
            openings.append(PlanOpening(kind: .door, segment: PlanGeometry.segment(transform: door.transform, width: door.dimensions.x)))
        }
        for window in room.windows {
            openings.append(PlanOpening(kind: .window, segment: PlanGeometry.segment(transform: window.transform, width: window.dimensions.x)))
        }
        for opening in room.openings {
            openings.append(PlanOpening(kind: .opening, segment: PlanGeometry.segment(transform: opening.transform, width: opening.dimensions.x)))
        }

        // Só usamos o contorno do piso quando o RoomPlan entrega exatamente um piso;
        // com vários pedaços, a área de um só ficaria menor que a do cômodo. Nesse caso
        // a planta cai para o contorno formado pelas paredes.
        var floorPolygon: [SIMD2<Float>] = []
        if room.floors.count == 1 {
            floorPolygon = floorOutline(room.floors[0])
        }

        let ceilingHeight: Float? = room.walls.isEmpty ? nil : heightSum / Float(room.walls.count)
        return PlanRoom(name: name,
                        walls: walls,
                        openings: openings,
                        floorPolygon: floorPolygon,
                        ceilingHeight: ceilingHeight)
    }

    /// Contorno do piso no plano da planta. Vazio se os dados não parecerem um piso.
    static func floorOutline(_ floor: CapturedRoom.Surface) -> [SIMD2<Float>] {
        // `polygonCorners` vem em coordenadas locais do plano da superfície. Se vier
        // vazio (piso retangular), montamos o retângulo a partir da caixa.
        var local = floor.polygonCorners
        if local.count < 3 {
            let halfX = floor.dimensions.x / 2
            let halfY = floor.dimensions.y / 2
            local = [SIMD3<Float>(-halfX, -halfY, 0),
                     SIMD3<Float>(halfX, -halfY, 0),
                     SIMD3<Float>(halfX, halfY, 0),
                     SIMD3<Float>(-halfX, halfY, 0)]
        }

        var lowestY = Float.greatestFiniteMagnitude
        var highestY = -Float.greatestFiniteMagnitude
        var outline: [SIMD2<Float>] = []
        for corner in local {
            let world4 = floor.transform * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            lowestY = min(lowestY, world.y)
            highestY = max(highestY, world.y)
            outline.append(PlanGeometry.planPoint(world))
        }

        // Um piso é horizontal: todos os cantos têm de estar quase na mesma altura.
        // Se não estiverem, a nossa leitura das coordenadas locais está errada para
        // este dado, e é melhor não usar do que desenhar um contorno torto.
        if highestY - lowestY > 0.3 {
            AppLog.warning(.processing, "Contorno do piso ignorado: cantos em alturas diferentes (\(highestY - lowestY) m)")
            return []
        }
        return outline
    }

    static func summary(of plan: PlanRoom, room: CapturedRoom) -> RoomSummary {
        var area: Double? = nil
        if let value = plan.area {
            area = Double(value)
        }
        var height: Double? = nil
        if let value = plan.ceilingHeight {
            height = Double(value)
        }
        return RoomSummary(name: plan.name,
                           area: area,
                           perimeter: Double(plan.perimeter),
                           ceilingHeight: height,
                           wallCount: room.walls.count,
                           doorCount: room.doors.count,
                           windowCount: room.windows.count)
    }
}
