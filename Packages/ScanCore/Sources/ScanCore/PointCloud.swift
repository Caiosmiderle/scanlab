import Foundation
import simd

/// Nuvem de pontos pronta para exportar.
public struct PointCloud: Equatable {
    /// 3 floats por ponto.
    public var positions: [Float]
    /// 3 floats por ponto, ou vazio se a nuvem não tem normais.
    public var normals: [Float]
    /// 3 bytes por ponto (RGB), ou vazio se a nuvem não tem cor.
    public var colors: [UInt8]
    /// 1 byte por ponto (classificação do ARKit), ou vazio.
    public var classifications: [UInt8]

    public init(positions: [Float], normals: [Float] = [], colors: [UInt8] = [], classifications: [UInt8] = []) {
        self.positions = positions
        self.normals = normals
        self.colors = colors
        self.classifications = classifications
    }

    public var count: Int {
        return positions.count / 3
    }

    public var hasNormals: Bool {
        return !normals.isEmpty
    }

    public var hasColors: Bool {
        return !colors.isEmpty
    }

    public var hasClassifications: Bool {
        return !classifications.isEmpty
    }

    public var isConsistent: Bool {
        if positions.count % 3 != 0 {
            return false
        }
        if hasNormals && normals.count != positions.count {
            return false
        }
        if hasColors && colors.count != positions.count {
            return false
        }
        if hasClassifications && classifications.count != count {
            return false
        }
        return true
    }

    /// Troca a convenção de eixos no lugar. A nuvem entra em Y-up (ARKit).
    public mutating func applyAxis(_ axis: UpAxis) {
        if axis == .yUp {
            return
        }
        var offset = 0
        while offset + 2 < positions.count {
            let p = AxisConversion.yUpToZUp(SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2]))
            positions[offset] = p.x
            positions[offset + 1] = p.y
            positions[offset + 2] = p.z
            if hasNormals {
                let n = AxisConversion.yUpToZUp(SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2]))
                normals[offset] = n.x
                normals[offset + 1] = n.y
                normals[offset + 2] = n.z
            }
            offset += 3
        }
    }

    /// Mínimo e máximo de cada eixo. `nil` se a nuvem estiver vazia.
    public func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        if count == 0 {
            return nil
        }
        var lower = SIMD3<Float>(positions[0], positions[1], positions[2])
        var upper = lower
        var offset = 3
        while offset + 2 < positions.count {
            let p = SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2])
            lower = simd_min(lower, p)
            upper = simd_max(upper, p)
            offset += 3
        }
        return (lower, upper)
    }
}

/// Junta os pontos que caem na mesma célula de uma grade e devolve a média de cada célula.
/// É o "voxel downsample": limita a densidade e elimina pontos repetidos.
struct VoxelAccumulator {
    let cellSize: Float
    let keepNormals: Bool
    let keepColors: Bool
    let keepClassifications: Bool

    private var cellToSlot: [VoxelKey: Int32] = [:]
    private var positionSums: [Float] = []
    private var normalSums: [Float] = []
    private var colorSums: [Float] = []
    private var classifications: [UInt8] = []
    private var counts: [Float] = []

    init(cellSize: Float, keepNormals: Bool, keepColors: Bool, keepClassifications: Bool) {
        self.cellSize = cellSize
        self.keepNormals = keepNormals
        self.keepColors = keepColors
        self.keepClassifications = keepClassifications
    }

    mutating func add(point: SIMD3<Float>, normal: SIMD3<Float>, color: SIMD3<Float>, classification: UInt8) {
        if !(point.x.isFinite && point.y.isFinite && point.z.isFinite) {
            return
        }
        let key = VoxelKey(point, cellSize: cellSize)
        var slot: Int
        if let existing = cellToSlot[key] {
            slot = Int(existing)
        } else {
            slot = counts.count
            cellToSlot[key] = Int32(slot)
            counts.append(0)
            positionSums.append(contentsOf: [0, 0, 0])
            if keepNormals {
                normalSums.append(contentsOf: [0, 0, 0])
            }
            if keepColors {
                colorSums.append(contentsOf: [0, 0, 0])
            }
            if keepClassifications {
                // A classificação não tem "média": fica a do primeiro ponto da célula.
                classifications.append(classification)
            }
        }
        let offset = slot * 3
        counts[slot] += 1
        positionSums[offset] += point.x
        positionSums[offset + 1] += point.y
        positionSums[offset + 2] += point.z
        if keepNormals {
            normalSums[offset] += normal.x
            normalSums[offset + 1] += normal.y
            normalSums[offset + 2] += normal.z
        }
        if keepColors {
            colorSums[offset] += color.x
            colorSums[offset + 1] += color.y
            colorSums[offset + 2] += color.z
        }
    }

    func makeCloud() -> PointCloud {
        let total = counts.count
        var positions = [Float](repeating: 0, count: total * 3)
        var normals = [Float](repeating: 0, count: keepNormals ? total * 3 : 0)
        var colors = [UInt8](repeating: 0, count: keepColors ? total * 3 : 0)
        for slot in 0..<total {
            let offset = slot * 3
            let weight = counts[slot]
            positions[offset] = positionSums[offset] / weight
            positions[offset + 1] = positionSums[offset + 1] / weight
            positions[offset + 2] = positionSums[offset + 2] / weight
            if keepNormals {
                var normal = SIMD3<Float>(normalSums[offset], normalSums[offset + 1], normalSums[offset + 2])
                let length = simd_length(normal)
                if length.isFinite && length > 0 {
                    normal = normal / length
                }
                normals[offset] = normal.x
                normals[offset + 1] = normal.y
                normals[offset + 2] = normal.z
            }
            if keepColors {
                colors[offset] = VertexColorizer.byte(colorSums[offset] / weight)
                colors[offset + 1] = VertexColorizer.byte(colorSums[offset + 1] / weight)
                colors[offset + 2] = VertexColorizer.byte(colorSums[offset + 2] / weight)
            }
        }
        return PointCloud(positions: positions,
                          normals: normals,
                          colors: colors,
                          classifications: keepClassifications ? classifications : [])
    }
}

public enum PointCloudBuilder {
    /// Um ponto por vértice da malha. É a nuvem mais leve: a densidade é a da malha.
    public static func fromVertices(_ mesh: WorldMesh) -> PointCloud {
        return PointCloud(positions: mesh.positions,
                          normals: mesh.normals,
                          colors: mesh.colors ?? [],
                          classifications: [])
    }

    /// Nuvem densa: espalha pontos sobre a superfície de cada triângulo, com
    /// espaçamento aproximado `spacing` (metros), e junta os repetidos numa grade de
    /// mesmo tamanho. Cada ponto herda a normal e a cor interpoladas dos três cantos
    /// e a classificação da face.
    public static func sampleSurface(_ mesh: WorldMesh, spacing: Float, progress: ((Double) -> Void)? = nil) -> PointCloud {
        let faceCount = mesh.faceCount
        let colors = mesh.colors
        var accumulator = VoxelAccumulator(cellSize: max(spacing, 0.0005),
                                           keepNormals: true,
                                           keepColors: colors != nil,
                                           keepClassifications: true)
        let reportEvery = max(1, faceCount / 50)

        for face in 0..<faceCount {
            let ia = Int(mesh.indices[face * 3]) * 3
            let ib = Int(mesh.indices[face * 3 + 1]) * 3
            let ic = Int(mesh.indices[face * 3 + 2]) * 3
            let pa = SIMD3<Float>(mesh.positions[ia], mesh.positions[ia + 1], mesh.positions[ia + 2])
            let pb = SIMD3<Float>(mesh.positions[ib], mesh.positions[ib + 1], mesh.positions[ib + 2])
            let pc = SIMD3<Float>(mesh.positions[ic], mesh.positions[ic + 1], mesh.positions[ic + 2])
            let na = SIMD3<Float>(mesh.normals[ia], mesh.normals[ia + 1], mesh.normals[ia + 2])
            let nb = SIMD3<Float>(mesh.normals[ib], mesh.normals[ib + 1], mesh.normals[ib + 2])
            let nc = SIMD3<Float>(mesh.normals[ic], mesh.normals[ic + 1], mesh.normals[ic + 2])
            var ca = SIMD3<Float>(0, 0, 0)
            var cb = SIMD3<Float>(0, 0, 0)
            var cc = SIMD3<Float>(0, 0, 0)
            if let colors = colors {
                ca = SIMD3<Float>(Float(colors[ia]), Float(colors[ia + 1]), Float(colors[ia + 2]))
                cb = SIMD3<Float>(Float(colors[ib]), Float(colors[ib + 1]), Float(colors[ib + 2]))
                cc = SIMD3<Float>(Float(colors[ic]), Float(colors[ic + 1]), Float(colors[ic + 2]))
            }
            let classification = mesh.classifications[face]

            // Divide cada lado em `steps` partes: uma grade triangular regular.
            let longest = max(simd_distance(pa, pb), max(simd_distance(pb, pc), simd_distance(pa, pc)))
            var steps = 1
            if longest.isFinite && spacing > 0 {
                steps = min(64, max(1, Int((longest / spacing).rounded(.up))))
            }
            for i in 0...steps {
                for j in 0...(steps - i) {
                    let u = Float(i) / Float(steps)
                    let v = Float(j) / Float(steps)
                    let w = 1 - u - v
                    accumulator.add(point: pa * w + pb * u + pc * v,
                                    normal: na * w + nb * u + nc * v,
                                    color: ca * w + cb * u + cc * v,
                                    classification: classification)
                }
            }

            if face % reportEvery == 0 {
                progress?(Double(face) / Double(max(1, faceCount)))
            }
        }
        progress?(1.0)
        return accumulator.makeCloud()
    }

    /// Reduz uma nuvem existente: um ponto (a média) por célula de `voxelSize` metros.
    public static func voxelDownsample(_ cloud: PointCloud, voxelSize: Float) -> PointCloud {
        if !(voxelSize > 0) || cloud.count == 0 {
            return cloud
        }
        var accumulator = VoxelAccumulator(cellSize: voxelSize,
                                           keepNormals: cloud.hasNormals,
                                           keepColors: cloud.hasColors,
                                           keepClassifications: cloud.hasClassifications)
        for point in 0..<cloud.count {
            let offset = point * 3
            let position = SIMD3<Float>(cloud.positions[offset], cloud.positions[offset + 1], cloud.positions[offset + 2])
            var normal = SIMD3<Float>(0, 0, 0)
            if cloud.hasNormals {
                normal = SIMD3<Float>(cloud.normals[offset], cloud.normals[offset + 1], cloud.normals[offset + 2])
            }
            var color = SIMD3<Float>(0, 0, 0)
            if cloud.hasColors {
                color = SIMD3<Float>(Float(cloud.colors[offset]), Float(cloud.colors[offset + 1]), Float(cloud.colors[offset + 2]))
            }
            let classification: UInt8 = cloud.hasClassifications ? cloud.classifications[point] : 0
            accumulator.add(point: position, normal: normal, color: color, classification: classification)
        }
        return accumulator.makeCloud()
    }
}
