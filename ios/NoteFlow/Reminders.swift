import Foundation
import UserNotifications

/// Rappels de la routine programmés par l'iPhone lui-même (notifications locales, sans serveur) :
/// les mêmes que les notifications du site, plus « Départ dans 5 min » avant chaque trajet.
/// iOS garde au plus 64 notifications en attente : on en programme 60 au maximum.
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    private let center = UNUserNotificationCenter.current()
    private let prefix = "nf-"

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Bannière même NoteFlow ouvert
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Empreinte stable d'un texte (hashValue change à chaque lancement)
    static func stable(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
    }

    private struct Item { let id: String; let at: Date; let title: String; let body: String }

    func schedule(_ plan: Plan) {
        guard Prefs.notify else { clear(); return }
        var items: [Item] = []
        let now = Date()
        for a in plan.alerts ?? [] {
            guard let at = Reminders.iso.date(from: a.at) ?? Reminders.isoPlain.date(from: a.at), at > now else { continue }
            items.append(Item(id: "\(prefix)\(Int(at.timeIntervalSince1970))-\(Reminders.stable(a.title))", at: at, title: a.title, body: a.body))
        }
        // « Départ dans 5 min » : avant le premier trajet de chaque déplacement
        for day in plan.days {
            guard let midnight = PlanClock.midnight(day.day) else { continue }
            for (i, s) in day.steps.enumerated() where s.travel && (i == 0 || !day.steps[i - 1].travel) {
                let at = midnight.addingTimeInterval((s.start - 5) * 60)
                guard at > now else { continue }
                items.append(Item(id: "\(prefix)go-\(Int(at.timeIntervalSince1970))", at: at, title: "Départ dans 5 min",
                                  body: "\(s.label) à \(PlanClock.clock(s.start))\(s.detail.isEmpty ? "" : " · \(s.detail)")"))
            }
        }
        items.sort { $0.at < $1.at }
        let chosen = Array(items.prefix(60))
        let sig = chosen.map { "\($0.id)\($0.title)\($0.body)" }.joined(separator: "|")
        guard sig != UserDefaults.standard.string(forKey: "remindersSig") else { return }

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            guard let self, ok else { return }
            self.center.getPendingNotificationRequests { pending in
                self.center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(self.prefix) })
                for item in chosen {
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = item.body
                    content.sound = .default
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.at)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                    self.center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
                }
                UserDefaults.standard.set(sig, forKey: "remindersSig")
            }
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: "remindersSig")
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(self.prefix) })
        }
    }

    /// Notification immédiate (arrivée détectée)
    func now(id: String, title: String, body: String) {
        guard Prefs.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "arrive-\(id)", content: content, trigger: nil))
    }
}
