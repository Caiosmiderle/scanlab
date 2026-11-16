import Foundation
import simd

/// Trecho reto no plano da planta (metros). Serve para parede, porta, janela ou vão.
public struct PlanSegment: Equatable, Codable {
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>

    public init(start: SIMD2<Float>, end: SIMD2<Float>) {
        self.start = start
        self.end = end
    }

    public var length: Float {
        return simd_distance(start, end)
    }

    public var midpoint: SIMD2<Float> {
        return (start + end) / 2
    }
}

public enum PlanOpeningKind: String, Codable {
    case door
    case window
    case opening
}

/// Porta, janela ou vão desenhado sobre uma parede.
public struct PlanOpening: Equatable, Codable {
    public var kind: PlanOpeningKind
    public var segment: PlanSegment

    public init(kind: PlanOpeningKind, segment: PlanSegment) {
        self.kind = kind
        self.segment = segment
    }
}

/// Um cômodo em estruturas simples, sem tipos do RoomPlan, para ser testável.
public struct PlanRoom: Equatable, Codable {
    public var name: String
    public var walls: [PlanSegment]
    public var openings: [PlanOpening]
    /// Contorno do piso, se o sensor entregou. Vazio se não houver.
    public var floorPolygon: [SIMD2<Float>]
    /// Pé-direito aproximado, em metros.
    public var ceilingHeight: Float?

    public init(name: String,
                walls: [PlanSegment],
                openings: [PlanOpening] = [],
                floorPolygon: [SIMD2<Float>] = [],
                ceilingHeight: Float? = nil) {
        self.name = name
        self.walls = walls
        self.openings = openings
        self.floorPolygon = floorPolygon
        self.ceilingHeight = ceilingHeight
    }

    /// Soma do comprimento das paredes, em metros.
    public var perimeter: Float {
        var total: Float = 0
        for wall in walls {
            total += wall.length
        }
        return total
    }

    /// Contorno usado para área e rótulo: o do piso, se existir; senão, as paredes
    /// encadeadas ponta com ponta. `nil` se as paredes não fecham um polígono.
    public var outline: [SIMD2<Float>]? {
        if floorPolygon.count >= 3 {
            return floorPolygon
        }
        return PlanGeometry.orderedPolygon(from: walls)
    }

    /// Área aproximada em m². `nil` se não der para fechar o contorno.
    public var area: Float? {
        guard let outline = outline else {
            return nil
        }
        return PlanGeometry.polygonArea(outline)
    }

    /// Ponto para o rótulo do cômodo.
    public var labelPoint: SIMD2<Float>? {
        if let outline = outline, !outline.isEmpty {
            return PlanGeometry.average(outline)
        }
        var points: [SIMD2<Float>] = []
        for wall in walls {
            points.append(wall.start)
            points.append(wall.end)
        }
        return points.isEmpty ? nil : PlanGeometry.average(points)
    }
}

public enum PlanGeometry {
    /// Leva um ponto do mundo do ARKit (Y para cima) para o plano da planta.
    /// A planta é a vista de cima: X continua sendo X e a profundidade Z vira o eixo
    /// vertical da folha. Como o Y da folha (SVG) cresce para baixo e, olhando de cima,
    /// +Z do mundo aponta para baixo na página, a vista sai sem espelhar.
    public static func planPoint(_ world: SIMD3<Float>) -> SIMD2<Float> {
        return SIMD2<Float>(world.x, world.z)
    }

    /// Trecho no plano a partir da pose e da largura de uma superfície vertical
    /// (parede, porta, janela). A superfície é centrada na origem do `transform` e a
    /// largura corre ao longo do eixo X local.
    public static func segment(transform: simd_float4x4, width: Float) -> PlanSegment {
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let axis = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let half = axis * (width / 2)
        return PlanSegment(start: planPoint(center - half), end: planPoint(center + half))
    }

    /// Área de um polígono simples (fórmula do laço), sempre positiva.
    public static func polygonArea(_ points: [SIMD2<Float>]) -> Float {
        if points.count < 3 {
            return 0
        }
        var sum: Float = 0
        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    public static func average(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        if points.isEmpty {
            return SIMD2<Float>(0, 0)
        }
        var sum = SIMD2<Float>(0, 0)
        for point in points {
            sum += point
        }
        return sum / Float(points.count)
    }

    /// Encadeia as paredes ponta com ponta para formar o contorno do cômodo.
    ///
    /// As paredes do sensor vêm em ordem qualquer, com sentido qualquer, e as pontas
    /// não coincidem exatamente; por isso a busca aceita pontas a até `tolerance` metros.
    /// - Returns: os cantos em ordem, ou `nil` se as paredes não fecham um laço que
    ///   use todas elas (cômodo aberto, parede faltando).
    public static func orderedPolygon(from walls: [PlanSegment], tolerance: Float = 0.35) -> [SIMD2<Float>]? {
        if walls.count < 3 {
            return nil
        }
        var used = [Bool](repeating: false, count: walls.count)
        var polygon: [SIMD2<Float>] = [walls[0].start]
        var current = walls[0].end
        used[0] = true
        var usedCount = 1

        while usedCount < walls.count {
            var bestIndex = -1
            var bestDistance = tolerance
            var bestIsReversed = false
            for index in 0..<walls.count where !used[index] {
                let toStart = simd_distance(current, walls[index].start)
                if toStart <= bestDistance {
                    bestDistance = toStart
                    bestIndex = index
                    bestIsReversed = false
                }
                let toEnd = simd_distance(current, walls[index].end)
                if toEnd <= bestDistance {
                    bestDistance = toEnd
                    bestIndex = index
                    bestIsReversed = true
                }
            }
            if bestIndex < 0 {
                return nil
            }
            let wall = walls[bestIndex]
            // O canto é o ponto médio entre a ponta onde paramos e a ponta que casou.
            let joined = bestIsReversed ? wall.end : wall.start
            polygon.append((current + joined) / 2)
            current = bestIsReversed ? wall.start : wall.end
            used[bestIndex] = true
            usedCount += 1
        }

        // Tem de voltar ao ponto de partida.
        if simd_distance(current, polygon[0]) > tolerance {
            return nil
        }
        polygon[0] = (polygon[0] + current) / 2
        return polygon
    }
}

public struct FloorPlanOptions: Equatable {
    public var pixelsPerMeter: Float
    /// Margem em volta do desenho, em pixels.
    public var margin: Float
    /// Escrever o comprimento de cada parede.
    public var showDimensions: Bool
    public var title: String?

    public init(pixelsPerMeter: Float = 100, margin: Float = 90, showDimensions: Bool = true, title: String? = nil) {
        self.pixelsPerMeter = pixelsPerMeter
        self.margin = margin
        self.showDimensions = showDimensions
        self.title = title
    }
}

/// Gera a planta baixa em SVG (marco M3).
public enum FloorPlanSVG {
    /// Número com duas casas e vírgula decimal, como se escreve em português.
    public static func formatMeters(_ value: Float) -> String {
        return String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func escape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }

    private static func number(_ value: Float) -> String {
        return String(format: "%.1f", value)
    }

    public static func render(rooms: [PlanRoom], options: FloorPlanOptions = FloorPlanOptions()) -> String {
        // Limites de tudo o que será desenhado.
        var points: [SIMD2<Float>] = []
        for room in rooms {
            for wall in room.walls {
                points.append(wall.start)
                points.append(wall.end)
            }
            points.append(contentsOf: room.floorPolygon)
            for opening in room.openings {
                points.append(opening.segment.start)
                points.append(opening.segment.end)
            }
        }

        let footerHeight: Float = 70
        guard let first = points.first else {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="400" height="120" viewBox="0 0 400 120">
            <rect width="400" height="120" fill="#ffffff"/>
            <text x="200" y="65" font-family="Helvetica, Arial, sans-serif" font-size="16" text-anchor="middle" fill="#444444">Planta vazia</text>
            </svg>

            """
        }
        var lower = first
        var upper = first
        for point in points {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }

        let scale = options.pixelsPerMeter
        let margin = options.margin
        let titleHeight: Float = options.title == nil ? 0 : 40
        let width = (upper.x - lower.x) * scale + margin * 2
        let height = (upper.y - lower.y) * scale + margin * 2 + titleHeight + footerHeight

        // Metros → pixels.
        func px(_ point: SIMD2<Float>) -> SIMD2<Float> {
            return SIMD2<Float>(margin + (point.x - lower.x) * scale,
                                margin + titleHeight + (point.y - lower.y) * scale)
        }

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(width))\" height=\"\(number(height))\" viewBox=\"0 0 \(number(width)) \(number(height))\" font-family=\"Helvetica, Arial, sans-serif\">")
        lines.append("<rect width=\"\(number(width))\" height=\"\(number(height))\" fill=\"#ffffff\"/>")

        if let title = options.title {
            lines.append("<text class=\"title\" x=\"\(number(margin))\" y=\"\(number(margin * 0.5 + 12))\" font-size=\"22\" font-weight=\"bold\" fill=\"#111111\">\(escape(title))</text>")
        }

        // Pisos primeiro, para as paredes ficarem por cima.
        for room in rooms {
            if let outline = room.outline, outline.count >= 3 {
                var path = ""
                for point in outline {
                    let p = px(point)
                    path += "\(number(p.x)),\(number(p.y)) "
                }
                lines.append("<polygon class=\"floor\" points=\"\(path.trimmingCharacters(in: .whitespaces))\" fill=\"#f1f3f5\" stroke=\"none\"/>")
            }
        }

        for room in rooms {
            for wall in room.walls {
                let a = px(wall.start)
                let b = px(wall.end)
                lines.append("<line class=\"wall\" x1=\"\(number(a.x))\" y1=\"\(number(a.y))\" x2=\"\(number(b.x))\" y2=\"\(number(b.y))\" stroke=\"#1f2933\" stroke-width=\"8\" stroke-linecap=\"round\"/>")
            }
        }

        // Aberturas: primeiro "apaga" o trecho da parede com branco, depois desenha o símbolo.
        for room in rooms {
            for opening in room.openings {
                let a = px(opening.segment.start)
                let b = px(opening.segment.end)
                let coordinates = "x1=\"\(number(a.x))\" y1=\"\(number(a.y))\" x2=\"\(number(b.x))\" y2=\"\(number(b.y))\""
                lines.append("<line \(coordinates) stroke=\"#ffffff\" stroke-width=\"10\"/>")
                switch opening.kind {
                case .door:
                    lines.append("<line class=\"door\" \(coordinates) stroke=\"#c2410c\" stroke-width=\"3\"/>")
                case .window:
                    lines.append("<line class=\"window\" \(coordinates) stroke=\"#2563eb\" stroke-width=\"4\"/>")
                case .opening:
                    lines.append("<line class=\"opening\" \(coordinates) stroke=\"#6b7280\" stroke-width=\"2\" stroke-dasharray=\"8 6\"/>")
                }
            }
        }

        // Cotas: comprimento de cada parede, escrito do lado de fora do cômodo.
        if options.showDimensions {
            for room in rooms {
                let center = room.labelPoint ?? SIMD2<Float>(0, 0)
                for wall in room.walls where wall.length > 0.2 {
                    let a = px(wall.start)
                    let b = px(wall.end)
                    let middle = (a + b) / 2
                    let direction = simd_normalize(b - a)
                    var normal = SIMD2<Float>(-direction.y, direction.x)
                    // A normal tem de apontar para longe do centro do cômodo.
                    if simd_dot(normal, middle - px(center)) < 0 {
                        normal = -normal
                    }
                    let position = middle + normal * 22
                    // Ângulo do texto, mantido entre -90 e 90 graus para não ficar de cabeça para baixo.
                    var angle = atan2(direction.y, direction.x) * 180 / Float.pi
                    if angle > 90 {
                        angle -= 180
                    }
                    if angle < -90 {
                        angle += 180
                    }
                    lines.append("<text class=\"dimension\" x=\"\(number(position.x))\" y=\"\(number(position.y))\" font-size=\"14\" fill=\"#374151\" text-anchor=\"middle\" dominant-baseline=\"middle\" transform=\"rotate(\(number(angle)) \(number(position.x)) \(number(position.y)))\">\(formatMeters(wall.length)) m</text>")
                }
            }
        }

        // Nome e área de cada cômodo.
        for room in rooms {
            guard let labelPoint = room.labelPoint else {
                continue
            }
            let p = px(labelPoint)
            lines.append("<text class=\"room-name\" x=\"\(number(p.x))\" y=\"\(number(p.y - 6))\" font-size=\"18\" font-weight=\"bold\" fill=\"#111111\" text-anchor=\"middle\">\(escape(room.name))</text>")
            if let area = room.area {
                lines.append("<text class=\"room-area\" x=\"\(number(p.x))\" y=\"\(number(p.y + 16))\" font-size=\"16\" fill=\"#111111\" text-anchor=\"middle\">\(formatMeters(area)) m²</text>")
            }
        }

        // Rodapé: barra de escala de 1 m e o aviso de medida aproximada.
        let barY = height - footerHeight + 24
        lines.append("<line class=\"scale-bar\" x1=\"\(number(margin))\" y1=\"\(number(barY))\" x2=\"\(number(margin + scale))\" y2=\"\(number(barY))\" stroke=\"#111111\" stroke-width=\"3\"/>")
        lines.append("<text x=\"\(number(margin + scale + 10))\" y=\"\(number(barY + 5))\" font-size=\"14\" fill=\"#111111\">1 m</text>")
        lines.append("<text class=\"notice\" x=\"\(number(margin))\" y=\"\(number(barY + 30))\" font-size=\"13\" fill=\"#6b7280\">Medidas aproximadas (LiDAR). Confira com a trena.</text>")

        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }
}
