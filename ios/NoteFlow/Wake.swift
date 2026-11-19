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

    private var alarmBusy = false
    private var alarmTry = Date.distantPast

    /// Réveils du planning après `after`, dans l'ordre (aujourd'hui et demain : les jours envoyés par le site)
    private func wakes(_ plan: Plan?, after: Date) -> [Date] {
        guard let plan else { return [] }
        return plan.days.compactMap { day -> Date? in
            guard let wake = day.wake, let midnight = PlanClock.midnight(day.day) else { return nil }
            if Prefs.schoolOnly && day.school != true { return nil }
            return midnight.addingTimeInterval(wake * 60)
        }
        .filter { $0 > after }
        .sorted()
    }

    /// Prochain réveil du planning (aujourd'hui s'il n'est pas passé, sinon demain)
    func next(_ plan: Plan?) -> Date? {
        wakes(plan, after: Date().addingTimeInterval(60)).first
    }

    /// Pose une alarme pour chaque réveil à venir (aujourd'hui et demain) et le lever de soleil Hue du prochain.
    /// Une alarme qui va sonner dans moins de 2 minutes (ou qui sonne) n'est jamais annulée : avant, l'app
    /// passait au réveil du lendemain une minute avant l'heure et annulait celui du jour, qui ne sonnait pas.
    /// Pont injoignable (pas à la maison) ou alarme refusée : nouvel essai 10 minutes plus tard.
    func sync(_ plan: Plan?, force: Bool = false) {
        let now = Date()
        let mode = Prefs.wakeMode
        let phone = Prefs.wakeOn && mode != "hue"
        let alarms = phone ? wakes(plan, after: now) : []
        let phoneKey = "v2|" + alarms.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ",")
        if !alarmBusy, force || phoneKey != d.string(forKey: "alarmKey") || now.timeIntervalSince(alarmTry) > 600 {
            alarmBusy = true
            alarmTry = now
            Task { @MainActor in
                let ok = await PhoneAlarm.set(alarms)
                if ok { self.d.set(phoneKey, forKey: "alarmKey") } else { self.d.removeObject(forKey: "alarmKey") }
                self.alarmBusy = false
            }
        }

        // Lumières : le réveil du jour reste la cible jusqu'à 30 minutes après (lever de soleil en cours)
        var target = Prefs.wakeOn ? wakes(plan, after: now.addingTimeInterval(-1800)).first : nil
        if let t = target, force, t < now.addingTimeInterval(60) { target = next(plan) }
        let lights = target != nil && mode != "phone" && Prefs.hueReady
        let stamp = target.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let hueKey = lights ? "\(stamp)|\(Prefs.hueGroup)|\(Prefs.sunrise)|\(Prefs.stimulate)" : "none"
        let hueDone = d.string(forKey: "hueKey")
        guard force || hueKey != hueDone, !busy, force || now.timeIntervalSince(lastTry) > 600 else { return }
        // Rien à défaire : pas de programme posé et rien à poser
        if hueKey == "none" && (hueDone == nil || hueDone == "none") { d.set("none", forKey: "hueKey"); return }
        let ip = Prefs.hueIP, user = Prefs.hueUser, group = Prefs.hueGroup
        guard !ip.isEmpty, !user.isEmpty else { d.set("none", forKey: "hueKey"); return }
        busy = true
        lastTry = now
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
    /// Alarmes posées aux heures données. Faux si elles n'ont pas pu l'être (autorisation, erreur) : nouvel essai.
    static func set(_ dates: [Date]) async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return await Modern.set(dates) }
        #endif
        return true
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
    /// Une alarme par réveil (heure → identifiant, gardé dans « alarms »). Les alarmes qui ne sont plus au planning
    /// sont annulées, sauf si elles sonnent dans moins de 2 minutes ; celles qu'iOS n'a plus sont reposées.
    static func set(_ dates: [Date]) async -> Bool {
        let manager = AlarmManager.shared
        let d = UserDefaults.standard
        let now = Date()
        var map = d.dictionary(forKey: "alarms") as? [String: String] ?? [:]
        // Ancienne version : une seule alarme
        if let old = d.string(forKey: "alarmId") {
            if let key = d.string(forKey: "alarmKey"), Double(key) != nil { map[key] = old }
            d.removeObject(forKey: "alarmId")
        }
        let live: Set<String>? = (try? manager.alarms).map { list in Set(list.map { $0.id.uuidString }) }
        let want = Dictionary(dates.map { (String(Int($0.timeIntervalSince1970)), $0) }, uniquingKeysWith: { a, _ in a })

        for (stamp, id) in map {
            let at = Date(timeIntervalSince1970: Double(stamp) ?? 0)
            let alive = live?.contains(id) ?? true
            if want[stamp] != nil {
                if !alive { map[stamp] = nil }  // disparue : on la repose
            } else if at > now.addingTimeInterval(120) {
                if let uuid = UUID(uuidString: id) { try? manager.cancel(id: uuid) }  // réveil changé
                map[stamp] = nil
            } else if !alive || at < now.addingTimeInterval(-3600) {
                map[stamp] = nil  // déjà sonnée
            }
        }

        var ok = true
        let missing = want.filter { map[$0.key] == nil && $0.value > now }
        if !missing.isEmpty {
            if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
            if manager.authorizationState != .authorized {
                d.set("Alarmes non autorisées (Réglages › NoteFlow › Alarmes)", forKey: "alarmLastError")
                ok = false
            } else {
                for (stamp, date) in missing {
                    let stop = AlarmButton(text: "Je suis réveillé", textColor: .white, systemImageName: "sun.max.fill")
                    let alert = AlarmPresentation.Alert(title: "C’est l’heure de te lever", stopButton: stop)
                    let attributes = AlarmAttributes<WakeMeta>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
                    let id = UUID()
                    let config = AlarmManager.AlarmConfiguration<WakeMeta>(schedule: .fixed(date), attributes: attributes)
                    do {
                        _ = try await manager.schedule(id: id, configuration: config)
                        map[stamp] = id.uuidString
                    } catch {
                        d.set(error.localizedDescription, forKey: "alarmLastError")
                        ok = false
                    }
                }
            }
        }
        d.set(map, forKey: "alarms")
        if ok { d.removeObject(forKey: "alarmLastError") }
        return ok
    }
}
#endif
