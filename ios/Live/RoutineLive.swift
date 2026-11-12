import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NoteFlowLiveBundle: WidgetBundle {
    var body: some Widget {
        RoutineLive()
    }
}

/// Activité en direct de la routine : écran verrouillé et Dynamic Island.
struct RoutineLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoutineAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: icon(context.state.kind))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            if !context.state.detail.isEmpty {
                                Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if !context.state.next.isEmpty {
                                Text(context.state.next).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if context.state.travel && !context.state.path.isEmpty {
                            MiniMap(path: context.state.path, me: context.state.me).frame(width: 74, height: 74)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context.state.kind))
            } compactTrailing: {
                Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: icon(context.state.kind))
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
    case "bag": return "backpack.fill"
    case "dinner", "breakfast": return "fork.knife"
    case "shower": return "shower.fill"
    case "teeth": return "mouth"
    case "dress": return "tshirt.fill"
    default: return "checklist"
    }
}

struct LockScreenView: View {
    let state: RoutineAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: icon(state.kind))
                    Text(state.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timerInterval: state.start...state.end, countsDown: true)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                if !state.detail.isEmpty {
                    Text(state.detail).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                ProgressView(timerInterval: state.start...state.end, countsDown: false,
                             label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .tint(.white)
                if !state.next.isEmpty {
                    Text(state.next).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            if state.travel && !state.path.isEmpty {
                MiniMap(path: state.path, me: state.me).frame(width: 88, height: 88)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Mini-carte du trajet : le tracé, le départ (point plein), l'arrivée (rond) et ta position (point bleu).
struct MiniMap: View {
    let path: [MapPoint]
    let me: MapPoint?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = path.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))
                Path { line in
                    guard let first = pts.first else { return }
                    line.move(to: first)
                    for p in pts.dropFirst() { line.addLine(to: p) }
                }
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let first = pts.first {
                    Circle().fill(Color.white).frame(width: 7, height: 7).position(first)
                }
                if let end = pts.last, pts.count > 1 {
                    Circle().stroke(Color.white, lineWidth: 2).frame(width: 11, height: 11).position(end)
                }
                if let m = me {
                    Circle().fill(Color.blue)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: m.x * w, y: m.y * h)
                }
            }
        }
    }
}
