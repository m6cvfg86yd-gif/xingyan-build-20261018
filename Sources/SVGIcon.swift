import SwiftUI
import UIKit

/* ============================================================
   把网页版 m.html 里那些手画的 <svg> 图标原样搬到原生：
   直接把 SVG 源码贴进来，这里解析成 Path 再画出来，
   所以线宽、圆角、比例和网页版一模一样。
   ============================================================ */

struct IconSpec {
    var box: CGFloat = 24
    var minX: CGFloat = 0
    var minY: CGFloat = 0
    var fillPath = Path()
    var strokePath = Path()
    var strokeWidth: CGFloat = 1.6
    var hasFill = false
    var hasStroke = false
    /// 填充用「奇偶规则」挖空（fill-rule="evenodd"）。
    /// 很多现成的图标集（比如 Iconly）是**一条 path + evenodd 挖空**画出轮廓的：
    /// 齿轮中间的孔、放大镜的圈、聊天气泡里的点全靠它。不认这个属性的话
    /// 会被画成一坨实心块 —— 所以解析时记下来，画的时候用 FillStyle(eoFill:)。
    var eoFill = false
}

struct SVGIcon: View {
    let markup: String
    var size: CGFloat
    var color: Color = .white
    var iconFill: Color? = nil
    /* ⚠ 2026-10-16 用户：「底栏图标换了不生效」。
       原因：后台换图标存下来的那段 SVG **自己带着 data-key**（比如 tab.chat 里存的那段
       写着 data-key="i.moments"），而这里又拿它去 IconOverrides 映射了一遍 ——
       于是画出来的是**另一个键**的图标（i.moments），看着就像"换了没生效"。
       direct = true 表示：这段 markup 本身就是后台换过的那份，**原样画**，别再映射。 */
    var direct: Bool = false

    var body: some View {
        // 后台换过的图标优先
        let raw = direct ? markup : IconOverrides.markup(markup)
        if raw.hasPrefix("<svg") {
            vector(raw)
        } else if raw.hasPrefix("http") || raw.hasPrefix("/uploads") || raw.hasPrefix("data:") {
            RemoteImage(path: raw).frame(width: size, height: size)
        } else {
            Text(raw)
                .font(.system(size: size * 0.86))
                .foregroundColor(color)
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func vector(_ markup: String) -> some View {
        let spec = SVG.spec(markup)
        let s = size / spec.box
        let t = CGAffineTransform(translationX: -spec.minX, y: -spec.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
        ZStack {
            if spec.hasFill {
                spec.fillPath
                    .applying(t)
                    .fill(iconFill ?? color, style: FillStyle(eoFill: spec.eoFill))
            }
            if spec.hasStroke {
                spec.strokePath
                    .applying(t)
                    .stroke(color, style: StrokeStyle(lineWidth: max(0.5, spec.strokeWidth * s),
                                                      lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

enum SVG {
    private static var cache: [String: IconSpec] = [:]

    static func spec(_ markup: String) -> IconSpec {
        if let hit = cache[markup] { return hit }
        let made = parse(markup)
        cache[markup] = made
        return made
    }

    /* ---------------------------------------------------------- 解析 */

    private static func parse(_ markup: String) -> IconSpec {
        var spec = IconSpec()
        guard let svgRange = markup.range(of: "<svg") else { return spec }
        let head = String(markup[svgRange.upperBound...])
        let rootAttrs: [String: String]
        if let close = head.range(of: ">") {
            rootAttrs = attrs(String(head[head.startIndex..<close.lowerBound]))
        } else {
            rootAttrs = [:]
        }
        if let vb = rootAttrs["viewBox"] {
            let p = vb.split(separator: " ").compactMap { Double($0) }
            if p.count == 4, p[2] > 0 {
                spec.box = CGFloat(p[2])
                spec.minX = CGFloat(p[0])
                spec.minY = CGFloat(p[1])
            }
        }
        let rootFill = rootAttrs["fill"] ?? "none"
        let rootStroke = rootAttrs["stroke"]
        let rootSW = CGFloat(Double(rootAttrs["stroke-width"] ?? "") ?? 1.6)

        // 逐个读子元素
        let body = markup
        var searchStart = body.startIndex
        while let lt = body.range(of: "<", range: searchStart..<body.endIndex) {
            guard let gt = body.range(of: ">", range: lt.upperBound..<body.endIndex) else { break }
            let inner = String(body[lt.upperBound..<gt.lowerBound])
            searchStart = gt.upperBound
            if inner.hasPrefix("/") || inner.hasPrefix("?") || inner.hasPrefix("!") { continue }
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            var nameEnd = trimmed.startIndex
            while nameEnd < trimmed.endIndex && !trimmed[nameEnd].isWhitespace {
                nameEnd = trimmed.index(after: nameEnd)
            }
            let name = String(trimmed[trimmed.startIndex..<nameEnd]).replacingOccurrences(of: "/", with: "")
            let a = attrs(trimmed)

            var p = Path()
            switch name {
            case "path":
                p = SVGPath.parse(a["d"] ?? "")
            case "circle":
                let cx = num(a["cx"]), cy = num(a["cy"]), r = num(a["r"])
                p = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case "ellipse":
                let cx = num(a["cx"]), cy = num(a["cy"]), rx = num(a["rx"]), ry = num(a["ry"])
                p = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            case "rect":
                let x = num(a["x"]), y = num(a["y"]), w = num(a["width"]), h = num(a["height"])
                let rx = a["rx"] != nil ? num(a["rx"]) : num(a["ry"])
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if rx > 0 {
                    p = Path(roundedRect: rect, cornerRadius: rx)
                } else {
                    p = Path(rect)
                }
            case "line":
                p.move(to: CGPoint(x: num(a["x1"]), y: num(a["y1"])))
                p.addLine(to: CGPoint(x: num(a["x2"]), y: num(a["y2"])))
            case "polyline", "polygon":
                let pts = (a["points"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { Double($0) }
                var i = 0
                var first = true
                while i + 1 < pts.count {
                    let pt = CGPoint(x: pts[i], y: pts[i + 1])
                    if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
                    i += 2
                }
                if name == "polygon" { p.closeSubpath() }
            default:
                continue
            }

            let fill = a["fill"] ?? rootFill
            let stroke = a["stroke"] ?? rootStroke
            if fill != "none" && !fill.isEmpty {
                spec.fillPath.addPath(p)
                spec.hasFill = true
                /* 奇偶填充规则：现成图标集（Iconly 那类）靠它挖空 */
                let rule = a["fill-rule"] ?? rootAttrs["fill-rule"] ?? ""
                if rule == "evenodd" { spec.eoFill = true }
            }
            if let stroke = stroke, stroke != "none" && !stroke.isEmpty {
                spec.strokePath.addPath(p)
                spec.hasStroke = true
                spec.strokeWidth = CGFloat(Double(a["stroke-width"] ?? "") ?? Double(rootSW))
            }
        }
        return spec
    }

    private static func num(_ s: String?) -> CGFloat {
        CGFloat(Double(s ?? "") ?? 0)
    }

    private static func attrs(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = "([a-zA-Z_:][-a-zA-Z0-9_:]*)\\s*=\\s*\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.numberOfRanges == 3 {
                let k = ns.substring(with: m.range(at: 1))
                let v = ns.substring(with: m.range(at: 2))
                out[k] = v
            }
        }
        return out
    }
}

/* ---------------------------------------------------------- path d 解析 */

enum SVGPath {
    private struct Cmd {
        var code: Character
        var args: [CGFloat]
    }

    static func parse(_ d: String) -> Path {
        var path = Path()
        var cur = CGPoint.zero
        var sub = CGPoint.zero
        var lastCtrl: CGPoint? = nil
        var prevUpper: Character = "M"

        for cmd in tokenize(d) {
            let code = cmd.code
            let upper = Character(String(code).uppercased())
            let rel = code.isLowercase
            let args = cmd.args

            var i = 0
            func next() -> CGFloat { defer { i += 1 }; return i < args.count ? args[i] : 0 }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }

            switch upper {
            case "M":
                if i + 1 < args.count {
                    let p = point(next(), next())
                    path.move(to: p)
                    cur = p; sub = p
                }
                // 后面的坐标对按 lineto 处理
                while i + 1 < args.count {
                    let q = point(next(), next())
                    path.addLine(to: q); cur = q
                }
                lastCtrl = nil

            case "L":
                while i + 1 < args.count {
                    let p = point(next(), next())
                    path.addLine(to: p); cur = p
                }
                lastCtrl = nil

            case "H":
                while i < args.count {
                    let x = next()
                    let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                    path.addLine(to: p); cur = p
                }
                lastCtrl = nil

            case "V":
                while i < args.count {
                    let y = next()
                    let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                    path.addLine(to: p); cur = p
                }
                lastCtrl = nil

            case "C":
                while i + 5 < args.count {
                    let c1 = point(next(), next())
                    let c2 = point(next(), next())
                    let p = point(next(), next())
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastCtrl = c2; cur = p
                }

            case "S":
                while i + 3 < args.count {
                    let c1: CGPoint
                    if let lc = lastCtrl, "CS".contains(prevUpper) {
                        c1 = CGPoint(x: cur.x * 2 - lc.x, y: cur.y * 2 - lc.y)
                    } else {
                        c1 = cur
                    }
                    let c2 = point(next(), next())
                    let p = point(next(), next())
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastCtrl = c2; cur = p
                }

            case "Q":
                while i + 3 < args.count {
                    let c = point(next(), next())
                    let p = point(next(), next())
                    path.addQuadCurve(to: p, control: c)
                    lastCtrl = c; cur = p
                }

            case "T":
                while i + 1 < args.count {
                    let c: CGPoint
                    if let lc = lastCtrl, "QT".contains(prevUpper) {
                        c = CGPoint(x: cur.x * 2 - lc.x, y: cur.y * 2 - lc.y)
                    } else {
                        c = cur
                    }
                    let p = point(next(), next())
                    path.addQuadCurve(to: p, control: c)
                    lastCtrl = c; cur = p
                }

            case "A":
                while i + 6 < args.count {
                    let rx = next(), ry = next(), rot = next()
                    let large = next() != 0, sweep = next() != 0
                    let p = point(next(), next())
                    for seg in arc(from: cur, to: p, rx: rx, ry: ry, rot: rot, large: large, sweep: sweep) {
                        path.addCurve(to: seg.2, control1: seg.0, control2: seg.1)
                    }
                    lastCtrl = nil; cur = p
                }

            case "Z":
                path.closeSubpath()
                cur = sub
                lastCtrl = nil

            default:
                break
            }
            prevUpper = upper
        }
        return path
    }

    private static func tokenize(_ d: String) -> [Cmd] {
        var out: [Cmd] = []
        var cmd: Character = "M"
        var args: [CGFloat] = []
        var token = ""
        var hasCmd = false

        func flushToken() {
            if !token.isEmpty {
                if let v = Double(token) { args.append(CGFloat(v)) }
                token = ""
            }
        }
        func flushCmd() {
            flushToken()
            if hasCmd {
                out.append(Cmd(code: cmd, args: args))
                args = []
            }
        }

        for ch in d {
            if ch.isLetter {
                flushCmd()
                cmd = ch
                hasCmd = true
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" || ch == "\r" {
                flushToken()
            } else if ch == "-" || ch == "+" {
                flushToken()
                token = String(ch)
            } else {
                token.append(ch)
            }
        }
        flushCmd()
        return out
    }

    /// SVG 的弧线转三次贝塞尔
    private static func arc(from p0: CGPoint, to p1: CGPoint,
                            rx rxIn: CGFloat, ry ryIn: CGFloat, rot: CGFloat,
                            large: Bool, sweep: Bool) -> [(CGPoint, CGPoint, CGPoint)] {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { return [(p0, p1, p1)] }
        let phi = rot * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        var rx2 = rx * rx, ry2 = ry * ry
        let lambda = x1p * x1p / rx2 + y1p * y1p / ry2
        if lambda > 1 {
            let k = sqrt(lambda)
            rx *= k; ry *= k
            rx2 = rx * rx; ry2 = ry * ry
        }
        var num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        if den == 0 { return [(p0, p1, p1)] }
        if num < 0 { num = 0 }
        var coef = sqrt(num / den)
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            if len == 0 { return 0 }
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var dTheta = angle(ux, uy, vx, vy)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var result: [(CGPoint, CGPoint, CGPoint)] = []
        var th = theta1
        for _ in 0..<segments {
            let th2 = th + delta
            let c1 = cos(th), s1 = sin(th)
            let c2 = cos(th2), s2 = sin(th2)
            let e1 = CGPoint(x: cx + rx * cosPhi * c1 - ry * sinPhi * s1,
                             y: cy + rx * sinPhi * c1 + ry * cosPhi * s1)
            let e2 = CGPoint(x: cx + rx * cosPhi * c2 - ry * sinPhi * s2,
                             y: cy + rx * sinPhi * c2 + ry * cosPhi * s2)
            let d1 = CGPoint(x: -rx * cosPhi * s1 - ry * sinPhi * c1,
                             y: -rx * sinPhi * s1 + ry * cosPhi * c1)
            let d2 = CGPoint(x: -rx * cosPhi * s2 - ry * sinPhi * c2,
                             y: -rx * sinPhi * s2 + ry * cosPhi * c2)
            let k1 = CGPoint(x: e1.x + t * d1.x, y: e1.y + t * d1.y)
            let k2 = CGPoint(x: e2.x - t * d2.x, y: e2.y - t * d2.y)
            result.append((k1, k2, e2))
            th = th2
        }
        return result
    }
}

private extension Path {
    mutating func addPath(_ other: Path) {
        addPath(other, transform: .identity)
    }
}
