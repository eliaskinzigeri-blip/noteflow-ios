import Foundation

/// Ce qu'on sait d'un jour du planning : sac, départ, réveil et coucher. Sert à l'activité en direct (sac du
/// lendemain) et aux réponses de Siri.
enum DayInfo {
    /// Planning enregistré (envoyé par le site : la semaine qui vient)
    static var plan: Plan? {
        UserDefaults.standard.data(forKey: "plan").flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    }

    /// Premier trajet du jour (étapes de déplacement qui se suivent) : première et dernière étape
    static func trip(_ day: PlanDay) -> (first: PlanStep, last: PlanStep, bus: PlanStep?)? {
        let steps = day.steps.sorted { $0.start < $1.start }
        guard var a = steps.firstIndex(where: { $0.travel }) else { return nil }
        var b = a
        while b + 1 < steps.count, steps[b + 1].travel, steps[b + 1].start - steps[b].end < 2 { b += 1 }
        let bus = steps[a...b].first { $0.kind == "bus" }
        a = min(a, b)
        return (steps[a], steps[b], bus)
    }

    /// Cours du jour, dans l'ordre, sans doublon
    static func subjects(_ day: PlanDay) -> [String] {
        var seen = Set<String>()
        return day.steps.filter { $0.kind == "lesson" }.sorted { $0.start < $1.start }.map(\.label).filter { seen.insert($0).inserted }
    }

    /// Sac d'un jour d'école : ses cours, les devoirs à rendre ce jour-là, les évaluations des 3 jours,
    /// la météo du trajet du matin. nil sans cours.
    static func bag(_ day: PlanDay, now: Date) -> (lines: [String], weather: String?)? {
        let list = subjects(day)
        guard !list.isEmpty, let midnight = PlanClock.midnight(day.day) else { return nil }
        let when = Calendar.current.isDate(midnight, inSameDayAs: now) ? "Aujourd’hui" : "Demain"
        var lines = ["\(when) : " + list.joined(separator: " · ")]
        let work = Inbox.shared.work
        let hw = work.homework.filter { $0.due == day.day }
        if !hw.isEmpty {
            lines.append("Devoirs : " + hw.prefix(3).map { w in
                let text = w.text.count > 28 ? String(w.text.prefix(27)) + "…" : w.text
                return text.isEmpty ? w.subject : "\(w.subject) (\(text))"
            }.joined(separator: " · ") + (hw.count > 3 ? " +\(hw.count - 3)" : ""))
        }
        let last = PlanClock.dayFormat.string(from: midnight.addingTimeInterval(2 * 86400 + 3600))
        let evals = work.evals.filter { $0.due >= day.day && $0.due <= last }.sorted { $0.due < $1.due }
        if !evals.isEmpty {
            lines.append("Éval : " + evals.prefix(3).map { e in
                let date = PlanClock.midnight(e.due).map { e.due == day.day ? "ce jour-là" : weekday($0) } ?? e.due
                return "\(e.subject) \(date)"
            }.joined(separator: " · "))
        }
        var weather: String?
        if let t = trip(day) {
            weather = Weather.shared.summary(midnight.addingTimeInterval(t.first.start * 60), midnight.addingTimeInterval(t.last.end * 60))
                .map { "\(when == "Demain" ? "Demain matin" : "Ce matin") : \($0)" }
        }
        return (lines, weather)
    }

    /// « lundi », « mardi »…
    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }
}
