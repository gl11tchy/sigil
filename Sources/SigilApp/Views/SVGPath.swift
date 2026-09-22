import SwiftUI

/// The subset of SVG path data the provider marks use.
enum SVGPath {
    static func bounds(of data: String) -> CGRect {
        path(from: data).boundingRect
    }

    static func path(from data: String) -> Path {
        var parser = Parser(data)
        return parser.parse()
    }
}

private struct Parser {
    private let data: String
    private var index: String.Index
    private var command: Character = "M"
    private var point = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var path = Path()

    init(_ data: String) {
        self.data = data
        index = data.startIndex
    }

    mutating func parse() -> Path {
        while let next = readCommand() {
            command = next
            append(command)
            let repeated: Character = command == "M" ? "L" : command == "m" ? "l" : command
            while peekNumber {
                let before = index
                append(repeated)
                if index == before { break }
            }
        }
        return path
    }

    private var peekNumber: Bool {
        var cursor = index
        while cursor < data.endIndex, isSeparator(data[cursor]) {
            cursor = data.index(after: cursor)
        }
        guard cursor < data.endIndex else { return false }
        let character = data[cursor]
        return character == "." || character == "+" || character == "-" || character.isNumber
    }

    private mutating func append(_ command: Character) {
        switch command {
        case "M":
            guard let x = readNumber(), let y = readNumber() else { return }
            point = CGPoint(x: x, y: y)
            subpathStart = point
            path.move(to: point)
        case "m":
            guard let x = readNumber(), let y = readNumber() else { return }
            point = CGPoint(x: point.x + x, y: point.y + y)
            subpathStart = point
            path.move(to: point)
        case "L":
            guard let x = readNumber(), let y = readNumber() else { return }
            point = CGPoint(x: x, y: y)
            path.addLine(to: point)
        case "l":
            guard let x = readNumber(), let y = readNumber() else { return }
            point = CGPoint(x: point.x + x, y: point.y + y)
            path.addLine(to: point)
        case "H":
            guard let x = readNumber() else { return }
            point.x = x
            path.addLine(to: point)
        case "h":
            guard let x = readNumber() else { return }
            point.x += x
            path.addLine(to: point)
        case "V":
            guard let y = readNumber() else { return }
            point.y = y
            path.addLine(to: point)
        case "v":
            guard let y = readNumber() else { return }
            point.y += y
            path.addLine(to: point)
        case "C":
            addCubic(relative: false)
        case "c":
            addCubic(relative: true)
        case "A":
            addArc(relative: false)
        case "a":
            addArc(relative: true)
        case "Z", "z":
            path.closeSubpath()
            point = subpathStart
        default:
            break
        }
    }

    private mutating func addCubic(relative: Bool) {
        guard let x1 = readNumber(), let y1 = readNumber(),
            let x2 = readNumber(), let y2 = readNumber(),
            let x = readNumber(), let y = readNumber()
        else { return }
        let origin = relative ? point : .zero
        let end = CGPoint(x: origin.x + x, y: origin.y + y)
        path.addCurve(
            to: end,
            control1: CGPoint(x: origin.x + x1, y: origin.y + y1),
            control2: CGPoint(x: origin.x + x2, y: origin.y + y2)
        )
        point = end
    }

    private mutating func addArc(relative: Bool) {
        guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
            let large = readFlag(), let sweep = readFlag(),
            let x = readNumber(), let y = readNumber()
        else { return }
        let end = CGPoint(
            x: relative ? point.x + x : x,
            y: relative ? point.y + y : y
        )
        addEllipticalArc(
            from: point, rx: rx, ry: ry, rotation: rotation,
            largeArc: large, sweep: sweep, to: end
        )
        point = end
    }

    /// Endpoint-to-center conversion from the SVG spec, drawn as cubics.
    private mutating func addEllipticalArc(
        from start: CGPoint, rx inRx: CGFloat, ry inRy: CGFloat, rotation: CGFloat,
        largeArc: Bool, sweep: Bool, to end: CGPoint
    ) {
        if start == end { return }
        var rx = abs(inRx)
        var ry = abs(inRy)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        var rxsq = rx * rx
        var rysq = ry * ry
        let x1psq = x1p * x1p
        let y1psq = y1p * y1p
        let lambda = x1psq / rxsq + y1psq / rysq
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
            rxsq = rx * rx
            rysq = ry * ry
        }
        let sign: CGFloat = (largeArc == sweep) ? -1 : 1
        let numerator = max(0, rxsq * rysq - rxsq * y1psq - rysq * x1psq)
        let denominator = rxsq * y1psq + rysq * x1psq
        let coef = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -ry * x1p / rx
        let center = CGPoint(
            x: cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2,
            y: sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2
        )
        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let lengths = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard lengths > 0 else { return 0 }
            var angle = acos(min(1, max(-1, dot / lengths)))
            if ux * vy - uy * vx < 0 { angle = -angle }
            return angle
        }
        let theta1 = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = vectorAngle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(Double(delta)) / (Double.pi / 2))))
        let step = delta / CGFloat(segments)
        var angle = theta1
        for _ in 0..<segments {
            let next = angle + step
            let alpha = sin(step) * (sqrt(4 + 3 * tan(step / 2) * tan(step / 2)) - 1) / 3
            func map(_ theta: CGFloat, _ offsetX: CGFloat, _ offsetY: CGFloat) -> CGPoint {
                let x = cos(theta) + offsetX
                let y = sin(theta) + offsetY
                return CGPoint(
                    x: center.x + rx * cosPhi * x - ry * sinPhi * y,
                    y: center.y + rx * sinPhi * x + ry * cosPhi * y
                )
            }
            path.addCurve(
                to: map(next, 0, 0),
                control1: map(angle, -alpha * sin(angle), alpha * cos(angle)),
                control2: map(next, alpha * sin(next), -alpha * cos(next))
            )
            angle = next
        }
    }

    private mutating func readCommand() -> Character? {
        skipSeparators()
        guard index < data.endIndex else { return nil }
        let character = data[index]
        guard character.isLetter else { return nil }
        index = data.index(after: index)
        return character
    }

    private mutating func readFlag() -> Bool? {
        skipSeparators()
        guard index < data.endIndex else { return nil }
        let character = data[index]
        guard character == "0" || character == "1" else { return nil }
        index = data.index(after: index)
        return character == "1"
    }

    private mutating func readNumber() -> CGFloat? {
        skipSeparators()
        let start = index
        guard index < data.endIndex else { return nil }
        if data[index] == "+" || data[index] == "-" { index = data.index(after: index) }
        var sawDigit = false
        var sawDot = false
        while index < data.endIndex {
            let character = data[index]
            if character.isNumber {
                sawDigit = true
                index = data.index(after: index)
            } else if character == ".", !sawDot {
                sawDot = true
                index = data.index(after: index)
            } else {
                break
            }
        }
        if index < data.endIndex, data[index] == "e" || data[index] == "E" {
            let exponent = data.index(after: index)
            var cursor = exponent
            if cursor < data.endIndex, data[cursor] == "+" || data[cursor] == "-" {
                cursor = data.index(after: cursor)
            }
            var sawExponent = false
            while cursor < data.endIndex, data[cursor].isNumber {
                sawExponent = true
                cursor = data.index(after: cursor)
            }
            if sawExponent { index = cursor }
        }
        guard sawDigit, let value = Double(data[start..<index]) else {
            index = start
            return nil
        }
        return CGFloat(value)
    }

    private mutating func skipSeparators() {
        while index < data.endIndex, isSeparator(data[index]) {
            index = data.index(after: index)
        }
    }

    private func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "," || character == "\n" || character == "\t"
    }
}
