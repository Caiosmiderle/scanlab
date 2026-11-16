import Foundation
import simd

/// Corte por caixa (marco M8).
///
/// O corte age sobre os dados brutos por bloco (`MeshAnchorData`), não sobre a malha
/// já montada: assim o resultado pode ser salvo como um novo `mesh.bin` e passar por
/// todo o processamento (cor, textura, exportação) como qualquer scan.
public enum MeshCropper {
    public static func isInside(_ point: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> Bool {
        return point.x >= boxMin.x && point.x <= boxMax.x
            && point.y >= boxMin.y && point.y <= boxMax.y
            && point.z >= boxMin.z && point.z <= boxMax.z
    }

    /// Remove as faces cujo centro está dentro da caixa (`removeInside`) ou fora dela.
    /// A caixa é dada no mundo (Y-up). Blocos que ficam sem nenhuma face são descartados.
    public static func crop(anchors: [MeshAnchorData],
                            boxMin: SIMD3<Float>,
                            boxMax: SIMD3<Float>,
                            removeInside: Bool) -> [MeshAnchorData] {
        var result: [MeshAnchorData] = []
        result.reserveCapacity(anchors.count)

        for anchor in anchors where anchor.isConsistent {
            let m = anchor.transform
            let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

            func world(_ vertex: Int) -> SIMD3<Float> {
                let offset = vertex * 3
                return c0 * anchor.positions[offset] + c1 * anchor.positions[offset + 1] + c2 * anchor.positions[offset + 2] + translation
            }

            // 1. Quais faces ficam e quais vértices elas usam.
            var keptFaces: [Int] = []
            var used = [Bool](repeating: false, count: anchor.vertexCount)
            for face in 0..<anchor.faceCount {
                let ia = Int(anchor.indices[face * 3])
                let ib = Int(anchor.indices[face * 3 + 1])
                let ic = Int(anchor.indices[face * 3 + 2])
                let center = (world(ia) + world(ib) + world(ic)) / 3
                let inside = isInside(center, boxMin: boxMin, boxMax: boxMax)
                if inside == removeInside {
                    continue
                }
                keptFaces.append(face)
                used[ia] = true
                used[ib] = true
                used[ic] = true
            }

            // 2. Copia os vértices usados na ordem original. Assim um bloco que não perdeu
            // nada sai idêntico ao que entrou, e os índices continuam previsíveis.
            var remap = [UInt32](repeating: 0, count: anchor.vertexCount)
            var positions: [Float] = []
            var normals: [Float] = []
            for vertex in 0..<anchor.vertexCount where used[vertex] {
                remap[vertex] = UInt32(positions.count / 3)
                let offset = vertex * 3
                positions.append(anchor.positions[offset])
                positions.append(anchor.positions[offset + 1])
                positions.append(anchor.positions[offset + 2])
                normals.append(anchor.normals[offset])
                normals.append(anchor.normals[offset + 1])
                normals.append(anchor.normals[offset + 2])
            }

            var indices: [UInt32] = []
            var classifications: [UInt8] = []
            indices.reserveCapacity(keptFaces.count * 3)
            classifications.reserveCapacity(keptFaces.count)
            for face in keptFaces {
                indices.append(remap[Int(anchor.indices[face * 3])])
                indices.append(remap[Int(anchor.indices[face * 3 + 1])])
                indices.append(remap[Int(anchor.indices[face * 3 + 2])])
                classifications.append(anchor.classifications[face])
            }

            if !classifications.isEmpty {
                result.append(MeshAnchorData(id: anchor.id,
                                             transform: anchor.transform,
                                             positions: positions,
                                             normals: normals,
                                             indices: indices,
                                             classifications: classifications))
            }
        }
        return result
    }

    /// Soma de faces de uma lista de blocos.
    public static func faceCount(_ anchors: [MeshAnchorData]) -> Int {
        var total = 0
        for anchor in anchors {
            total += anchor.faceCount
        }
        return total
    }

    public static func vertexCount(_ anchors: [MeshAnchorData]) -> Int {
        var total = 0
        for anchor in anchors {
            total += anchor.vertexCount
        }
        return total
    }
}

public enum MeasurementKind: String, Codable {
    /// Distância entre dois pontos.
    case distance
    /// Área de um polígono no piso.
    case area
}

/// Uma medida feita no visualizador (marco M9). Os pontos estão no mundo do scan (Y-up).
public struct MeasurementRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: MeasurementKind
    public var points: [SIMD3<Float>]

    public init(id: UUID = UUID(), name: String, kind: MeasurementKind, points: [SIMD3<Float>]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.points = points
    }

    /// Metros para distância, metros quadrados para área.
    public var value: Float {
        switch kind {
        case .distance:
            return MeasureMath.pathLength(points)
        case .area:
            return MeasureMath.horizontalArea(points)
        }
    }

    public var unit: String {
        return kind == .distance ? "m" : "m²"
    }

    /// Valor com duas casas e vírgula, por exemplo "3,25 m".
    public var formattedValue: String {
        return "\(FloorPlanSVG.formatMeters(value)) \(unit)"
    }

    /// Ponto onde escrever o rótulo da medida na cena.
    public var labelPoint: SIMD3<Float> {
        if points.isEmpty {
            return SIMD3<Float>(0, 0, 0)
        }
        var sum = SIMD3<Float>(0, 0, 0)
        for point in points {
            sum += point
        }
        return sum / Float(points.count)
    }
}

/// Contas da medição. (O nome evita colidir com o `Measurement` do Foundation.)
public enum MeasureMath {
    /// Comprimento do caminho que passa pelos pontos, na ordem.
    public static func pathLength(_ points: [SIMD3<Float>]) -> Float {
        if points.count < 2 {
            return 0
        }
        var total: Float = 0
        for index in 1..<points.count {
            total += simd_distance(points[index - 1], points[index])
        }
        return total
    }

    /// Área do polígono projetado no plano do piso (ignora a altura dos pontos).
    /// É a medida que interessa para área de cômodo, mesmo que os toques tenham caído
    /// em alturas um pouco diferentes.
    public static func horizontalArea(_ points: [SIMD3<Float>]) -> Float {
        var flat: [SIMD2<Float>] = []
        flat.reserveCapacity(points.count)
        for point in points {
            flat.append(PlanGeometry.planPoint(point))
        }
        return PlanGeometry.polygonArea(flat)
    }

    /// Vértice da malha mais próximo de `point`, se houver algum a até `maxDistance`.
    /// É o "ímã" da medição: tocar perto de um vértice gruda nele, o que ajuda a pegar
    /// quinas, onde os vértices da malha se concentram.
    /// - Parameter positions: 3 floats por vértice.
    public static func nearestVertex(to point: SIMD3<Float>, positions: [Float], maxDistance: Float) -> SIMD3<Float>? {
        var best: SIMD3<Float>? = nil
        var bestSquared = maxDistance * maxDistance
        var offset = 0
        while offset + 2 < positions.count {
            let candidate = SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2])
            let squared = simd_distance_squared(candidate, point)
            if squared <= bestSquared {
                bestSquared = squared
                best = candidate
            }
            offset += 3
        }
        return best
    }

    private static func number(_ value: Float) -> String {
        return String(format: "%.3f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// CSV das medidas. Separador ponto e vírgula e vírgula decimal, que é o que o
    /// Excel em português abre direto.
    public static func csv(_ records: [MeasurementRecord]) -> String {
        var lines: [String] = []
        lines.append("nome;tipo;valor;unidade;pontos (x y z em metros)")
        for record in records {
            var points: [String] = []
            for point in record.points {
                points.append("\(number(point.x)) \(number(point.y)) \(number(point.z))")
            }
            let kind = record.kind == .distance ? "distância" : "área"
            // O ponto e vírgula separa colunas: se aparecer no nome, vira vírgula.
            let name = record.name.replacingOccurrences(of: ";", with: ",")
            lines.append("\(name);\(kind);\(FloorPlanSVG.formatMeters(record.value));\(record.unit);\(points.joined(separator: " | "))")
        }
        lines.append("aviso;;;;Medidas aproximadas (LiDAR). Confira com a trena.")
        return lines.joined(separator: "\n") + "\n"
    }
}
