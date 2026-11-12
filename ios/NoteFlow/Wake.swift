import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Réveil intelligent : l'heure de réveil vient du planning (premier cours, temps de préparation, bus),
/// recalculée si un prof est absent. Selon les réglages : une vraie alarme de l'iPhone (AlarmKit, iOS 26)
/// et/ou un lever de soleil programmé dans le pont Philips Hue.
final class Wake {
    static let shared = Wake()
    private let d = UserDefaults.standard
    private var busy = false
    private var lastTry = Date.distantPast

    /// Prochain réveil du planning (aujourd'hui s'il n'est pas passé, sinon demain)
    func next(_ plan: Plan?) -> Date? {
        guard let plan else { return nil }
        let now = Date()
        for day in plan.days {
            guard let wake = day.wake, let midnight = PlanClock.midnight(day.day) else { continue }
            if Prefs.schoolOnly && day.school != true { continue }
            let at = midnight.addingTimeInterval(wake * 60)
            if at > now.addingTimeInterval(60) { return at }
        }
        return nil
    }

    /// Met l'alarme et le pont Hue à l'heure du prochain réveil. Ne refait rien si rien n'a changé ;
    /// pont injoignable (pas à la maison) : nouvel essai 10 minutes plus tard.
    func sync(_ plan: Plan?, force: Bool = false) {
        let target = Prefs.wakeOn ? next(plan) : nil
        let mode = Prefs.wakeMode
        let phone = target != nil && mode != "hue"
        let lights = target != nil && mode != "phone" && Prefs.hueReady
        let stamp = target.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let phoneKey = phone ? stamp : "none"
        let hueKey = lights ? "\(stamp)|\(Prefs.hueGroup)|\(Prefs.sunrise)|\(Prefs.stimulate)" : "none"

        if force || phoneKey != d.string(forKey: "alarmKey") {
            d.set(phoneKey, forKey: "alarmKey")
            Task { await PhoneAlarm.set(phone ? target : nil) }
        }
        let hueDone = d.string(forKey: "hueKey")
        guard force || hueKey != hueDone, !busy, force || Date().timeIntervalSince(lastTry) > 600 else { return }
        // Rien à défaire : pas de programme posé et rien à poser
        if hueKey == "none" && (hueDone == nil || hueDone == "none") { d.set("none", forKey: "hueKey"); return }
        let ip = Prefs.hueIP, user = Prefs.hueUser, group = Prefs.hueGroup
        guard !ip.isEmpty, !user.isEmpty else { d.set("none", forKey: "hueKey"); return }
        busy = true
        lastTry = Date()
        Task {
            do {
                if lights, let target {
                    try await Hue.schedule(ip, user, group: group, wake: target, sunrise: Prefs.sunrise, stimulate: Prefs.stimulate)
                } else {
                    try await Hue.clear(ip, user)
                }
                d.set(hueKey, forKey: "hueKey")
                d.set(Date(), forKey: "hueSyncedAt")
            } catch {
                d.set(error.localizedDescription, forKey: "hueLastError")
            }
            busy = false
        }
    }
}

/// Alarme de l'iPhone (AlarmKit, iOS 26 et plus) : sonne même en mode silencieux ou concentration.
enum PhoneAlarm {
    static func set(_ date: Date?) async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { await Modern.set(date) }
        #endif
    }

    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct WakeMeta: AlarmMetadata {}

@available(iOS 26.0, *)
private enum Modern {
    static func set(_ date: Date?) async {
        let manager = AlarmManager.shared
        let d = UserDefaults.standard
        if let old = d.string(forKey: "alarmId").flatMap(UUID.init(uuidString:)) { try? manager.cancel(id: old) }
        d.removeObject(forKey: "alarmId")
        guard let date else { return }
        if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
        guard manager.authorizationState == .authorized else { return }
        let stop = AlarmButton(text: "Je suis réveillé", textColor: .white, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: "C’est l’heure de te lever", stopButton: stop)
        let attributes = AlarmAttributes<WakeMeta>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
        let id = UUID()
        let config = AlarmManager.AlarmConfiguration<WakeMeta>(schedule: .fixed(date), attributes: attributes)
        do {
            _ = try await manager.schedule(id: id, configuration: config)
            d.set(id.uuidString, forKey: "alarmId")
        } catch {
            d.set(error.localizedDescription, forKey: "alarmLastError")
            d.removeObject(forKey: "alarmKey")
        }
    }
}
#endif
