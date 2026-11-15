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
        return (UInt8(max(0, min(255, result[0].rounded()))),
                UInt8(max(0, min(255, result[1].rounded()))),
                UInt8(max(0, min(255, result[2].rounded()))))
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

    public init(minDepth: Float = 0.15,
                maxDepth: Float = 6.0,
                minCosine: Float = 0.2,
                borderFraction: Float = 0.03,
                fallbackGray: UInt8 = 128,
                fillIterations: Int = 6) {
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.minCosine = minCosine
        self.borderFraction = borderFraction
        self.fallbackGray = fallbackGray
        self.fillIterations = fillIterations
    }
}

public struct ColorizeReport: Equatable {
    /// Vértices que receberam cor direto de um keyframe.
    public var coloredDirectly: Int
    /// Vértices sem keyframe que herdaram a média dos vizinhos.
    public var filledFromNeighbors: Int
    /// Vértices que ficaram com o cinza padrão.
    public var uncolored: Int
    /// Quantos keyframes foram de fato usados.
    public var framesUsed: Int
}

/// Cor por vértice a partir dos keyframes (marco M2A).
///
/// Para cada vértice escolhemos o MELHOR keyframe e amostramos a cor nele. A nota de
/// um keyframe para um vértice é alta quando a câmera vê a superfície de frente (normal
/// apontando para a câmera), de perto e longe da borda da imagem. A malha precisa estar
/// no mundo do ARKit (Y-up), que é onde as poses das câmeras foram gravadas.
///
/// Limite conhecido desta etapa: ainda não há teste de oclusão. Um keyframe pode "ver"
/// um vértice que na verdade está atrás de um móvel ou de uma parede fina. O teste com
/// o mapa de profundidade entra no M2B.
public enum VertexColorizer {

    /// Nota de um keyframe para um vértice. `nil` se o keyframe não serve.
    static func score(camera: CameraModel, point: SIMD3<Float>, normal: SIMD3<Float>, options: ColorizeOptions) -> Float? {
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
        // Peso que cresce da borda até 15% para dentro: o centro da lente distorce menos.
        let centerWeight = min(1, border / 0.15)
        let distanceWeight = 1 / (1 + projected.depth)
        return cosine * centerWeight * distanceWeight
    }

    /// Para cada vértice, o índice (em `cameras`) do melhor keyframe, ou -1 se nenhum serve.
    public static func assignKeyframes(mesh: WorldMesh,
                                       cameras: [CameraModel],
                                       options: ColorizeOptions = ColorizeOptions(),
                                       progress: ((Double) -> Void)? = nil) -> [Int32] {
        let vertexCount = mesh.vertexCount
        var assignment = [Int32](repeating: -1, count: vertexCount)
        if cameras.isEmpty {
            return assignment
        }
        let reportEvery = max(1, vertexCount / 50)

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            let point = SIMD3<Float>(mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
            let normal = SIMD3<Float>(mesh.normals[offset], mesh.normals[offset + 1], mesh.normals[offset + 2])

            var bestScore: Float = 0
            var bestCamera: Int32 = -1
            for cameraIndex in 0..<cameras.count {
                if let value = score(camera: cameras[cameraIndex], point: point, normal: normal, options: options),
                   value > bestScore {
                    bestScore = value
                    bestCamera = Int32(cameraIndex)
                }
            }
            assignment[vertex] = bestCamera

            if vertex % reportEvery == 0 {
                progress?(Double(vertex) / Double(vertexCount))
            }
        }
        progress?(1.0)
        return assignment
    }

    /// Colore a malha no lugar.
    /// - Parameter imageProvider: recebe o índice da câmera e devolve a imagem decodificada
    ///   (pode ser em resolução menor que a original; a escala é compensada aqui). É chamado
    ///   uma vez por keyframe usado, em ordem, para que só uma imagem fique na memória por vez.
    @discardableResult
    public static func colorize(mesh: inout WorldMesh,
                                cameras: [CameraModel],
                                options: ColorizeOptions = ColorizeOptions(),
                                imageProvider: (Int) -> RGBAImage?,
                                progress: ((Double) -> Void)? = nil) -> ColorizeReport {
        let vertexCount = mesh.vertexCount

        // Etapa 1 (60% do progresso): escolher o keyframe de cada vértice.
        let assignment = assignKeyframes(mesh: mesh, cameras: cameras, options: options) { fraction in
            progress?(0.6 * fraction)
        }

        // Agrupa os vértices por keyframe para decodificar cada imagem uma única vez.
        var verticesByCamera = [[Int32]](repeating: [], count: cameras.count)
        for vertex in 0..<vertexCount {
            let camera = assignment[vertex]
            if camera >= 0 {
                verticesByCamera[Int(camera)].append(Int32(vertex))
            }
        }

        var colors = [UInt8](repeating: options.fallbackGray, count: vertexCount * 3)
        var hasColor = [Bool](repeating: false, count: vertexCount)
        var coloredDirectly = 0
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

            for vertexValue in vertices {
                let vertex = Int(vertexValue)
                let offset = vertex * 3
                let point = SIMD3<Float>(mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
                guard let projected = camera.project(point) else {
                    continue
                }
                let color = image.sample(x: projected.u * scaleX, y: projected.v * scaleY)
                colors[offset] = color.r
                colors[offset + 1] = color.g
                colors[offset + 2] = color.b
                hasColor[vertex] = true
                coloredDirectly += 1
            }
            progress?(0.6 + 0.35 * Double(cameraIndex + 1) / Double(cameras.count))
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
                colors[vertex * 3] = UInt8(max(0, min(255, (sums[vertex * 3] / counts[vertex]).rounded())))
                colors[vertex * 3 + 1] = UInt8(max(0, min(255, (sums[vertex * 3 + 1] / counts[vertex]).rounded())))
                colors[vertex * 3 + 2] = UInt8(max(0, min(255, (sums[vertex * 3 + 2] / counts[vertex]).rounded())))
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
