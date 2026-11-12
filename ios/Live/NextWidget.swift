import SwiftUI
import WidgetKit

/// Une étape du planning telle que le widget l'affiche
struct WidgetStep: Hashable {
    let label: String
    let detail: String
    let kind: String
    let start: Date
    let end: Date
}

struct NextEntry: TimelineEntry {
    let date: Date
    let current: WidgetStep?
    let next: WidgetStep?
}

/// Planning lu dans le stockage partagé (écrit par l'app à chaque envoi du site) ; une entrée par début d'étape.
struct NextProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEntry {
        let now = Date()
        return NextEntry(date: now,
                         current: WidgetStep(label: "Mathématiques", detail: "Salle 12", kind: "lesson", start: now, end: now.addingTimeInterval(3300)),
                         next: WidgetStep(label: "Français", detail: "", kind: "lesson", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(6900)))
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
        completion(entries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        let list = entries()
        let refresh = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
        completion(Timeline(entries: list.isEmpty ? [NextEntry(date: Date(), current: nil, next: nil)] : list, policy: .after(refresh)))
    }

    private func steps() -> [WidgetStep] {
        guard let data = SharedStore.defaults.data(forKey: "plan"),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return [] }
        return plan.days.flatMap { day -> [WidgetStep] in
            guard let midnight = PlanClock.midnight(day.day) else { return [] }
            return day.steps.filter { !($0.kind == "sleep" && $0.label == "Sommeil") }.map {
                WidgetStep(label: $0.label, detail: $0.detail, kind: $0.kind,
                           start: midnight.addingTimeInterval($0.start * 60), end: midnight.addingTimeInterval(max($0.end, $0.start + 1) * 60))
            }
        }.sorted { $0.start < $1.start }
    }

    private func entries() -> [NextEntry] {
        let all = steps()
        let now = Date()
        var out: [NextEntry] = []
        // Maintenant, puis à chaque début d'étape à venir
        var moments = [now] + all.map(\.start).filter { $0 > now }
        moments = Array(moments.prefix(40))
        for t in moments {
            let cur = all.last { $0.start <= t && t < $0.end }
            let next = all.first { $0.start > t && $0.start >= (cur?.end ?? t).addingTimeInterval(-30) }
            out.append(NextEntry(date: t, current: cur, next: next))
        }
        return out
    }
}

struct NextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NoteFlowNext", provider: NextProvider()) { entry in
            NextWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.11, green: 0.11, blue: 0.13) }
        }
        .configurationDisplayName("Prochaine étape")
        .description("L’étape de ta routine en cours et la suivante.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

private func hm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%dh%02d", c.hour ?? 0, c.minute ?? 0)
}

struct NextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let s = entry.current ?? entry.next { Text("\(hm(s.start)) · \(s.label)") } else { Text("NoteFlow") }
        case .accessoryCircular:
            if let s = entry.current {
                ProgressView(timerInterval: s.start...s.end, countsDown: true) { Image(systemName: icon(s.kind)) }
                    .progressViewStyle(.circular)
            } else {
                Image(systemName: "checklist")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let s = entry.current {
                    Label(s.label, systemImage: icon(s.kind)).font(.headline).lineLimit(1)
                    Text("jusqu’à \(hm(s.end))").font(.caption)
                }
                if let n = entry.next { Text("\(hm(n.start)) \(n.label)").font(.caption).lineLimit(1) }
                if entry.current == nil && entry.next == nil { Text("Ouvre NoteFlow").font(.caption) }
            }
        default:
            box
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = entry.current {
                HStack(spacing: 6) {
                    Image(systemName: icon(s.kind))
                    Text(s.label).font(.headline).lineLimit(2)
                }
                if !s.detail.isEmpty && family == .systemMedium { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(timerInterval: s.start...s.end, countsDown: true)
                    .font(.title3.weight(.semibold)).monospacedDigit()
            } else if entry.next == nil {
                Text("Ouvre NoteFlow pour charger ta routine").font(.callout)
            }
            Spacer(minLength: 0)
            if let n = entry.next {
                Text("Ensuite à \(hm(n.start))").font(.caption2).foregroundStyle(.secondary)
                Label(n.label, systemImage: icon(n.kind)).font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
