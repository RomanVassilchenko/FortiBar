import AppKit

/// Draws the menu bar icon: a template version of the app mark (an "F" of rounded bars whose
/// middle bar ends in a node) that follows the menu bar appearance like system icons.
/// The node carries the state:
/// - no tunnel: open ring
/// - connecting (nothing up yet): half-filled ring
/// - one tunnel up: filled node
/// - several tunnels up: a larger filled node with the count cut out of it
/// - a tunnel up while another one connects: a small dot next to the mark
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    private enum Node {
        case open, half, filled
        case count(String)
    }

    // Mark geometry in points (y up). Bar edges sit on whole points so 1x stays crisp.
    private static let bar: CGFloat = 3
    private static let stemX: CGFloat = 2
    private static let markTop: CGFloat = 16
    private static let markBottom: CGFloat = 2
    private static let topBarEnd: CGFloat = 15
    private static let armEnd: CGFloat = 9
    private static let armY: CGFloat = 8.5
    private static let nodeCenter = CGPoint(x: 13.5, y: 8.5)
    private static let nodeRadius: CGFloat = 3
    private static let badgeRadius: CGFloat = 4

    static func image(connected: Int, busy: Int) -> NSImage {
        let node: Node
        let description: String

        switch connected {
        case 0 where busy > 0:
            node = .half
            description = "Connecting"
        case 0:
            node = .open
            description = "Disconnected"
        case 1:
            node = .filled
            description = "Connected: 1 tunnel"
        default:
            node = .count(connected > 9 ? "+" : String(connected))
            description = "Connected: \(connected) tunnels"
        }

        let showsActivity = connected > 0 && busy > 0
        let width = showsActivity ? size.width + 4.5 : size.width

        let image = NSImage(size: NSSize(width: width, height: size.height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)

            context.addPath(markPath())
            context.fillPath()
            drawNode(node, in: context)

            if showsActivity {
                let dot = NSRect(x: size.width + 0.5, y: 2, width: 4, height: 4)
                context.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// The "F": one closed outline with round bar ends and small inner fillets.
    private static func markPath() -> CGPath {
        let x0 = stemX, x1 = stemX + bar
        let topBarBottom = markTop - bar
        let armTop = armY + bar / 2, armBottom = armY - bar / 2
        let end = bar / 2, inner: CGFloat = 0.5
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (x0, markTop, end), (topBarEnd, markTop, end), (topBarEnd, topBarBottom, end),
            (x1, topBarBottom, inner), (x1, armTop, inner), (armEnd, armTop, end),
            (armEnd, armBottom, end), (x1, armBottom, inner), (x1, markBottom, end), (x0, markBottom, end),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: (markTop + markBottom) / 2))
        for (i, corner) in corners.enumerated() {
            let next = corners[(i + 1) % corners.count]
            path.addArc(tangent1End: CGPoint(x: corner.0, y: corner.1),
                        tangent2End: CGPoint(x: next.0, y: next.1), radius: corner.2)
        }
        path.closeSubpath()
        return path
    }

    private static func circle(_ radius: CGFloat) -> CGRect {
        CGRect(x: nodeCenter.x - radius, y: nodeCenter.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func drawNode(_ node: Node, in context: CGContext) {
        let ringWidth: CGFloat = 1.5
        switch node {
        case .open:
            context.setLineWidth(ringWidth)
            context.strokeEllipse(in: circle(nodeRadius - ringWidth / 2))
        case .half:
            context.setLineWidth(ringWidth)
            context.strokeEllipse(in: circle(nodeRadius - ringWidth / 2))
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: nodeCenter.x, height: size.height))
            context.fillEllipse(in: circle(nodeRadius))
            context.restoreGState()
        case .filled:
            context.fillEllipse(in: circle(nodeRadius))
        case .count(let text):
            // Clear a thin gap around the badge so it reads as separate from the F
            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: circle(badgeRadius + 0.5))
            context.restoreGState()
            context.fillEllipse(in: circle(badgeRadius))
            cutOut(text)
        }
    }

    /// Punches the text out of the badge, so the menu bar shows through it.
    private static func cutOut(_ text: String) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut

        let font = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        // Centre on the digit's cap height rather than the line box
        let origin = NSPoint(
            x: nodeCenter.x - textSize.width / 2,
            y: nodeCenter.y - font.capHeight / 2 + font.descender
        )
        string.draw(at: origin)

        context.restoreGraphicsState()
    }
}
