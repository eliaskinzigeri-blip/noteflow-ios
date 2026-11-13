import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NoteFlowLiveBundle: WidgetBundle {
    var body: some Widget {
        RoutineLive()
        NextWidget()
    }
}

/// Couleurs de NoteFlow : noir, blanc et rouge braise (#e7000b)
enum NF {
    static let red = Color(red: 0.906, green: 0, blue: 0.043)
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let soft = Color.white.opacity(0.62)
}

/// Activité en direct de la routine : écran verrouillé et Dynamic Island.
struct RoutineLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoutineAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(NF.ink.opacity(0.9))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(navTitle(s), systemImage: icon(s.kind))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: s, font: .headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.travel {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(arrival(s)).font(.caption).foregroundStyle(NF.soft).lineLimit(1)
                            Track(progress: s.progress ?? 0, kind: s.kind)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(NF.soft).lineLimit(1) }
                            if !s.next.isEmpty { Text(s.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(1) }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: icon(s.kind)).foregroundStyle(NF.red)
            } compactTrailing: {
                Countdown(state: s, font: .caption2.weight(.semibold), compact: true)
            } minimal: {
                Image(systemName: icon(s.kind)).foregroundStyle(NF.red)
            }
        }
    }
}

/// Icône de l'étape (bus, marche, attente, cours, routine…).
func icon(_ kind: String) -> String {
    switch kind {
    case "bus": return "bus.fill"
    case "walk": return "figure.walk"
    case "wait": return "clock"
    case "lesson": return "book.fill"
    case "sport", "move": return "figure.run"
    case "session": return "basketball.fill"
    case "bag": return "backpack.fill"
    case "dinner", "breakfast": return "fork.knife"
    case "shower": return "shower.fill"
    case "teeth": return "mouth"
    case "sleep": return "moon.zzz.fill"
    case "free": return "sparkles"
    case "dress": return "tshirt.fill"
    default: return "checklist"
    }
}

/// Distance lisible : « 350 m », « 3,2 km »
func distance(_ m: Double) -> String {
    m < 950 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
}

private func hm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%dh%02d", c.hour ?? 0, c.minute ?? 0)
}

/// Titre d'un trajet, comme un GPS : « À pied · 350 m », « Bus 876S · 4,1 km », « Attente du bus »
func navTitle(_ s: RoutineAttributes.ContentState) -> String {
    guard s.travel else { return s.title }
    let dist = s.meters.map { " · \(distance($0))" } ?? ""
    switch s.kind {
    case "walk": return "À pied\(dist)"
    case "bus": return "\(s.title)\(dist)"
    case "wait": return "Attente du bus"
    default: return "\(s.title)\(dist)"
    }
}

/// « Arrivée à 8h20 · Place » (attente : « Bus à 8h20 · Place »)
func arrival(_ s: RoutineAttributes.ContentState) -> String {
    let at = hm(s.eta ?? s.end)
    let place = (s.dest ?? "").isEmpty ? "" : " · \(s.dest!)"
    return s.kind == "wait" ? "Bus à \(at)\(place)" : "Arrivée à \(at)\(place)"
}

/// Compte à rebours sur une seule ligne : « arrivée dans 2:26 » en trajet, temps restant sinon.
struct Countdown: View {
    let state: RoutineAttributes.ContentState
    var font: Font = .title3.weight(.bold)
    var compact = false

    var body: some View {
        let end = state.travel ? (state.eta ?? state.end) : state.end
        let from = min(Date(), end)
        let long = end.timeIntervalSince(from) >= 3600
        let width: CGFloat = compact ? (long ? 56 : 40) : (long ? 92 : 64)
        Text(timerInterval: from...end, countsDown: true)
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
            .foregroundStyle(state.travel ? NF.red : .white)
    }
}

/// Barre d'avancement façon GPS : trajet fait en rouge, toi (flèche), destination (rond)
struct Track: View {
    let progress: Double
    let kind: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = 9 + (w - 18) * CGFloat(min(max(progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 6)
                Capsule().fill(NF.red).frame(width: max(x, 6), height: 6)
                Circle().stroke(Color.white, lineWidth: 3).background(Circle().fill(NF.ink))
                    .frame(width: 13, height: 13).position(x: w - 7, y: 9)
                ZStack {
                    Circle().fill(NF.red)
                    Circle().stroke(Color.white, lineWidth: 2.5)
                    Image(systemName: kind == "bus" ? "bus.fill" : kind == "wait" ? "clock.fill" : "location.north.fill")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(kind == "walk" ? .degrees(90) : .zero)
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                .position(x: x, y: 9)
            }
        }
        .frame(height: 20)
    }
}

struct LockScreenView: View {
    let state: RoutineAttributes.ContentState

    var body: some View {
        if state.travel { travel } else { step }
    }

    /// Trajet : comme un GPS, avec la mini-carte
    private var travel: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(state.kind))
                    Text(navTitle(state)).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(arrival(state)).font(.caption).foregroundStyle(NF.soft).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(state.kind == "wait" ? "dans" : "arrivée dans").font(.caption2).foregroundStyle(NF.soft)
                    Countdown(state: state)
                }
                Track(progress: state.progress ?? 0, kind: state.kind)
                if !state.next.isEmpty {
                    Text(state.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(1)
                }
            }
            if !state.path.isEmpty {
                MiniMap(path: state.path, me: state.me).frame(width: 84, height: 84)
            }
        }
        .foregroundStyle(.white)
    }

    /// Étape, séance, temps libre ou nuit
    private var step: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: icon(state.kind)).foregroundStyle(state.kind == "session" ? NF.red : .white)
                Text(state.title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Countdown(state: state, font: .subheadline.weight(.semibold))
            }
            if !state.detail.isEmpty {
                Text(state.detail).font(.caption).foregroundStyle(NF.soft).lineLimit(2)
            }
            ProgressView(timerInterval: min(state.start, Date())...state.end, countsDown: false,
                         label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .tint(NF.red)
            if !state.next.isEmpty {
                Text(state.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Mini-carte du trajet : le tracé, le départ (point plein), l'arrivée (rond) et ta position (point rouge).
struct MiniMap: View {
    let path: [MapPoint]
    let me: MapPoint?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = path.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
                Path { line in
                    guard let first = pts.first else { return }
                    line.move(to: first)
                    for p in pts.dropFirst() { line.addLine(to: p) }
                }
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let first = pts.first {
                    Circle().fill(Color.white).frame(width: 7, height: 7).position(first)
                }
                if let end = pts.last, pts.count > 1 {
                    Circle().stroke(Color.white, lineWidth: 2).frame(width: 11, height: 11).position(end)
                }
                if let m = me {
                    Circle().fill(NF.red)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: m.x * w, y: m.y * h)
                }
            }
        }
    }
}
