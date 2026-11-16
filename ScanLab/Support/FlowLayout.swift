import SwiftUI

/// Arranjo em fileiras que quebra linha quando os itens não cabem na largura.
///
/// Os controles do app foram desenhados no iPad, onde uma fileira de botões cabe com
/// folga. No iPhone a mesma fileira passa da borda da tela. Com este arranjo, no iPad os
/// itens continuam numa linha só e no iPhone descem para a linha de baixo, sem precisar
/// de duas versões de cada tela. Cada fileira fica centralizada.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    /// Tamanho de cada item: o ideal dele, sem passar da largura disponível.
    private func sizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        var result: [CGSize] = []
        result.reserveCapacity(subviews.count)
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            result.append(size)
        }
        return result
    }

    /// Divide os itens em fileiras. Cada fileira é a lista de índices dos itens.
    private func rows(_ sizes: [CGSize], maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var width: CGFloat = 0
        for index in 0..<sizes.count {
            let itemWidth = sizes[index].width
            let needed = current.isEmpty ? itemWidth : width + spacing + itemWidth
            if !current.isEmpty && needed > maxWidth {
                rows.append(current)
                current = [index]
                width = itemWidth
            } else {
                current.append(index)
                width = needed
            }
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private func rowWidth(_ row: [Int], _ sizes: [CGSize]) -> CGFloat {
        var width: CGFloat = 0
        for (position, index) in row.enumerated() {
            width += sizes[index].width
            if position > 0 {
                width += spacing
            }
        }
        return width
    }

    private func rowHeight(_ row: [Int], _ sizes: [CGSize]) -> CGFloat {
        var height: CGFloat = 0
        for index in row {
            height = max(height, sizes[index].height)
        }
        return height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let itemSizes = sizes(subviews, maxWidth: maxWidth)
        let itemRows = rows(itemSizes, maxWidth: maxWidth)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (position, row) in itemRows.enumerated() {
            width = max(width, rowWidth(row, itemSizes))
            height += rowHeight(row, itemSizes)
            if position > 0 {
                height += lineSpacing
            }
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let itemSizes = sizes(subviews, maxWidth: bounds.width)
        let itemRows = rows(itemSizes, maxWidth: bounds.width)
        var y = bounds.minY
        for row in itemRows {
            let height = rowHeight(row, itemSizes)
            var x = bounds.minX + max(0, (bounds.width - rowWidth(row, itemSizes)) / 2)
            for index in row {
                let size = itemSizes[index]
                // Cada item fica centralizado na altura da sua fileira.
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}
