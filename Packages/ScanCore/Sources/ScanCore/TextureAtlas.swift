import Foundation
import simd

/// Malha com coordenadas de textura (um par UV por vértice).
///
/// Diferente da `WorldMesh`, aqui um ponto da superfície pode aparecer mais de uma
/// vez: se dois triângulos vizinhos usam fotos diferentes, o vértice que eles
/// compartilham precisa de um UV para cada foto, então ele é duplicado.
public struct TexturedMesh: Equatable {
    /// 3 floats por vértice.
    public var positions: [Float]
    /// 3 floats por vértice.
    public var normals: [Float]
    /// 2 floats por vértice, de 0 a 1, com a origem no canto SUPERIOR esquerdo da
    /// imagem (a convenção do glTF). O OBJ usa a origem embaixo: o escritor inverte o V.
    public var uvs: [Float]
    /// 3 índices por face.
    public var indices: [UInt32]

    public init(positions: [Float], normals: [Float], uvs: [Float], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
    }

    public var vertexCount: Int {
        return positions.count / 3
    }

    public var faceCount: Int {
        return indices.count / 3
    }

    public var isConsistent: Bool {
        if positions.count % 3 != 0 || indices.count % 3 != 0 {
            return false
        }
        return normals.count == positions.count && uvs.count == vertexCount * 2
    }

    /// Troca a convenção de eixos no lugar. A malha entra em Y-up (ARKit).
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
            let n = AxisConversion.yUpToZUp(SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2]))
            normals[offset] = n.x
            normals[offset + 1] = n.y
            normals[offset + 2] = n.z
            offset += 3
        }
    }

    public func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        if vertexCount == 0 {
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

public struct TextureAtlasOptions: Equatable {
    /// Lado do atlas em pixels (4096 no perfil Rápido, 8192 no HD).
    public var atlasSize: Int
    /// Margem em volta de cada recorte, em pixels do atlas. Os pixels da margem repetem
    /// a imagem vizinha, para a costura entre recortes não aparecer preta.
    public var padding: Int
    /// Regras de escolha da foto (as mesmas da cor por vértice).
    public var selection: ColorizeOptions
    /// Cor dos triângulos que nenhuma foto viu.
    public var fallbackGray: UInt8

    public init(atlasSize: Int = 4096, padding: Int = 3, selection: ColorizeOptions = ColorizeOptions(), fallbackGray: UInt8 = 128) {
        self.atlasSize = atlasSize
        self.padding = padding
        self.selection = selection
        self.fallbackGray = fallbackGray
    }
}

public struct TextureAtlasReport: Equatable {
    /// Quantos recortes (charts) entraram no atlas.
    public var chartCount: Int
    public var texturedFaces: Int
    /// Triângulos que nenhuma foto viu (ficam cinza).
    public var untexturedFaces: Int
    public var camerasUsed: Int
    /// Escala aplicada às fotos para caber no atlas (1 = resolução original).
    public var scale: Float
}

public struct TextureAtlasResult {
    public var mesh: TexturedMesh
    /// Imagem do atlas, quadrada, RGBA.
    public var atlas: RGBAImage
    public var report: TextureAtlasReport
}

/// Empacotamento em prateleiras: os retângulos são colocados da esquerda para a direita
/// em fileiras, do mais alto para o mais baixo. Simples e suficiente para recortes de
/// tamanhos parecidos.
public enum ShelfPacker {
    /// - Returns: o canto superior esquerdo de cada retângulo, na ordem de entrada, ou
    ///   `nil` se eles não couberem num quadrado de lado `atlasSize`.
    public static func pack(sizes: [(width: Int, height: Int)], atlasSize: Int) -> [(x: Int, y: Int)]? {
        var order = Array(0..<sizes.count)
        order.sort { sizes[$0].height > sizes[$1].height }

        var positions = [(x: Int, y: Int)](repeating: (0, 0), count: sizes.count)
        var cursorX = 0
        var cursorY = 0
        var shelfHeight = 0
        for index in order {
            let size = sizes[index]
            if size.width > atlasSize || size.height > atlasSize {
                return nil
            }
            if cursorX + size.width > atlasSize {
                // Não cabe nesta prateleira: abre a próxima.
                cursorY += shelfHeight
                cursorX = 0
                shelfHeight = 0
            }
            if cursorY + size.height > atlasSize {
                return nil
            }
            positions[index] = (cursorX, cursorY)
            cursorX += size.width
            shelfHeight = max(shelfHeight, size.height)
        }
        return positions
    }
}

/// Atlas de textura (marco M7).
///
/// 1. Para cada triângulo, escolhe a melhor foto (mesma nota da cor por vértice,
///    incluindo o teste de oclusão).
/// 2. Triângulos vizinhos que usam a mesma foto formam um recorte ("chart").
/// 3. O retângulo que cobre o recorte na foto é copiado para o atlas, reduzido por uma
///    escala única escolhida para tudo caber.
/// 4. Cada vértice recebe o UV correspondente à sua posição dentro do recorte.
///
/// Sem mistura entre fotos nesta versão: onde dois recortes de fotos diferentes se
/// encontram pode aparecer uma diferença de tom.
public enum TextureAtlasBuilder {
    /// Lado, em pixels, do bloco cinza reservado para os triângulos sem foto.
    static let fallbackBlock = 8

    struct Chart {
        var camera: Int
        var faces: [Int32]
        /// Retângulo na foto original, em pixels.
        var minU: Float
        var minV: Float
        var maxU: Float
        var maxV: Float
        /// Canto do recorte no atlas (já contando a margem) e tamanho sem a margem.
        var atlasX: Int = 0
        var atlasY: Int = 0
        var width: Int = 0
        var height: Int = 0
    }

    private static func point(_ mesh: WorldMesh, _ vertex: Int) -> SIMD3<Float> {
        return SIMD3<Float>(mesh.positions[vertex * 3], mesh.positions[vertex * 3 + 1], mesh.positions[vertex * 3 + 2])
    }

    private static func normal(_ mesh: WorldMesh, _ vertex: Int) -> SIMD3<Float> {
        return SIMD3<Float>(mesh.normals[vertex * 3], mesh.normals[vertex * 3 + 1], mesh.normals[vertex * 3 + 2])
    }

    /// Melhor foto de cada face (-1 se nenhuma serve). A face só aceita uma foto em que
    /// os três cantos caem dentro da imagem.
    static func assignFaces(mesh: WorldMesh,
                            cameras: [CameraModel],
                            depthMaps: [DepthMap?],
                            options: ColorizeOptions,
                            progress: ((Double) -> Void)?) -> [Int32] {
        let faceCount = mesh.faceCount
        var assignment = [Int32](repeating: -1, count: faceCount)
        if cameras.isEmpty {
            return assignment
        }
        let useDepth = depthMaps.count == cameras.count
        let reportEvery = max(1, faceCount / 50)

        for face in 0..<faceCount {
            let ia = Int(mesh.indices[face * 3])
            let ib = Int(mesh.indices[face * 3 + 1])
            let ic = Int(mesh.indices[face * 3 + 2])
            let a = point(mesh, ia)
            let b = point(mesh, ib)
            let c = point(mesh, ic)
            let center = (a + b + c) / 3
            var faceNormal = normal(mesh, ia) + normal(mesh, ib) + normal(mesh, ic)
            let length = simd_length(faceNormal)
            if !(length.isFinite && length > 0) {
                continue
            }
            faceNormal = faceNormal / length

            var bestScore: Float = 0
            var bestCamera: Int32 = -1
            for cameraIndex in 0..<cameras.count {
                let camera = cameras[cameraIndex]
                let depthMap: DepthMap? = useDepth ? depthMaps[cameraIndex] : nil
                guard let value = VertexColorizer.score(camera: camera, depthMap: depthMap, point: center, normal: faceNormal, options: options),
                      value > bestScore else {
                    continue
                }
                // Só vale se o triângulo inteiro aparece na foto.
                if camera.project(a) == nil || camera.project(b) == nil || camera.project(c) == nil {
                    continue
                }
                bestScore = value
                bestCamera = Int32(cameraIndex)
            }
            assignment[face] = bestCamera

            if face % reportEvery == 0 {
                progress?(Double(face) / Double(faceCount))
            }
        }
        progress?(1.0)
        return assignment
    }

    /// Agrupa em recortes as faces vizinhas (que compartilham vértice) com a mesma foto.
    static func buildCharts(mesh: WorldMesh, cameras: [CameraModel], faceCamera: [Int32]) -> [Chart] {
        let faceCount = mesh.faceCount
        let vertexCount = mesh.vertexCount

        // Faces de cada câmera.
        var facesByCamera = [[Int32]](repeating: [], count: cameras.count)
        for face in 0..<faceCount where faceCamera[face] >= 0 {
            facesByCamera[Int(faceCamera[face])].append(Int32(face))
        }

        // Union-find sobre as faces.
        var parent = [Int32](repeating: 0, count: faceCount)
        for face in 0..<faceCount {
            parent[face] = Int32(face)
        }
        func find(_ start: Int) -> Int {
            var root = start
            while Int(parent[root]) != root {
                root = Int(parent[root])
            }
            var node = start
            while Int(parent[node]) != node {
                let next = Int(parent[node])
                parent[node] = Int32(root)
                node = next
            }
            return root
        }

        // Para cada vértice, a última face (desta câmera) que o usou. O carimbo evita
        // ter de zerar os vetores a cada câmera.
        var stamp = [Int32](repeating: -1, count: vertexCount)
        var owner = [Int32](repeating: 0, count: vertexCount)
        for cameraIndex in 0..<cameras.count {
            for faceValue in facesByCamera[cameraIndex] {
                let face = Int(faceValue)
                for corner in 0..<3 {
                    let vertex = Int(mesh.indices[face * 3 + corner])
                    if stamp[vertex] == Int32(cameraIndex) {
                        let rootA = find(face)
                        let rootB = find(Int(owner[vertex]))
                        if rootA != rootB {
                            parent[rootB] = Int32(rootA)
                        }
                    } else {
                        stamp[vertex] = Int32(cameraIndex)
                        owner[vertex] = Int32(face)
                    }
                }
            }
        }

        // Um recorte por raiz.
        var chartOfRoot: [Int: Int] = [:]
        var charts: [Chart] = []
        for cameraIndex in 0..<cameras.count {
            let camera = cameras[cameraIndex]
            for faceValue in facesByCamera[cameraIndex] {
                let face = Int(faceValue)
                let root = find(face)
                var chartIndex: Int
                if let existing = chartOfRoot[root] {
                    chartIndex = existing
                } else {
                    chartIndex = charts.count
                    chartOfRoot[root] = chartIndex
                    charts.append(Chart(camera: cameraIndex,
                                        faces: [],
                                        minU: Float.greatestFiniteMagnitude,
                                        minV: Float.greatestFiniteMagnitude,
                                        maxU: -Float.greatestFiniteMagnitude,
                                        maxV: -Float.greatestFiniteMagnitude))
                }
                charts[chartIndex].faces.append(faceValue)
                for corner in 0..<3 {
                    let vertex = Int(mesh.indices[face * 3 + corner])
                    if let projected = camera.project(point(mesh, vertex)) {
                        charts[chartIndex].minU = min(charts[chartIndex].minU, projected.u)
                        charts[chartIndex].minV = min(charts[chartIndex].minV, projected.v)
                        charts[chartIndex].maxU = max(charts[chartIndex].maxU, projected.u)
                        charts[chartIndex].maxV = max(charts[chartIndex].maxV, projected.v)
                    }
                }
            }
        }

        // Fecha cada retângulo em pixels inteiros, com 1 pixel de folga, dentro da foto.
        for index in 0..<charts.count {
            let camera = cameras[charts[index].camera]
            charts[index].minU = max(0, charts[index].minU.rounded(.down) - 1)
            charts[index].minV = max(0, charts[index].minV.rounded(.down) - 1)
            charts[index].maxU = min(camera.width, charts[index].maxU.rounded(.up) + 1)
            charts[index].maxV = min(camera.height, charts[index].maxV.rounded(.up) + 1)
        }
        return charts
    }

    /// Resultado do posicionamento: a escala usada e onde ficou o bloco cinza.
    struct Layout {
        var scale: Float
        var fallbackX: Int
        var fallbackY: Int
    }

    /// Escolhe a escala e a posição de cada recorte no atlas.
    /// - Returns: `nil` se nem reduzindo muito os recortes couberam.
    static func layout(charts: inout [Chart], atlasSize: Int, padding: Int) -> Layout? {
        if charts.isEmpty {
            return Layout(scale: 1, fallbackX: 0, fallbackY: 0)
        }
        var sourceArea: Float = 0
        for chart in charts {
            sourceArea += (chart.maxU - chart.minU) * (chart.maxV - chart.minV)
        }
        // Começa pela escala que ocuparia cerca de 75% do atlas e vai reduzindo.
        let capacity = Float(atlasSize) * Float(atlasSize) * 0.75
        var scale: Float = 1
        if sourceArea > capacity {
            scale = (capacity / sourceArea).squareRoot()
        }

        for _ in 0..<40 {
            var sizes: [(width: Int, height: Int)] = []
            sizes.reserveCapacity(charts.count + 1)
            for index in 0..<charts.count {
                let width = max(1, Int(((charts[index].maxU - charts[index].minU) * scale).rounded(.up)))
                let height = max(1, Int(((charts[index].maxV - charts[index].minV) * scale).rounded(.up)))
                charts[index].width = width
                charts[index].height = height
                sizes.append((width + padding * 2, height + padding * 2))
            }
            // O último retângulo é o bloco cinza dos triângulos sem foto.
            sizes.append((fallbackBlock, fallbackBlock))

            if let positions = ShelfPacker.pack(sizes: sizes, atlasSize: atlasSize) {
                for index in 0..<charts.count {
                    charts[index].atlasX = positions[index].x + padding
                    charts[index].atlasY = positions[index].y + padding
                }
                return Layout(scale: scale, fallbackX: positions[charts.count].x, fallbackY: positions[charts.count].y)
            }
            scale *= 0.9
        }
        return nil
    }

    public static func build(mesh: WorldMesh,
                             cameras: [CameraModel],
                             depthMaps: [DepthMap?] = [],
                             options: TextureAtlasOptions = TextureAtlasOptions(),
                             imageProvider: (Int) -> RGBAImage?,
                             progress: ((Double) -> Void)? = nil) -> TextureAtlasResult {
        let atlasSize = max(16, options.atlasSize)
        let padding = max(0, options.padding)
        let faceCount = mesh.faceCount

        // 1. Foto de cada face (50% do progresso).
        var faceCamera = assignFaces(mesh: mesh, cameras: cameras, depthMaps: depthMaps, options: options.selection) { fraction in
            progress?(0.5 * fraction)
        }

        // 2. Recortes e posição no atlas.
        var charts = buildCharts(mesh: mesh, cameras: cameras, faceCamera: faceCamera)
        var blockOrigin: (x: Int, y: Int) = (0, 0)
        var scale: Float = 1
        if let placed = layout(charts: &charts, atlasSize: atlasSize, padding: padding) {
            scale = placed.scale
            blockOrigin = (placed.fallbackX, placed.fallbackY)
        } else {
            // Não coube de jeito nenhum: sai sem textura (tudo cinza).
            charts = []
            for face in 0..<faceCount {
                faceCamera[face] = -1
            }
        }
        progress?(0.55)

        // 3. Pinta o atlas, uma foto por vez (40% do progresso).
        var pixels = [UInt8](repeating: options.fallbackGray, count: atlasSize * atlasSize * 4)
        var alpha = 3
        while alpha < pixels.count {
            pixels[alpha] = 255
            alpha += 4
        }
        var chartsByCamera = [[Int]](repeating: [], count: cameras.count)
        for index in 0..<charts.count {
            chartsByCamera[charts[index].camera].append(index)
        }
        var camerasUsed = 0
        var failedCharts: Set<Int> = []
        for cameraIndex in 0..<cameras.count {
            if chartsByCamera[cameraIndex].isEmpty {
                continue
            }
            guard let image = imageProvider(cameraIndex) else {
                for chartIndex in chartsByCamera[cameraIndex] {
                    failedCharts.insert(chartIndex)
                }
                continue
            }
            camerasUsed += 1
            let camera = cameras[cameraIndex]
            let imageScaleX = Float(image.width) / camera.width
            let imageScaleY = Float(image.height) / camera.height

            for chartIndex in chartsByCamera[cameraIndex] {
                let chart = charts[chartIndex]
                // Pinta o retângulo inteiro mais a margem: a margem repete a foto vizinha.
                for row in (-padding)..<(chart.height + padding) {
                    let atlasY = chart.atlasY + row
                    if atlasY < 0 || atlasY >= atlasSize {
                        continue
                    }
                    let sourceV = min(camera.height, max(0, chart.minV + (Float(row) + 0.5) / scale))
                    for column in (-padding)..<(chart.width + padding) {
                        let atlasX = chart.atlasX + column
                        if atlasX < 0 || atlasX >= atlasSize {
                            continue
                        }
                        let sourceU = min(camera.width, max(0, chart.minU + (Float(column) + 0.5) / scale))
                        let color = image.sample(x: sourceU * imageScaleX, y: sourceV * imageScaleY)
                        let offset = (atlasY * atlasSize + atlasX) * 4
                        pixels[offset] = color.r
                        pixels[offset + 1] = color.g
                        pixels[offset + 2] = color.b
                    }
                }
            }
            progress?(0.55 + 0.40 * Double(cameraIndex + 1) / Double(cameras.count))
        }

        // 4. Malha com UV. Um vértice é duplicado para cada recorte em que aparece.
        let vertexCount = mesh.vertexCount
        var positions: [Float] = []
        var normals: [Float] = []
        var uvs: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(vertexCount * 3)
        normals.reserveCapacity(vertexCount * 3)
        uvs.reserveCapacity(vertexCount * 2)
        indices.reserveCapacity(faceCount * 3)

        var stamp = [Int32](repeating: -1, count: vertexCount)
        var newIndex = [UInt32](repeating: 0, count: vertexCount)
        let size = Float(atlasSize)
        var texturedFaces = 0
        var faceDone = [Bool](repeating: false, count: faceCount)

        func appendVertex(_ vertex: Int, u: Float, v: Float) -> UInt32 {
            let created = UInt32(positions.count / 3)
            positions.append(mesh.positions[vertex * 3])
            positions.append(mesh.positions[vertex * 3 + 1])
            positions.append(mesh.positions[vertex * 3 + 2])
            normals.append(mesh.normals[vertex * 3])
            normals.append(mesh.normals[vertex * 3 + 1])
            normals.append(mesh.normals[vertex * 3 + 2])
            uvs.append(u)
            uvs.append(v)
            return created
        }

        for chartIndex in 0..<charts.count where !failedCharts.contains(chartIndex) {
            let chart = charts[chartIndex]
            let camera = cameras[chart.camera]
            for faceValue in chart.faces {
                let face = Int(faceValue)
                for corner in 0..<3 {
                    let vertex = Int(mesh.indices[face * 3 + corner])
                    if stamp[vertex] != Int32(chartIndex) {
                        stamp[vertex] = Int32(chartIndex)
                        var atlasU = Float(chart.atlasX)
                        var atlasV = Float(chart.atlasY)
                        if let projected = camera.project(point(mesh, vertex)) {
                            atlasU += (projected.u - chart.minU) * scale
                            atlasV += (projected.v - chart.minV) * scale
                        }
                        newIndex[vertex] = appendVertex(vertex, u: atlasU / size, v: atlasV / size)
                    }
                    indices.append(newIndex[vertex])
                }
                faceDone[face] = true
                texturedFaces += 1
            }
        }

        // Faces sem foto: todas apontam para o centro do bloco cinza.
        let grayU = (Float(blockOrigin.x) + Float(fallbackBlock) / 2) / size
        let grayV = (Float(blockOrigin.y) + Float(fallbackBlock) / 2) / size
        let fallbackStamp = Int32(charts.count)
        for face in 0..<faceCount where !faceDone[face] {
            for corner in 0..<3 {
                let vertex = Int(mesh.indices[face * 3 + corner])
                if stamp[vertex] != fallbackStamp {
                    stamp[vertex] = fallbackStamp
                    newIndex[vertex] = appendVertex(vertex, u: grayU, v: grayV)
                }
                indices.append(newIndex[vertex])
            }
        }

        progress?(1.0)
        let textured = TexturedMesh(positions: positions, normals: normals, uvs: uvs, indices: indices)
        let report = TextureAtlasReport(chartCount: charts.count - failedCharts.count,
                                        texturedFaces: texturedFaces,
                                        untexturedFaces: faceCount - texturedFaces,
                                        camerasUsed: camerasUsed,
                                        scale: scale)
        let atlas = RGBAImage(trustedWidth: atlasSize, height: atlasSize, pixels: pixels)
        return TextureAtlasResult(mesh: textured, atlas: atlas, report: report)
    }
}
