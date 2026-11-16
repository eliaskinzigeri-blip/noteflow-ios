import Foundation
import UIKit
import UserNotifications

/// Notifications de l'école dans l'app iPhone : nouvelle note, nouvelle information ou sondage, devoirs pour demain
/// et évaluation dans 3 jours. Le site les reçoit par Firebase (notifications web), que la vue web d'une app ne
/// reçoit pas, et une app installée par SideStore n'a pas droit aux notifications d'Apple (APNs). L'app demande
/// donc elle-même à NoteFlow ce qui est nouveau (fonction « noteflow-focus », q=inbox, avec la clé secrète du
/// compte) et l'affiche en notification locale. Elle le fait toutes les 3 minutes tant qu'elle tourne : au premier
/// plan, en arrière-plan (la localisation de l'activité en direct la garde éveillée), et aux réveils d'iOS.
/// Les devoirs et les évaluations sont programmés à l'avance : ils sonnent même si l'app est fermée.
final class Inbox {
    static let shared = Inbox()
    static let refreshTask = "com.noteflow.app.refresh"

    private let endpoint = "https://ieagkscoaoutrvsgihat.supabase.co/functions/v1/noteflow-focus"
    private let d = UserDefaults.standard
    private var busy = false
    private var lastTry = Date.distantPast

    private init() {}

    /// Clé du mode focus du compte, envoyée par la vue web (WebView.swift) : elle sert aussi à lier YouTube et Twitch.
    var key: String { d.string(forKey: "focusKey") ?? "" }
    var linked: Bool { key.count >= 20 }

    func link(_ key: String) {
        guard key.count >= 20, key != self.key else { return }
        d.set(key, forKey: "focusKey")
        // Autre compte : on repart de maintenant, sans rejouer les alertes de l'ancien
        d.removeObject(forKey: "inboxSince")
        d.removeObject(forKey: "inboxSeen")
        poll(force: true)
    }

    /// Texte d'état pour l'écran « Sur cet iPhone ».
    var status: String {
        guard linked else { return "Ouvre NoteFlow connecté à ton compte : la liaison se fait toute seule en quelques secondes." }
        let last = d.double(forKey: "inboxOK")
        guard last > 0 else { return "Première vérification en cours…" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        let date = Date(timeIntervalSince1970: last)
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'aujourd’hui à' H'h'mm" : "EEEE 'à' H'h'mm"
        return "Dernière vérification : \(f.string(from: date))."
    }

    // MARK: Relevé

    func poll(force: Bool = false, done: ((Bool) -> Void)? = nil) {
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { done?(ok) } }
        guard Prefs.school else { Reminders.shared.clearSchool(); finish(false); return }
        guard linked, !busy, Date().timeIntervalSince(lastTry) >= (force ? 15 : 180) else { finish(false); return }
        var parts = URLComponents(string: endpoint)!
        parts.queryItems = [URLQueryItem(name: "q", value: "inbox"), URLQueryItem(name: "k", value: key)]
        let since = d.double(forKey: "inboxSince")
        // Une minute et demie de recouvrement : une alerte écrite pendant le relevé d'avant n'est pas perdue
        if since > 0 { parts.queryItems?.append(URLQueryItem(name: "since", value: String(Int(since - 90_000)))) }
        guard let url = parts.url else { finish(false); return }
        busy = true
        lastTry = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        let asked = key
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard asked == self.key, (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let reply = try? JSONDecoder().decode(Reply.self, from: data) else { done?(false); return }
                self.handle(reply)
                done?(true)
            }
        }.resume()
    }

    private struct Alert: Decodable { let id: String; let kind: String; let at: Double; let title: String; let body: String; let url: String }
    private struct Work: Decodable { let id: String; let subject: String; let text: String; let due: String }
    private struct Reply: Decodable {
        let now: Double
        let quiet: Bool
        let alerts: [Alert]
        let child: String
        let dueTomorrow: Bool
        let evalSoon: Bool
        let homework: [Work]
        let evals: [Work]
    }

    private func handle(_ r: Reply) {
        d.set(Date().timeIntervalSince1970, forKey: "inboxOK")
        plan(r)
        // Focus « sans notifications » : les alertes attendent la fin du focus (le relevé repart du même point)
        if r.quiet && d.double(forKey: "inboxSince") > 0 { return }
        var seen = d.stringArray(forKey: "inboxSeen") ?? []
        for a in r.alerts where !seen.contains(a.id) {
            seen.append(a.id)
            let route = a.url.isEmpty ? (a.kind == "grade" ? "#/notes" : a.kind == "info" ? "#/infos" : "#/") : a.url
            Reminders.shared.post(id: "school-alert-\(a.id)", title: a.title, body: a.body, url: route)
        }
        d.set(Array(seen.suffix(300)), forKey: "inboxSeen")
        d.set(r.now, forKey: "inboxSince")
    }

    // MARK: Devoirs pour demain (18 h) et évaluations dans 3 jours (8 h)

    private func plan(_ r: Reply) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let who = r.child.isEmpty ? "" : " : \(r.child)"
        var keep: [String] = []                                  // notifications programmées à garder
        var planned = Set(d.stringArray(forKey: "schoolPlanned") ?? [])  // déjà programmées ou affichées

        for offset in 0..<3 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day),
                  let fire = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) else { continue }
            let id = "school-hw-\(PlanClock.dayFormat.string(from: day))"
            let due = PlanClock.dayFormat.string(from: next)
            let list = r.dueTomorrow ? r.homework.filter { $0.due == due } : []
            guard !list.isEmpty else { planned.remove(id); continue }
            var body = list.prefix(4).map { "\($0.subject) : \($0.text)" }.joined(separator: "\n")
            if list.count > 4 { body += "\n+ \(list.count - 4) autre\(list.count > 5 ? "s" : "")" }
            if fire > now {
                Reminders.shared.post(id: id, title: "Pour demain\(who)", body: body, url: "#/tasks", at: fire)
                keep.append(id)
                planned.insert(id)
            } else if !planned.contains(id) {
                // 18 h déjà passé et rien n'était programmé (devoir ajouté le soir, app liée après 18 h)
                Reminders.shared.post(id: id, title: "Pour demain\(who)", body: body, url: "#/tasks")
                planned.insert(id)
            }
        }

        for e in r.evalSoon ? r.evals : [] {
            guard let due = PlanClock.midnight(e.due), let day = cal.date(byAdding: .day, value: -3, to: due),
                  let fire = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) else { continue }
            let id = "school-eval-\(e.id.isEmpty ? String(Reminders.stable(e.due + e.subject + e.text)) : e.id)"
            let url = e.id.isEmpty ? "#/tasks" : "#/tasks/\(e.id)"
            if fire > now {
                Reminders.shared.post(id: id, title: "Évaluation dans 3 jours\(who)", body: "\(e.subject) : \(e.text)", url: url, at: fire)
                keep.append(id)
                planned.insert(id)
            } else if cal.isDate(fire, inSameDayAs: now), !planned.contains(id) {
                Reminders.shared.post(id: id, title: "Évaluation dans 3 jours\(who)", body: "\(e.subject) : \(e.text)", url: url)
                planned.insert(id)
            }
        }

        Reminders.shared.keepSchool(Set(keep))
        // La mémoire ne garde que les devoirs des jours encore utiles et les évaluations encore annoncées
        let floor = "school-hw-\(PlanClock.dayFormat.string(from: today))"
        let evalIDs = Set(r.evals.map { "school-eval-\($0.id)" })
        planned = planned.filter { $0.hasPrefix("school-hw-") ? $0 >= floor : (evalIDs.contains($0) || keep.contains($0)) }
        d.set(Array(planned), forKey: "schoolPlanned")
    }
}
