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
    static func findDay(_ choice: DayChoice) -> (PlanDay?, String, Date) { find(choice) }

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

extension Answers {
    private static func fr(_ x: Double) -> String {
        let r = (x * 100).rounded() / 100
        return (r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r).replacingOccurrences(of: "0$", with: "", options: .regularExpression))
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Cours d'un jour avec leur salle
    private static func lessons(_ day: PlanDay) -> [PlanStep] {
        day.steps.filter { $0.kind == "lesson" }.sorted { $0.start < $1.start }
    }

    private static func room(_ s: PlanStep) -> String {
        let r = s.detail.components(separatedBy: " · ").first ?? ""
        return r.isEmpty ? "" : " en \(r.lowercased().hasPrefix("salle") ? r : "salle \(r)")"
    }

    static func nextLesson() -> String {
        let now = Date()
        for day in DayInfo.plan?.days ?? [] {
            guard let midnight = PlanClock.midnight(day.day) else { continue }
            let list = lessons(day)
            let at = { (m: Double) in midnight.addingTimeInterval(m * 60) }
            if let cur = list.first(where: { at($0.start) <= now && now < at($0.end) }) {
                var text = "Tu es en \(cur.label) jusqu’à \(PlanClock.clock(cur.end))"
                if let n = list.first(where: { $0.start >= cur.end }) { text += ". Ensuite : \(n.label) à \(PlanClock.clock(n.start))\(room(n))" }
                return text + "."
            }
            if let n = list.first(where: { at($0.start) > now }) {
                let mins = Int(at(n.start).timeIntervalSince(now) / 60)
                let today = Calendar.current.isDate(midnight, inSameDayAs: now)
                let when = today ? (mins < 90 ? "dans \(mins) minutes" : "à \(PlanClock.clock(n.start))")
                    : Calendar.current.isDateInTomorrow(midnight) ? "demain à \(PlanClock.clock(n.start))" : "\(DayInfo.weekday(midnight)) à \(PlanClock.clock(n.start))"
                return "Ton prochain cours : \(n.label) \(when)\(room(n))."
            }
        }
        return "Je ne vois pas de cours à venir : ouvre NoteFlow pour mettre ton emploi du temps à jour."
    }

    static func day(_ choice: DayChoice) -> String {
        let (day, name, _) = findDay(choice)
        guard let day else { return "Je ne connais pas encore ton planning de ce jour-là : ouvre NoteFlow pour le mettre à jour." }
        let list = lessons(day)
        guard let first = list.first, let last = list.last else { return "\(name), pas de cours." }
        let items = list.map { "\(PlanClock.clock($0.start)) \($0.label)" }
        return "\(name), \(list.count) cours : \(items.joined(separator: ", ")). Tu commences à \(PlanClock.clock(first.start)) et tu finis à \(PlanClock.clock(last.end))."
    }

    static func evals() -> String {
        guard Inbox.shared.linked else { return "Je ne vois pas encore tes évaluations : ouvre NoteFlow connecté à ton compte." }
        let today = PlanClock.dayFormat.string(from: Date())
        let list = Inbox.shared.work.evals.filter { $0.due >= today }.sorted { $0.due < $1.due }
        guard !list.isEmpty else { return "Aucune évaluation prévue pour l’instant." }
        let tomorrow = PlanClock.dayFormat.string(from: Date().addingTimeInterval(86400))
        let items = list.prefix(5).map { e -> String in
            let when = e.due == today ? "aujourd’hui" : e.due == tomorrow ? "demain" : (PlanClock.midnight(e.due).map(DayInfo.weekday) ?? e.due)
            return e.text.isEmpty ? "\(e.subject) \(when)" : "\(e.subject) \(when) (\(e.text))"
        }
        return "Prochaines évaluations : \(items.joined(separator: " ; "))."
    }

    static func grades(_ subject: SubjectEntity?) -> String {
        guard let g = Grades.saved else { return "Je n’ai pas encore tes notes : ouvre NoteFlow connecté à ton compte." }
        let note = { (r: Grades.Recent) -> String in
            let v = r.value.map { "\(fr($0)) sur \(fr(r.out ?? 20))" } ?? (r.raw ?? "")
            return "\(v) en \(r.subject)"
        }
        if let subject, let s = g.subjects.first(where: { $0.name == subject.id }) {
            var text = "En \(s.name), ta moyenne est de \(fr(s.avg))"
            if let c = s.cls { text += ", la classe a \(fr(c))" }
            let short = s.short ?? s.name
            if let r = g.recent.first(where: { $0.subject == short || $0.subject == s.name }) {
                text += ". Dernière note : \(note(r))"
            }
            return text + "."
        }
        var text = g.general.map { "Ta moyenne générale est de \(fr($0))." } ?? ""
        let sorted = g.subjects.sorted { $0.avg > $1.avg }
        if let best = sorted.first, let low = sorted.last, sorted.count > 1 {
            text += " Meilleure matière : \(best.name) avec \(fr(best.avg)). À travailler : \(low.name) avec \(fr(low.avg))."
        }
        if !g.recent.isEmpty { text += " Dernières notes : " + g.recent.prefix(3).map(note).joined(separator: ", ") + "." }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func bus() -> String {
        let now = Date()
        for day in DayInfo.plan?.days ?? [] {
            guard let midnight = PlanClock.midnight(day.day) else { continue }
            let at = { (m: Double) in midnight.addingTimeInterval(m * 60) }
            for b in day.steps.filter({ $0.kind == "bus" }).sorted(by: { $0.start < $1.start }) {
                let runs = [b.start] + (b.later ?? []).map(\.dep).filter { $0 > b.start }
                guard let dep = runs.first(where: { at($0) > now.addingTimeInterval(-60) }) else { continue }
                let stop = b.detail.components(separatedBy: "→").first?.trimmingCharacters(in: .whitespaces) ?? ""
                let mins = Int(at(dep).timeIntervalSince(now) / 60)
                let today = Calendar.current.isDate(midnight, inSameDayAs: now)
                let when = today ? (mins < 60 ? "dans \(max(mins, 0)) minutes, à \(PlanClock.clock(dep))" : "à \(PlanClock.clock(dep))")
                    : Calendar.current.isDateInTomorrow(midnight) ? "demain à \(PlanClock.clock(dep))" : "\(DayInfo.weekday(midnight)) à \(PlanClock.clock(dep))"
                var text = "Ton \(b.label.lowercased()) passe \(when)\(stop.isEmpty ? "" : " à \(stop)")"
                if let next = runs.first(where: { $0 > dep }) { text += ". Le suivant : \(PlanClock.clock(next))" }
                return text + "."
            }
        }
        return "Pas de bus prévu dans ton planning."
    }
}

/// Menus de la cantine, envoyés par le site (lus par l'IA dans les informations Pronote)
struct Menu: Codable {
    struct Day: Codable { let date: String; let meals: [String] }
    let days: [Day]

    static var saved: Menu? {
        UserDefaults.standard.data(forKey: "menu").flatMap { try? JSONDecoder().decode(Menu.self, from: $0) }
    }
}

extension Answers {
    static func menu(_ choice: DayChoice) -> String {
        let (_, name, date) = findDay(choice)
        let key = PlanClock.dayFormat.string(from: date)
        let when = name == "Aujourd’hui" ? "Aujourd’hui" : name
        if let day = Menu.saved?.days.first(where: { $0.date == key }) {
            return "\(when) à la cantine : \(day.meals.joined(separator: ", "))."
        }
        let weekday = Calendar.current.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return "\(when), pas de cantine." }
        if Menu.saved == nil { return "Je n’ai pas encore les menus de la cantine : ouvre NoteFlow connecté, je les cherche sur Pronote." }
        return "Je n’ai pas trouvé le menu de \(when.lowercased()) : il n’est peut-être pas encore publié sur Pronote."
    }
}

struct MenuIntent: AppIntent {
    static let title: LocalizedStringResource = "Menu de la cantine"
    static let description = IntentDescription("Ce qu’on mange à la cantine, d’après les menus publiés sur Pronote.")
    @Parameter(title: "Jour", default: .today) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.menu(day))")
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
    static let description = IntentDescription("Les devoirs à rendre ces prochains jours et les évaluations à venir.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Devoirs puis évaluations (les deux dans une seule question : Apple limite à 10 questions par app)
        let evals = Answers.evals()
        let text = Inbox.shared.linked && !evals.hasPrefix("Aucune") ? "\(Answers.homework()) \(evals)" : Answers.homework()
        return .result(dialog: "\(text)")
    }
}

struct NextLessonIntent: AppIntent {
    static let title: LocalizedStringResource = "Prochain cours"
    static let description = IntentDescription("Ton prochain cours, son heure et sa salle.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.nextLesson())")
    }
}

struct DayIntent: AppIntent {
    static let title: LocalizedStringResource = "Emploi du temps"
    static let description = IntentDescription("Tes cours d’un jour, l’heure où tu commences et où tu finis.")
    @Parameter(title: "Jour", default: .tomorrow) var day: DayChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.day(day))")
    }
}

struct EvalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Évaluations"
    static let description = IntentDescription("Tes prochaines évaluations.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.evals())")
    }
}

struct GradesIntent: AppIntent {
    static let title: LocalizedStringResource = "Moyenne et notes"
    static let description = IntentDescription("Ta moyenne (générale ou d’une matière) et tes dernières notes.")
    @Parameter(title: "Matière") var subject: SubjectEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.grades(subject))")
    }
}

struct BusIntent: AppIntent {
    static let title: LocalizedStringResource = "Prochain bus"
    static let description = IntentDescription("Quand passe ton prochain bus, et le suivant.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Answers.bus())")
    }
}

/// Phrases de Siri. Apple impose le nom de l'app dans chaque phrase : « NoteFlow », ou ses autres noms
/// (Info.plist, INAlternativeAppNames) « Ma routine », « Mon planning », « Note flow ». 10 actions au plus.
struct NoteFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BedtimeIntent(), phrases: [
            "\(.applicationName) je me couche à quelle heure",
            "\(.applicationName) je me couche à quelle heure \(\.$day)",
            "\(.applicationName) heure du coucher \(\.$day)",
            "À quelle heure je me couche avec \(.applicationName)",
            "À quelle heure je me couche \(\.$day) avec \(.applicationName)",
            "Je me couche à quelle heure \(\.$day) \(.applicationName)",
        ], shortTitle: "Heure du coucher", systemImageName: "bed.double.fill")
        AppShortcut(intent: WakeIntent(), phrases: [
            "\(.applicationName) je me réveille à quelle heure",
            "\(.applicationName) je me réveille à quelle heure \(\.$day)",
            "\(.applicationName) réveil \(\.$day)",
            "À quelle heure je me réveille \(\.$day) avec \(.applicationName)",
            "Je me réveille à quelle heure \(\.$day) \(.applicationName)",
        ], shortTitle: "Heure du réveil", systemImageName: "alarm.fill")
        AppShortcut(intent: LeaveIntent(), phrases: [
            "\(.applicationName) je pars à quelle heure",
            "\(.applicationName) je pars à quelle heure \(\.$day)",
            "À quelle heure je pars \(\.$day) avec \(.applicationName)",
            "Je pars à quelle heure \(\.$day) \(.applicationName)",
        ], shortTitle: "Heure de départ", systemImageName: "figure.walk")
        AppShortcut(intent: BagIntent(), phrases: [
            "\(.applicationName) faut prendre quoi pour demain",
            "\(.applicationName) je prends quoi pour demain",
            "\(.applicationName) mon sac pour demain",
            "\(.applicationName) faut prendre quoi \(\.$day)",
            "Qu'est-ce que je dois prendre pour demain avec \(.applicationName)",
        ], shortTitle: "Sac pour demain", systemImageName: "backpack.fill")
        AppShortcut(intent: HomeworkIntent(), phrases: [
            "\(.applicationName) j'ai quoi comme devoirs",
            "\(.applicationName) mes devoirs",
            "Qu'est-ce que j'ai comme devoirs avec \(.applicationName)",
            "J'ai quoi comme devoirs \(.applicationName)",
            "\(.applicationName) j'ai des contrôles",
            "\(.applicationName) mes évaluations",
            "\(.applicationName) mes prochains contrôles",
            "\(.applicationName) c'est quand mon prochain contrôle",
            "\(.applicationName) j'ai une évaluation",
            "\(.applicationName) j'ai un contrôle",
            "\(.applicationName) évaluations",
            "\(.applicationName) mes contrôles",
            "\(.applicationName) j'ai des évaluations",
            "Mes évaluations \(.applicationName)",
        ], shortTitle: "Devoirs et contrôles", systemImageName: "checklist")
        AppShortcut(intent: NextLessonIntent(), phrases: [
            "\(.applicationName) c'est quoi mon prochain cours",
            "\(.applicationName) mon prochain cours",
            "\(.applicationName) j'ai cours de quoi",
            "C'est quoi mon prochain cours \(.applicationName)",
        ], shortTitle: "Prochain cours", systemImageName: "book.fill")
        AppShortcut(intent: DayIntent(), phrases: [
            "\(.applicationName) j'ai quoi \(\.$day)",
            "\(.applicationName) j'ai cours \(\.$day)",
            "\(.applicationName) mon emploi du temps \(\.$day)",
            "\(.applicationName) je finis à quelle heure \(\.$day)",
            "\(.applicationName) emploi du temps",
        ], shortTitle: "Emploi du temps", systemImageName: "calendar")
        AppShortcut(intent: MenuIntent(), phrases: [
            "\(.applicationName) on mange quoi à la cantine",
            "\(.applicationName) on mange quoi à la cantine \(\.$day)",
            "\(.applicationName) on mange quoi \(\.$day)",
            "\(.applicationName) le menu de la cantine",
            "\(.applicationName) menu de la cantine \(\.$day)",
            "\(.applicationName) c'est quoi le menu",
            "On mange quoi à la cantine \(.applicationName)",
        ], shortTitle: "Menu de la cantine", systemImageName: "fork.knife")
        AppShortcut(intent: GradesIntent(), phrases: [
            "\(.applicationName) c'est quoi ma moyenne",
            "\(.applicationName) ma moyenne",
            "\(.applicationName) ma moyenne en \(\.$subject)",
            "\(.applicationName) mes notes",
            "\(.applicationName) mes dernières notes",
        ], shortTitle: "Moyenne et notes", systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(intent: BusIntent(), phrases: [
            "\(.applicationName) quand passe mon bus",
            "\(.applicationName) mon bus",
            "\(.applicationName) il passe quand le bus",
            "Quand passe mon bus \(.applicationName)",
        ], shortTitle: "Prochain bus", systemImageName: "bus.fill")
    }
}
