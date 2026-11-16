import Foundation
import SceneKit
import ScanCore

/// Monta geometria do SceneKit a partir da malha do ScanCore.
/// Usado pelo exportador de USDZ e pelo visualizador 3D.
enum SceneGeometry {
    /// Fonte de vetores de 3 floats (posição, normal ou cor de 0 a 1).
    static func vectorSource(_ values: [Float], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let floatSize = MemoryLayout<Float>.size
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data,
                                 semantic: semantic,
                                 vectorCount: values.count / 3,
                                 usesFloatComponents: true,
                                 componentsPerVector: 3,
                                 bytesPerComponent: floatSize,
                                 dataOffset: 0,
                                 dataStride: floatSize * 3)
    }

    /// Cores de 8 bits (RGB) convertidas para a faixa de 0 a 1 que o SceneKit usa.
    static func colorSource(_ colors: [UInt8]) -> SCNGeometrySource {
        var floats = [Float](repeating: 0, count: colors.count)
        for index in 0..<colors.count {
            floats[index] = Float(colors[index]) / 255
        }
        return vectorSource(floats, semantic: .color)
    }

    /// Cada normal vira uma cor: (n + 1) / 2 leva o intervalo de -1 a 1 para 0 a 1.
    static func normalColorSource(_ normals: [Float]) -> SCNGeometrySource {
        var floats = [Float](repeating: 0, count: normals.count)
        for index in 0..<normals.count {
            floats[index] = normals[index] * 0.5 + 0.5
        }
        return vectorSource(floats, semantic: .color)
    }

    static func triangleElement(_ indices: [UInt32]) -> SCNGeometryElement {
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometryElement(data: data,
                                  primitiveType: .triangles,
                                  primitiveCount: indices.count / 3,
                                  bytesPerIndex: MemoryLayout<UInt32>.size)
    }

    /// Geometria de linhas soltas: cada par de pontos é um segmento.
    static func lines(_ points: [SIMD3<Float>], color: UIColor) -> SCNGeometry {
        var values: [Float] = []
        values.reserveCapacity(points.count * 3)
        var indices: [UInt32] = []
        indices.reserveCapacity(points.count)
        for position in 0..<points.count {
            values.append(points[position].x)
            values.append(points[position].y)
            values.append(points[position].z)
            indices.append(UInt32(position))
        }
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: data,
                                         primitiveType: .line,
                                         primitiveCount: points.count / 2,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [vectorSource(values, semantic: .vertex)], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        // Sem iluminação: a linha aparece sempre com a cor cheia.
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }

    /// - Parameter vertexColors: usar as cores por vértice da malha, se existirem.
    static func geometry(from mesh: WorldMesh, vertexColors: Bool) -> SCNGeometry {
        var sources = [vectorSource(mesh.positions, semantic: .vertex),
                       vectorSource(mesh.normals, semantic: .normal)]
        if vertexColors, let colors = mesh.colors, colors.count == mesh.positions.count {
            sources.append(colorSource(colors))
        }
        let geometry = SCNGeometry(sources: sources, elements: [triangleElement(mesh.indices)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        // A malha de um cômodo é vista por dentro e por fora.
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

extension SceneGeometry {
    /// Geometria texturizada: posição, normal e UV, com a imagem do atlas no material.
    static func texturedGeometry(from mesh: TexturedMesh, image: UIImage) -> SCNGeometry {
        let floatSize = MemoryLayout<Float>.size
        let uvData = mesh.uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSource = SCNGeometrySource(data: uvData,
                                         semantic: .texcoord,
                                         vectorCount: mesh.vertexCount,
                                         usesFloatComponents: true,
                                         componentsPerVector: 2,
                                         bytesPerComponent: floatSize,
                                         dataOffset: 0,
                                         dataStride: floatSize * 2)
        let geometry = SCNGeometry(sources: [vectorSource(mesh.positions, semantic: .vertex),
                                             vectorSource(mesh.normals, semantic: .normal),
                                             uvSource],
                                   elements: [triangleElement(mesh.indices)])
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

/// USDZ pelo SceneKit: monta uma cena com a malha e pede ao SceneKit para gravá-la.
/// O SceneKit escolhe o formato pela extensão do arquivo, e `.usdz` abre direto no
/// Quick Look (com AR) do iPhone, do iPad e do Mac.
enum USDZExporter {
    /// A malha deve estar em Y-up (o padrão do USD e do Quick Look).
    static func write(_ mesh: WorldMesh, to url: URL) throws {
        let scene = SCNScene()
        let node = SCNNode(geometry: SceneGeometry.geometry(from: mesh, vertexColors: true))
        node.name = "scan"
        scene.rootNode.addChildNode(node)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let succeeded = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        if !succeeded || !FileManager.default.fileExists(atPath: url.path) {
            throw ExportError.usdzFailed
        }
    }

    /// USDZ texturizado: a imagem do atlas vai embutida no arquivo.
    static func writeTextured(_ mesh: TexturedMesh, jpeg: Data, to url: URL) throws {
        guard let image = UIImage(data: jpeg) else {
            throw ExportError.usdzFailed
        }
        let scene = SCNScene()
        let node = SCNNode(geometry: SceneGeometry.texturedGeometry(from: mesh, image: image))
        node.name = "scan"
        scene.rootNode.addChildNode(node)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let succeeded = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        if !succeeded || !FileManager.default.fileExists(atPath: url.path) {
            throw ExportError.usdzFailed
        }
    }
}
