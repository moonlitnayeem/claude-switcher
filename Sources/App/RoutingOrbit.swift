import SwiftUI

struct RouteMapSignal: Equatable {
    enum Phase: Equatable { case sending, answered, failed }
    let phase: Phase
    let backup: Bool
    let model: String?
    let at: Date
    var mainLimited = false
}

enum OrbitInk {
    static let aqua = Color(red: 0.42, green: 0.94, blue: 0.85)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.39)
    static let lavender = Color(red: 0.67, green: 0.70, blue: 1.0)
    static let quiet = Color(red: 0.67, green: 0.71, blue: 0.80)
}

struct RoutingOrbitCard: View {
    let data: RoutingDisplay
    @Binding var enabled: Bool
    let canSwitch: Bool
    let compact: Bool

    private var signal: RouteMapSignal? { enabled ? data.route : nil }

    private var status: (title: String, detail: String) {
        if let live = signal, live.phase == .sending {
            if live.backup, live.mainLimited {
                return (L10n.text("Trying your backup"), live.model.map { L10n.format("Your main account reached its limit. The backup is trying %@.", $0) }
                        ?? L10n.text("Your main account reached its limit. The backup is trying this request."))
            }
            return (L10n.text(live.backup ? "Trying your backup" : "Asking your main account"),
                    live.model.map { L10n.format("Waiting for %@ to answer.", $0) }
                    ?? L10n.text("Waiting for Claude to answer."))
        }
        return (data.title, data.detail)
    }

    private var mapDescription: String {
        guard let signal else {
            return L10n.text(enabled ? "Waiting for a request" : "Switching is off")
        }
        switch signal.phase {
        case .sending:
            return L10n.text(signal.backup ? "Sending to your backup" : "Sending to your main account")
        case .answered:
            return L10n.text(signal.backup ? "Last reply came from your backup" : "Last reply came from your main account")
        case .failed:
            return L10n.text("The last request did not get a reply")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(OrbitInk.aqua).accessibilityHidden(true)
                Text("Account map").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 2)
                if data.externallyManaged {
                    Label(enabled ? "Switching on" : "Switching off", systemImage: enabled ? "checkmark.circle.fill" : "pause.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(enabled ? OrbitInk.aqua : OrbitInk.quiet)
                        .identified("routing.managed-status")
                } else {
                    Text("Automatic switching").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.86))
                        .accessibilityHidden(true)
                    Toggle("Automatic switching", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .tint(Color(red: 0.15, green: 0.62, blue: 0.53))
                        .environment(\.colorScheme, .dark).disabled(!canSwitch)
                        .accessibilityLabel("Automatic switching").identified("routing.automatic")
                        .help("Let a backup answer when your main account runs out.")
                }
            }.padding(.horizontal, compact ? 15 : 20).padding(.vertical, 12)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            OrbitMap(signal: signal, hasBackup: data.accounts.count > 1)
                .frame(height: compact ? 124 : 152)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Account map").accessibilityValue(mapDescription)
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                if signal?.phase != .sending, let signal {
                    Label(mapDescription, systemImage: signal.phase == .failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(signal.phase == .failed ? OrbitInk.amber : OrbitInk.quiet)
                }
                Text(status.title)
                    .font(.system(size: compact ? 21 : 24, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(status.detail).font(.callout).foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? 15 : 20).padding(.vertical, 12)
                .background(.black.opacity(0.13))
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.085, green: 0.101, blue: 0.165),
                                            Color(red: 0.041, green: 0.068, blue: 0.112)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
    }
}

/// Only actual attempts animate along a branch. A request that completed between polls gets a brief, labeled trace.
private struct OrbitMap: View {
    let signal: RouteMapSignal?
    let hasBackup: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var traceBegan: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || (signal?.phase != .sending && traceBegan == nil))) { timeline in
            Canvas { context, size in
                let clock = timeline.date.timeIntervalSinceReferenceDate
                var pulse: Double?
                if !reduceMotion, let signal {
                    if signal.phase == .sending {
                        pulse = max(0, timeline.date.timeIntervalSince(signal.at)).truncatingRemainder(dividingBy: 2.4) / 2.4
                    } else if let began = traceBegan {
                        pulse = min(1, max(0, timeline.date.timeIntervalSince(began) / 1.5))
                    }
                }
                draw(context: context, size: size, pulse: pulse, angle: pulse == nil ? 0 : sin(clock * 0.22) * 0.12)
            }
        }
        .task(id: signal) {
            traceBegan = nil
            guard !reduceMotion, let signal, signal.phase == .answered,
                  abs(signal.at.timeIntervalSinceNow) < 4 else { return }
            traceBegan = Date()
            try? await Task.sleep(nanoseconds: 1_550_000_000)
            if !Task.isCancelled { traceBegan = nil }
        }
    }

    private func draw(context c: GraphicsContext, size: CGSize, pulse: Double?, angle: Double) {
        let w = size.width, h = size.height
        guard w > 30, h > 30 else { return }
        let compact = w < 430
        let center = CGPoint(x: 0.48*w, y: 0.45*h)
        let r = min(h*0.29, w*0.09)
        let left = CGPoint(x: w*0.12, y: h*0.45)
        let right = min(w*0.73, w - (compact ? 87 : 110))
        let main = CGPoint(x: right, y: h*0.29)
        let backup = CGPoint(x: right, y: h*0.68)
        let radius: CGFloat = compact ? 6 : 8
        let face = signal?.backup == true ? OrbitInk.amber : OrbitInk.aqua

        background(c, size: size, center: center, radius: r)
        let incoming = Curve(left, CGPoint(x: w*0.24, y: left.y), CGPoint(x: center.x-r*1.6, y: center.y+r*0.56), center)
        let front = Curve(center, CGPoint(x: center.x+r*1.65, y: center.y+r*0.18),
                          CGPoint(x: right-w*0.10, y: main.y), main)
        let back = Curve(center, CGPoint(x: center.x+r*1.3, y: center.y+r*0.38),
                         CGPoint(x: right-w*0.12, y: backup.y), backup)
        drawCable(c, incoming, color: OrbitInk.lavender, selected: signal != nil)
        drawCable(c, front, color: OrbitInk.aqua, selected: signal?.backup == false)
        drawCable(c, back, color: OrbitInk.amber, selected: signal?.backup == true,
                  dashed: !hasBackup && signal?.backup != true)

        globe(c, center: center, radius: r, angle: angle)
        node(c, at: left, color: OrbitInk.lavender, radius: radius, selected: true)
        node(c, at: main, color: OrbitInk.aqua, radius: radius * 0.77, selected: signal?.backup == false)
        node(c, at: backup, color: hasBackup ? OrbitInk.amber : OrbitInk.quiet, radius: radius * 0.77, selected: signal?.backup == true)
        if let pulse, pulse < 1 {
            let departing = pulse >= 0.45
            let curve = departing ? (signal?.backup == true ? back : front) : incoming
            let progress = departing ? (pulse - 0.45) / 0.55 : pulse / 0.45
            let tip = curve.point(progress)
            let color = departing ? face : OrbitInk.lavender
            for i in 1...6 {
                let t = max(0, progress - Double(i)*0.014)
                dot(c, curve.point(t), radius: 2.1-Double(i)*0.17, color: color.opacity(0.80-Double(i)*0.11))
            }
            glow(c, tip, radius: 10, color: color.opacity(0.62))
            dot(c, tip, radius: 2.5, color: .white)
        }

        let labelSize: CGFloat = compact ? 10 : 12
        caption(c, "Your request", at: CGPoint(x: left.x, y: left.y+radius+12), font: labelSize, anchor: .center)
        caption(c, "AI Switcher", at: CGPoint(x: center.x, y: center.y+r*1.18+8), font: labelSize, anchor: .center)
        caption(c, "Main account", at: CGPoint(x: right+radius+7, y: main.y), font: labelSize, anchor: .leading)
        caption(c, hasBackup ? "Backup" : "No backup", at: CGPoint(x: right+radius+7, y: backup.y),
                font: labelSize, anchor: .leading, muted: !hasBackup)
    }

    private func background(_ c: GraphicsContext, size: CGSize, center: CGPoint, radius: CGFloat) {
        let area = CGRect(origin: .zero, size: size)
        c.fill(Path(area), with: .radialGradient(Gradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.30),
                                                                    Color(red: 0.046, green: 0.062, blue: 0.104)]),
                                                  center: center, startRadius: 12, endRadius: size.width*0.55))
        let columns = Int(size.width / 15), rows = Int(size.height / 15)
        for x in 0...columns { for y in 0...rows {
            dot(c, CGPoint(x: 7+CGFloat(x)*15, y: 7+CGFloat(y)*15), radius: 0.7, color: .white.opacity(0.13))
        } }
        for i in 0..<4 {
            let size = CGSize(width: radius*(4.9+Double(i)*0.64), height: radius*(1.02+Double(i)*0.1))
            var tilted = c
            tilted.translateBy(x: center.x, y: center.y)
            tilted.rotate(by: .degrees(-16+Double(i)*3))
            let ellipse = Path(ellipseIn: CGRect(x: -size.width*0.5, y: -size.height*0.5, width: size.width, height: size.height))
            tilted.stroke(ellipse, with: .color(OrbitInk.lavender.opacity(i == 0 ? 0.28 : 0.12)), lineWidth: 0.7)
        }
    }

    /// A projected triangular sphere keeps the illustration sharp on Retina displays and at every window width.
    private func globe(_ c: GraphicsContext, center: CGPoint, radius r: CGFloat, angle: Double) {
        glow(c, center, radius: r*1.7, color: OrbitInk.aqua.opacity(0.22))
        let ball = Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2))
        c.fill(ball, with: .radialGradient(Gradient(colors: [Color(red: 0.20, green: 0.32, blue: 0.39),
                                                            Color(red: 0.043, green: 0.115, blue: 0.18)]),
                                            center: CGPoint(x: center.x-r*0.36, y: center.y-r*0.50), startRadius: 0, endRadius: r*1.4))
        func vertex(_ row: Int, _ col: Int) -> (CGPoint, Double) {
            let latitude = -.pi/2 + Double(row) * .pi/8
            let longitude = Double(col) * (.pi/8) + (row.isMultiple(of: 2) ? 0 : .pi/16) + angle + 0.31
            let x = cos(latitude)*cos(longitude), y = sin(latitude), z = cos(latitude)*sin(longitude)
            let tiltedY = y*0.974 - z*0.227, depth = y*0.227 + z*0.974
            return (CGPoint(x: center.x + r*(x*0.946-tiltedY*0.325),
                            y: center.y + r*(x*0.325+tiltedY*0.946)), depth)
        }
        func edge(_ a: (CGPoint, Double), _ b: (CGPoint, Double)) {
            guard a.1 > -0.05 && b.1 > -0.05 else { return }
            var line = Path(); line.move(to: a.0); line.addLine(to: b.0)
            c.stroke(line, with: .color(OrbitInk.aqua.opacity(0.18+0.35*(a.1+b.1)/2)), lineWidth: 0.65)
        }
        for row in 0..<8 { for col in 0..<16 {
            let a = vertex(row,col)
            edge(a,vertex(row,col+1)); edge(a,vertex(row+1,col))
            edge(a,vertex(row+1,col+(row.isMultiple(of: 2) ? -1 : 1)))
            if a.1 > 0.10 {
                let bright = (row * 7 + col * 3).isMultiple(of: 5)
                let fill = bright ? OrbitInk.amber : OrbitInk.aqua
                if bright { glow(c, a.0, radius: 4.4, color: fill.opacity(0.75)) }
                dot(c, a.0, radius: bright ? 1.7 : 0.86, color: fill.opacity(0.52+0.45*a.1))
            }
        } }
        c.stroke(ball, with: .color(OrbitInk.aqua.opacity(0.60)), lineWidth: 0.8)
    }

    private func node(_ c: GraphicsContext, at p: CGPoint, color: Color, radius r: CGFloat, selected: Bool) {
        if selected { glow(c, p, radius: r*2.5, color: color.opacity(0.47)) }
        let box = CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)
        c.fill(Path(ellipseIn: box), with: .color(Color(red: 0.06, green: 0.09, blue: 0.13)))
        c.stroke(Path(ellipseIn: box), with: .color(color.opacity(selected ? 1 : 0.65)), lineWidth: selected ? 1.65 : 1)
        dot(c, p, radius: selected ? r*0.46 : r*0.27, color: color)
    }

    private func drawCable(_ c: GraphicsContext, _ curve: Curve, color: Color, selected: Bool, dashed: Bool = false) {
        var path = Path(); path.move(to: curve.a); path.addCurve(to: curve.d, control1: curve.b, control2: curve.c)
        if selected { c.stroke(path, with: .color(color.opacity(0.09)), lineWidth: 6.5) }
        c.stroke(path, with: .color(color.opacity(selected ? 0.94 : (dashed ? 0.24 : 0.55))),
                 style: StrokeStyle(lineWidth: selected ? 1.8 : 1.03, lineCap: .round, dash: dashed ? [3,4] : []))
    }

    private func caption(_ c: GraphicsContext, _ key: String, at p: CGPoint, font: CGFloat, anchor: UnitPoint, muted: Bool = false) {
        let text = Text(L10n.text(key)).font(.system(size: font, weight: .semibold))
            .foregroundColor(muted ? OrbitInk.quiet : .white)
        c.draw(text, at: p, anchor: anchor)
    }

    private func dot(_ c: GraphicsContext, _ p: CGPoint, radius r: CGFloat, color: Color) {
        c.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)), with: .color(color))
    }

    private func glow(_ c: GraphicsContext, _ p: CGPoint, radius r: CGFloat, color: Color) {
        let circle = Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2))
        c.fill(circle, with: .radialGradient(Gradient(colors: [color, .clear]), center: p, startRadius: 0, endRadius: r))
    }

    private struct Curve {
        let a, b, c, d: CGPoint
        init(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) { self.a=a; self.b=b; self.c=c; self.d=d }
        func point(_ t: Double) -> CGPoint {
            let u = 1-t, aa = u*u*u, bb = 3*u*u*t, cc = 3*u*t*t, dd = t*t*t
            return CGPoint(x: a.x*aa+b.x*bb+c.x*cc+d.x*dd, y: a.y*aa+b.y*bb+c.y*cc+d.y*dd)
        }
    }
}
