import AppIntents
import Foundation

// Questions à Siri sur la routine NoteFlow (App Intents : dans l'app, aucun identifiant d'app en plus).
// « Dis Siri, à quelle heure je me couche demain avec NoteFlow », « NoteFlow j'ai quoi comme devoirs »…
// Les réponses viennent du planning enregistré par l'app (la semaine qui vient) et des devoirs du dernier relevé.

/// Jour demandé : aujourd'hui, demain ou un jour de la semaine (le prochain, ou aujourd'hui si c'est ce jour-là)
enum DayChoice: String, AppEnum {
    case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Jour"
    static let caseDisplayRepresentations: [DayChoice: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "aujourd’hui", synonyms: ["ce soir", "ce matin", "aujourd'hui"]),
        .tomorrow: DisplayRepresentation(title: "demain", synonyms: ["demain matin", "demain soir"]),
        .monday: "lundi", .tuesday: "mardi", .wednesday: "mercredi", .thursday: "jeudi",
        .friday: "vendredi", .saturday: "samedi", .sunday: "dimanche",
    ]

    func date(_ now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday: Int  // Calendar : 1 = dimanche
        switch self {
        case .today: return today
        case .tomorrow: return cal.date(byAdding: .day, value: 1, to: today) ?? today
        case .sunday: weekday = 1
        case .monday: weekday = 2
        case .tuesday: weekday = 3
        case .wednesday: weekday = 4
        case .thursday: weekday = 5
        case .friday: weekday = 6
        case .saturday: weekday = 7
        }
        let diff = (weekday - cal.component(.weekday, from: today) + 7) % 7
        return cal.date(byAdding: .day, value: diff, to: today) ?? today
    }
}

enum Answers {
    /// Jour du planning et sa façon d'en parler (« Demain », « Jeudi », « Aujourd’hui »)
    private static func find(_ choice: DayChoice) -> (PlanDay?, String, Date) {
        let now = Date()
        let date = choice.date(now)
        let cal = Calendar.current
        let name = cal.isDateInToday(date) ? "Aujourd’hui" : cal.isDateInTomorrow(date) ? "Demain" : DayInfo.weekday(date).capitalized
        let key = PlanClock.dayFormat.string(from: date)
        return (DayInfo.plan?.days.first { $0.day == key }, name, date)
    }

    private static func unknown(_ name: String) -> String {
        "Je ne connais pas encore ton planning de \(name == "Aujourd’hui" ? "la journée" : name.lowercased()) : ouvre NoteFlow pour le mettre à jour."
    }

    static func bed(_ choice: DayChoice) -> String {
        let (day, name, date) = find(choice)
        guard let day, let bed = day.bed else { return unknown(name) }
        let when = name == "Aujourd’hui" ? "Ce soir" : name == "Demain" ? "Demain soir" : "\(name) soir"
        var text = "\(when), couche-toi à \(PlanClock.clock(bed))"
        let next = PlanClock.dayFormat.string(from: date.addingTimeInterval(36 * 3600))
        if let wake = DayInfo.plan?.days.first(where: { $0.day == next })?.wake {
            text += " pour te réveiller à \(PlanClock.clock(wake))"
        }
        return text + "."
    }

    static func wake(_ choice: DayChoice) -> String {
        let (day, name, _) = find(choice)
        guard let day else { return unknown(name) }
        guard let wake = day.wake else { return "\(name), pas de réveil prévu." }
        var text = "\(name), réveil à \(PlanClock.clock(wake))"
        if let first = day.steps.filter({ $0.kind == "lesson" }).map(\.start).min() {
            text += ", premier cours à \(PlanClock.clock(first))"
        } else if day.school != true {
            text += ", pas de cours"
        }
        return text + "."
    }

    static func leave(_ choice: DayChoice) -> String {
        let (day, name, _) = find(choice)
        guard let day else { return unknown(name) }
        guard let trip = DayInfo.trip(day) else { return "\(name), pas de trajet prévu." }
        var text = "\(name), pars à \(PlanClock.clock(trip.first.start))"
        if let bus = trip.bus {
            let stop = bus.detail.components(separatedBy: "→").first?.trimmingCharacters(in: .whitespaces) ?? ""
            text += " pour le \(bus.label.lowercased()) de \(PlanClock.clock(bus.start))\(stop.isEmpty ? "" : " à \(stop)")"
        }
        return text + ", arrivée à \(PlanClock.clock(trip.last.end))."
    }

    static func bag(_ choice: DayChoice) -> String {
        let (day, name, _) = find(choice)
        guard let day else { return unknown(name) }
        guard let found = DayInfo.bag(day, now: Date()) else { return "\(name), pas de cours : rien à préparer." }
        var parts = found.lines
        if let first = parts.first, let colon = first.range(of: " : ") {
            parts[0] = "\(name), prends tes affaires de " + first[colon.upperBound...].replacingOccurrences(of: " · ", with: ", ")
        }
        if let weather = found.weather { parts.append(weather) }
        return parts.map { $0.replacingOccurrences(of: " · ", with: ", ") }.joined(separator: ". ") + "."
    }

    static func homework() -> String {
        guard Inbox.shared.linked else { return "Je ne vois pas encore tes devoirs : ouvre NoteFlow connecté à ton compte." }
        let today = PlanClock.dayFormat.string(from: Date())
        let list = Inbox.shared.work.homework.filter { $0.due >= today }.sorted { $0.due < $1.due }
        guard !list.isEmpty else { return "Tu n’as aucun devoir à rendre pour l’instant." }
        let tomorrow = PlanClock.dayFormat.string(from: Date().addingTimeInterval(86400))
        var parts: [String] = []
        for due in Array(Set(list.map(\.due))).sorted().prefix(4) {
            let items = list.filter { $0.due == due }.prefix(4).map { $0.text.isEmpty ? $0.subject : "\($0.subject) : \($0.text)" }
            let when = due == today ? "Pour aujourd’hui" : due == tomorrow ? "Pour demain" : "Pour \(PlanClock.midnight(due).map(DayInfo.weekday) ?? due)"
            parts.append("\(when), \(items.joined(separator: " ; "))")
        }
        return parts.joined(separator: ". ") + "."
    }
}

struct BedtimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Heure du coucher"
    static let description = IntentDescription("À quelle heure te coucher, d’après ta routine NoteFlow.")
    @Parameter(title: "Jour", default: .today) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.bed(day))")
    }
}

struct WakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Heure du réveil"
    static let description = IntentDescription("À quelle heure tu te réveilles, d’après ta routine NoteFlow.")
    @Parameter(title: "Jour", default: .tomorrow) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.wake(day))")
    }
}

struct LeaveIntent: AppIntent {
    static let title: LocalizedStringResource = "Heure de départ"
    static let description = IntentDescription("À quelle heure partir de la maison, et quel bus prendre.")
    @Parameter(title: "Jour", default: .tomorrow) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.leave(day))")
    }
}

struct BagIntent: AppIntent {
    static let title: LocalizedStringResource = "Sac pour demain"
    static let description = IntentDescription("Les affaires à prendre : cours, devoirs à rendre, évaluations et météo.")
    @Parameter(title: "Jour", default: .tomorrow) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.bag(day))")
    }
}

struct HomeworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Mes devoirs"
    static let description = IntentDescription("Les devoirs à rendre ces prochains jours.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.homework())")
    }
}

/// Phrases de Siri (le nom de l'app doit y être) ; elles apparaissent aussi dans l'app Raccourcis.
struct NoteFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BedtimeIntent(), phrases: [
            "À quelle heure je me couche avec \(.applicationName)",
            "À quelle heure je me couche \(\.$day) avec \(.applicationName)",
            "\(.applicationName) je me couche à quelle heure",
            "\(.applicationName) je me couche à quelle heure \(\.$day)",
            "\(.applicationName) heure du coucher \(\.$day)",
        ], shortTitle: "Heure du coucher", systemImageName: "bed.double.fill")
        AppShortcut(intent: WakeIntent(), phrases: [
            "À quelle heure je me réveille avec \(.applicationName)",
            "À quelle heure je me réveille \(\.$day) avec \(.applicationName)",
            "\(.applicationName) je me réveille à quelle heure",
            "\(.applicationName) je me réveille à quelle heure \(\.$day)",
            "\(.applicationName) réveil \(\.$day)",
        ], shortTitle: "Heure du réveil", systemImageName: "alarm.fill")
        AppShortcut(intent: LeaveIntent(), phrases: [
            "À quelle heure je pars avec \(.applicationName)",
            "À quelle heure je pars \(\.$day) avec \(.applicationName)",
            "\(.applicationName) je pars à quelle heure",
            "\(.applicationName) je pars à quelle heure \(\.$day)",
        ], shortTitle: "Heure de départ", systemImageName: "figure.walk")
        AppShortcut(intent: BagIntent(), phrases: [
            "Qu'est-ce que je dois prendre pour demain avec \(.applicationName)",
            "\(.applicationName) faut prendre quoi pour demain",
            "\(.applicationName) je prends quoi pour demain",
            "\(.applicationName) mon sac pour demain",
            "\(.applicationName) faut prendre quoi \(\.$day)",
        ], shortTitle: "Sac pour demain", systemImageName: "backpack.fill")
        AppShortcut(intent: HomeworkIntent(), phrases: [
            "Qu'est-ce que j'ai comme devoirs avec \(.applicationName)",
            "\(.applicationName) j'ai quoi comme devoirs",
            "\(.applicationName) mes devoirs",
        ], shortTitle: "Mes devoirs", systemImageName: "checklist")
    }
}
