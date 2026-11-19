import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NoteFlowLiveBundle: WidgetBundle {
    var body: some Widget {
        RoutineLive()
        NextWidget()
        if #available(iOS 18.0, *) {
            NextLessonControl()
            NotesControl()
            TasksControl()
            FocusControl()
        }
    }
}

/// Couleurs de NoteFlow : noir et blanc
enum NF {
    static let accent = Color.white
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
                            if let line = s.lines?.first { Text(line).font(.caption).lineLimit(1) }
                            else if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(NF.soft).lineLimit(1) }
                            if !s.next.isEmpty { Text(s.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(1) }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: icon(s.kind)).foregroundStyle(NF.accent)
            } compactTrailing: {
                Countdown(state: s, font: .caption2.weight(.semibold), compact: true)
            } minimal: {
                Image(systemName: icon(s.kind)).foregroundStyle(NF.accent)
            }
        }
    }
}

/// Icône de l'étape (bus, marche, attente, cours, routine…).
func icon(_ kind: String) -> String {
    switch kind {
    case "bus": return "bus.fill"
    case "walk": return "figure.walk"
    case "wait", "pause": return "clock"
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
    case "pause": return "En attente"
    default: return "\(s.title.isEmpty ? "En route" : s.title)\(dist)"
    }
}

/// « Arrivée à 8h20 · Place » (attente : « Bus à 8h20 · Place », pause : « Si tu repars, arrivée à 8h20 »)
func arrival(_ s: RoutineAttributes.ContentState) -> String {
    let at = hm(s.eta ?? s.end)
    let place = (s.dest ?? "").isEmpty ? "" : " · \(s.dest!)"
    switch s.kind {
    case "wait": return s.detail.isEmpty ? "Bus à \(at)\(place)" : "\(s.detail)\(place)"
    case "pause": return "Si tu repars, arrivée à \(at)\(place)"
    default: return "Arrivée à \(at)\(place)"
    }
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
            .foregroundStyle(state.travel ? NF.accent : .white)
    }
}

/// Barre d'avancement façon GPS : trajet fait en blanc, toi (flèche), destination (rond)
struct Track: View {
    let progress: Double
    let kind: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = 9 + (w - 18) * CGFloat(min(max(progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 6)
                Capsule().fill(NF.accent).frame(width: max(x, 6), height: 6)
                Circle().stroke(Color.white, lineWidth: 3).background(Circle().fill(NF.ink))
                    .frame(width: 13, height: 13).position(x: w - 7, y: 9)
                ZStack {
                    Circle().fill(Color.white)
                    Circle().stroke(NF.ink, lineWidth: 2.5)
                    Image(systemName: kind == "bus" ? "bus.fill" : kind == "wait" || kind == "pause" ? "clock.fill" : "location.north.fill")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(kind == "walk" ? .degrees(90) : .zero)
                        .foregroundStyle(NF.ink)
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

    /// Trajet : comme un GPS, avec à droite ce que tu fais (marche, bus ou horloge pour l'attente)
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
                    Text(state.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(2)
                }
            }
            ModeBadge(kind: state.kind).frame(width: 74)
        }
        .foregroundStyle(.white)
    }

    /// Étape, séance, temps libre ou nuit (avec le sac du lendemain et la météo du trajet quand il y en a)
    private var step: some View {
        let lines = Array((state.lines ?? []).prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: icon(state.kind)).foregroundStyle(state.kind == "session" ? NF.accent : .white)
                Text(state.title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Countdown(state: state, font: .subheadline.weight(.semibold))
            }
            if !lines.isEmpty {
                // Sac : cours, devoirs, évaluations (à la place du détail et de la barre)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).lineLimit(1)
                }
            } else {
                if !state.detail.isEmpty {
                    Text(state.detail).font(.caption).foregroundStyle(NF.soft).lineLimit(2)
                }
                ProgressView(timerInterval: min(state.start, Date())...state.end, countsDown: false,
                             label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .tint(NF.accent)
            }
            if let weather = state.weather, !weather.isEmpty {
                Label(weather, systemImage: weatherIcon(weather))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            if !state.next.isEmpty {
                Text(state.next).font(.caption2).foregroundStyle(NF.soft).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Icône de la météo d'après son résumé
func weatherIcon(_ text: String) -> String {
    if text.contains("Neige") { return "cloud.snow.fill" }
    if text.contains("Pluie") { return "cloud.rain.fill" }
    if text.contains("Froid") { return "thermometer.snowflake" }
    return "sun.max.fill"
}

/// Indicateur du trajet, deviné avec ta vitesse : un marcheur à pied, un bus en bus, une horloge en attente.
struct ModeBadge: View {
    let kind: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white)
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(NF.ink)
            }
            .frame(width: 58, height: 58)
            Text(word)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NF.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var symbol: String {
        switch kind {
        case "bus": return "bus.fill"
        case "walk": return "figure.walk"
        default: return "clock.fill"
        }
    }

    private var word: String {
        switch kind {
        case "bus": return "En bus"
        case "walk": return "À pied"
        default: return "Attente"
        }
    }
}
