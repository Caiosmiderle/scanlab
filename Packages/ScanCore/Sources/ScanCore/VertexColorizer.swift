import Foundation
import simd

/// Imagem RGBA de 8 bits por canal, linha a linha a partir do topo.
public struct RGBAImage {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    /// Devolve `nil` se o vetor não tiver exatamente `width * height * 4` bytes.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * 4 else {
            return nil
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Para uso interno, quando o tamanho do vetor já é garantido por construção.
    /// Se os números não baterem, cai numa imagem cinza de 1 x 1 em vez de falhar.
    init(trustedWidth width: Int, height: Int, pixels: [UInt8]) {
        if width > 0 && height > 0 && pixels.count == width * height * 4 {
            self.width = width
            self.height = height
            self.pixels = pixels
        } else {
            self.width = 1
            self.height = 1
            self.pixels = [128, 128, 128, 255]
        }
    }

    /// Cor em (x, y), em pixels desta imagem, com interpolação bilinear.
    /// Coordenadas fora da imagem são trazidas para a borda.
    public func sample(x: Float, y: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        // Centro do pixel (0,0) fica em (0.5, 0.5).
        let fx = max(0, min(Float(width - 1), x - 0.5))
        let fy = max(0, min(Float(height - 1), y - 0.5))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        var result: [Float] = [0, 0, 0]
        for channel in 0..<3 {
            let p00 = Float(pixels[(y0 * width + x0) * 4 + channel])
            let p10 = Float(pixels[(y0 * width + x1) * 4 + channel])
            let p01 = Float(pixels[(y1 * width + x0) * 4 + channel])
            let p11 = Float(pixels[(y1 * width + x1) * 4 + channel])
            let top = p00 + (p10 - p00) * tx
            let bottom = p01 + (p11 - p01) * tx
            result[channel] = top + (bottom - top) * ty
        }
        return (VertexColorizer.byte(result[0]), VertexColorizer.byte(result[1]), VertexColorizer.byte(result[2]))
    }
}

public struct ColorizeOptions: Equatable {
    /// Distância mínima e máxima (m) entre a câmera e o vértice.
    public var minDepth: Float
    public var maxDepth: Float
    /// Cosseno mínimo entre a normal do vértice e a direção até a câmera.
    /// Valores pequenos são superfícies vistas quase de lado, onde a cor "escorre".
    public var minCosine: Float
    /// Faixa junto à borda da imagem (fração do lado) que não é usada.
    public var borderFraction: Float
    /// Cor dos vértices que nenhum keyframe viu.
    public var fallbackGray: UInt8
    /// Passadas de preenchimento de vértices sem cor a partir dos vizinhos.
    public var fillIterations: Int

    /// Oclusão (M2B): o vértice é considerado escondido se estiver mais longe que a
    /// superfície medida pelo LiDAR naquele pixel, além desta tolerância:
    /// `occlusionBaseTolerance + occlusionRelativeTolerance * profundidade` (metros).
    public var occlusionBaseTolerance: Float
    public var occlusionRelativeTolerance: Float
    /// Confiança mínima do pixel de profundidade para ele valer no teste (0, 1 ou 2).
    public var minDepthConfidence: UInt8
    /// Multiplicador da nota quando não há medida de profundidade confiável no pixel:
    /// o keyframe ainda pode ser usado, mas perde para um que confirmou a visibilidade.
    public var unknownDepthPenalty: Float

    /// Quantos keyframes entram na mistura de cor de cada vértice.
    public var blendCount: Int
    /// Um keyframe só entra na mistura se a nota dele for pelo menos esta fração da melhor.
    public var blendMinRelativeScore: Float

    public init(minDepth: Float = 0.15,
                maxDepth: Float = 6.0,
                minCosine: Float = 0.2,
                borderFraction: Float = 0.03,
                fallbackGray: UInt8 = 128,
                fillIterations: Int = 6,
                occlusionBaseTolerance: Float = 0.05,
                occlusionRelativeTolerance: Float = 0.03,
                minDepthConfidence: UInt8 = 1,
                unknownDepthPenalty: Float = 0.5,
                blendCount: Int = 3,
                blendMinRelativeScore: Float = 0.6) {
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.minCosine = minCosine
        self.borderFraction = borderFraction
        self.fallbackGray = fallbackGray
        self.fillIterations = fillIterations
        self.occlusionBaseTolerance = occlusionBaseTolerance
        self.occlusionRelativeTolerance = occlusionRelativeTolerance
        self.minDepthConfidence = minDepthConfidence
        self.unknownDepthPenalty = unknownDepthPenalty
        self.blendCount = blendCount
        self.blendMinRelativeScore = blendMinRelativeScore
    }
}

public struct ColorizeReport: Equatable {
    /// Vértices que receberam cor direto de keyframes.
    public var coloredDirectly: Int
    /// Vértices sem keyframe que herdaram a média dos vizinhos.
    public var filledFromNeighbors: Int
    /// Vértices que ficaram com o cinza padrão.
    public var uncolored: Int
    /// Quantos keyframes foram de fato usados.
    public var framesUsed: Int
}

/// Para cada vértice, até `slots` keyframes escolhidos e o peso de cada um.
public struct KeyframeAssignment: Equatable {
    public let slots: Int
    /// `vertexCount * slots` índices de câmera, do melhor para o pior; -1 = vazio.
    public var cameras: [Int32]
    /// Peso de cada escolha na mistura (0 onde a câmera é -1).
    public var weights: [Float]

    /// O melhor keyframe de cada vértice (-1 se nenhum serve).
    public var bestCameras: [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(cameras.count / max(1, slots))
        var index = 0
        while index < cameras.count {
            result.append(cameras[index])
            index += slots
        }
        return result
    }
}

/// Cor por vértice a partir dos keyframes (marco M2).
///
/// Cada keyframe recebe uma nota para cada vértice. A nota é alta quando a câmera vê a
/// superfície de frente (normal apontando para a câmera), de perto e longe da borda da
/// imagem. Com mapa de profundidade (M2B), um keyframe é descartado se o LiDAR mediu,
/// naquele pixel, uma superfície MAIS PRÓXIMA que o vértice: há algo na frente (um
/// móvel, uma parede) e a cor ali não é a do vértice. A cor final é a média ponderada
/// dos melhores keyframes, o que suaviza diferenças de exposição entre fotos.
///
/// A malha precisa estar no mundo do ARKit (Y-up), onde as poses foram gravadas.
public enum VertexColorizer {

    static func byte(_ value: Float) -> UInt8 {
        return UInt8(max(0, min(255, value.rounded())))
    }

    /// Nota de um keyframe para um vértice. `nil` se o keyframe não serve.
    static func score(camera: CameraModel,
                      depthMap: DepthMap?,
                      point: SIMD3<Float>,
                      normal: SIMD3<Float>,
                      options: ColorizeOptions) -> Float? {
        let toCamera = camera.position - point
        let distance = simd_length(toCamera)
        if !(distance > options.minDepth && distance < options.maxDepth) {
            return nil
        }
        let cosine = simd_dot(normal, toCamera) / distance
        if !(cosine > options.minCosine) {
            return nil
        }
        guard let projected = camera.project(point) else {
            return nil
        }
        if projected.depth < options.minDepth {
            return nil
        }
        // Distância até a borda mais próxima, como fração do lado da imagem.
        let borderX = min(projected.u, camera.width - projected.u) / camera.width
        let borderY = min(projected.v, camera.height - projected.v) / camera.height
        let border = min(borderX, borderY)
        if border < options.borderFraction {
            return nil
        }

        var occlusionWeight: Float = 1
        if let depthMap = depthMap {
            let measured = depthMap.nearestSurface(columnFraction: projected.u / camera.width,
                                                   rowFraction: projected.v / camera.height,
                                                   minConfidence: options.minDepthConfidence)
            if let measured = measured {
                let tolerance = options.occlusionBaseTolerance + options.occlusionRelativeTolerance * projected.depth
                if projected.depth > measured + tolerance {
                    // O LiDAR viu algo mais perto neste pixel: o vértice está escondido.
                    return nil
                }
            } else {
                occlusionWeight = options.unknownDepthPenalty
            }
        }

        // Peso que cresce da borda até 15% para dentro: o centro da lente distorce menos.
        let centerWeight = min(1, border / 0.15)
        let distanceWeight = 1 / (1 + projected.depth)
        return cosine * centerWeight * distanceWeight * occlusionWeight
    }

    /// Escolhe os melhores keyframes de cada vértice.
    /// - Parameter depthMaps: um mapa por câmera (mesmo índice), ou vazio para não testar oclusão.
    public static func assignKeyframes(mesh: WorldMesh,
                                       cameras: [CameraModel],
                                       depthMaps: [DepthMap?] = [],
                                       options: ColorizeOptions = ColorizeOptions(),
                                       progress: ((Double) -> Void)? = nil) -> KeyframeAssignment {
        let vertexCount = mesh.vertexCount
        let slots = max(1, options.blendCount)
        var assignment = KeyframeAssignment(slots: slots,
                                            cameras: [Int32](repeating: -1, count: vertexCount * slots),
                                            weights: [Float](repeating: 0, count: vertexCount * slots))
        if cameras.isEmpty {
            return assignment
        }
        let useDepth = depthMaps.count == cameras.count
        let reportEvery = max(1, vertexCount / 50)

        var topScores = [Float](repeating: 0, count: slots)
        var topCameras = [Int32](repeating: -1, count: slots)

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            let point = SIMD3<Float>(mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
            let normal = SIMD3<Float>(mesh.normals[offset], mesh.normals[offset + 1], mesh.normals[offset + 2])

            for slot in 0..<slots {
                topScores[slot] = 0
                topCameras[slot] = -1
            }

            for cameraIndex in 0..<cameras.count {
                let depthMap: DepthMap? = useDepth ? depthMaps[cameraIndex] : nil
                guard let value = score(camera: cameras[cameraIndex], depthMap: depthMap, point: point, normal: normal, options: options) else {
                    continue
                }
                // Inserção ordenada na lista dos melhores (lista minúscula: 1 a 3 itens).
                var position = slots
                while position > 0 && value > topScores[position - 1] {
                    position -= 1
                }
                if position < slots {
                    var slot = slots - 1
                    while slot > position {
                        topScores[slot] = topScores[slot - 1]
                        topCameras[slot] = topCameras[slot - 1]
                        slot -= 1
                    }
                    topScores[position] = value
                    topCameras[position] = Int32(cameraIndex)
                }
            }

            let best = topScores[0]
            if topCameras[0] >= 0 && best > 0 {
                for slot in 0..<slots {
                    if topCameras[slot] < 0 {
                        break
                    }
                    if topScores[slot] < best * options.blendMinRelativeScore {
                        break
                    }
                    assignment.cameras[vertex * slots + slot] = topCameras[slot]
                    // Nota ao quadrado: o melhor keyframe domina, os outros só suavizam.
                    assignment.weights[vertex * slots + slot] = topScores[slot] * topScores[slot]
                }
            }

            if vertex % reportEvery == 0 {
                progress?(Double(vertex) / Double(vertexCount))
            }
        }
        progress?(1.0)
        return assignment
    }

    /// Colore a malha no lugar.
    /// - Parameter depthMaps: um mapa de profundidade por câmera, ou vazio para não testar oclusão.
    /// - Parameter imageProvider: recebe o índice da câmera e devolve a imagem decodificada
    ///   (pode ser em resolução menor que a original; a escala é compensada aqui). É chamado
    ///   uma vez por keyframe usado, em ordem, para que só uma imagem fique na memória por vez.
    @discardableResult
    public static func colorize(mesh: inout WorldMesh,
                                cameras: [CameraModel],
                                depthMaps: [DepthMap?] = [],
                                options: ColorizeOptions = ColorizeOptions(),
                                imageProvider: (Int) -> RGBAImage?,
                                progress: ((Double) -> Void)? = nil) -> ColorizeReport {
        let vertexCount = mesh.vertexCount

        // Etapa 1 (60% do progresso): escolher os keyframes de cada vértice.
        let assignment = assignKeyframes(mesh: mesh, cameras: cameras, depthMaps: depthMaps, options: options) { fraction in
            progress?(0.6 * fraction)
        }
        let slots = assignment.slots

        // Agrupa por keyframe para decodificar cada imagem uma única vez.
        var verticesByCamera = [[Int32]](repeating: [], count: cameras.count)
        var weightsByCamera = [[Float]](repeating: [], count: cameras.count)
        for vertex in 0..<vertexCount {
            for slot in 0..<slots {
                let camera = assignment.cameras[vertex * slots + slot]
                if camera < 0 {
                    break
                }
                verticesByCamera[Int(camera)].append(Int32(vertex))
                weightsByCamera[Int(camera)].append(assignment.weights[vertex * slots + slot])
            }
        }

        var sums = [Float](repeating: 0, count: vertexCount * 3)
        var weightSums = [Float](repeating: 0, count: vertexCount)
        var framesUsed = 0

        // Etapa 2 (35%): amostrar as cores, um keyframe por vez.
        for cameraIndex in 0..<cameras.count {
            let vertices = verticesByCamera[cameraIndex]
            if vertices.isEmpty {
                continue
            }
            guard let image = imageProvider(cameraIndex) else {
                continue
            }
            framesUsed += 1
            let camera = cameras[cameraIndex]
            let scaleX = Float(image.width) / camera.width
            let scaleY = Float(image.height) / camera.height
            let weights = weightsByCamera[cameraIndex]

            for item in 0..<vertices.count {
                let vertex = Int(vertices[item])
                let offset = vertex * 3
                let point = SIMD3<Float>(mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
                guard let projected = camera.project(point) else {
                    continue
                }
                let color = image.sample(x: projected.u * scaleX, y: projected.v * scaleY)
                let weight = weights[item]
                sums[offset] += Float(color.r) * weight
                sums[offset + 1] += Float(color.g) * weight
                sums[offset + 2] += Float(color.b) * weight
                weightSums[vertex] += weight
            }
            progress?(0.6 + 0.35 * Double(cameraIndex + 1) / Double(cameras.count))
        }

        var colors = [UInt8](repeating: options.fallbackGray, count: vertexCount * 3)
        var hasColor = [Bool](repeating: false, count: vertexCount)
        var coloredDirectly = 0
        for vertex in 0..<vertexCount where weightSums[vertex] > 0 {
            let offset = vertex * 3
            colors[offset] = byte(sums[offset] / weightSums[vertex])
            colors[offset + 1] = byte(sums[offset + 1] / weightSums[vertex])
            colors[offset + 2] = byte(sums[offset + 2] / weightSums[vertex])
            hasColor[vertex] = true
            coloredDirectly += 1
        }

        // Etapa 3 (5%): vértices sem cor herdam a média dos vizinhos já coloridos.
        let filled = fillFromNeighbors(colors: &colors, hasColor: &hasColor, indices: mesh.indices, iterations: options.fillIterations)

        mesh.colors = colors
        progress?(1.0)
        return ColorizeReport(coloredDirectly: coloredDirectly,
                              filledFromNeighbors: filled,
                              uncolored: vertexCount - coloredDirectly - filled,
                              framesUsed: framesUsed)
    }

    /// Espalha cor para vértices sem cor a partir dos vizinhos (vértices da mesma face).
    /// Cada passada avança um "anel" de vizinhança. Devolve quantos vértices foram preenchidos.
    static func fillFromNeighbors(colors: inout [UInt8], hasColor: inout [Bool], indices: [UInt32], iterations: Int) -> Int {
        let vertexCount = hasColor.count
        var filledTotal = 0

        for _ in 0..<max(0, iterations) {
            var sums = [Float](repeating: 0, count: vertexCount * 3)
            var counts = [Float](repeating: 0, count: vertexCount)

            var face = 0
            while face * 3 + 2 < indices.count {
                let a = Int(indices[face * 3])
                let b = Int(indices[face * 3 + 1])
                let c = Int(indices[face * 3 + 2])
                face += 1
                if a >= vertexCount || b >= vertexCount || c >= vertexCount {
                    continue
                }
                // Só interessam faces que misturam vértices com e sem cor.
                let coloredCorners = (hasColor[a] ? 1 : 0) + (hasColor[b] ? 1 : 0) + (hasColor[c] ? 1 : 0)
                if coloredCorners == 0 || coloredCorners == 3 {
                    continue
                }
                let corners = [a, b, c]
                for target in corners where !hasColor[target] {
                    for source in corners where hasColor[source] {
                        sums[target * 3] += Float(colors[source * 3])
                        sums[target * 3 + 1] += Float(colors[source * 3 + 1])
                        sums[target * 3 + 2] += Float(colors[source * 3 + 2])
                        counts[target] += 1
                    }
                }
            }

            // Aplica só no fim da passada, para o resultado não depender da ordem das faces.
            var filledNow = 0
            for vertex in 0..<vertexCount where counts[vertex] > 0 {
                colors[vertex * 3] = byte(sums[vertex * 3] / counts[vertex])
                colors[vertex * 3 + 1] = byte(sums[vertex * 3 + 1] / counts[vertex])
                colors[vertex * 3 + 2] = byte(sums[vertex * 3 + 2] / counts[vertex])
                hasColor[vertex] = true
                filledNow += 1
            }
            filledTotal += filledNow
            if filledNow == 0 {
                break
            }
        }
        return filledTotal
    }
}
