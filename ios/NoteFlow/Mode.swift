import CoreLocation
import Foundation

/// Devine comment tu te déplaces avec ta vitesse et tes positions : à pied, en bus ou à l'arrêt (attente).
/// Un changement de mode doit durer un moment pour être pris en compte : un bus arrêté au feu reste un bus,
/// une pause de quelques secondes ne coupe pas la marche.
final class ModeGuess {
    enum Mode: String { case walk, bus, wait }

    private(set) var mode: Mode?
    private(set) var since = Date()        // début du mode actuel
    private var candidate: Mode?
    private var candidateSince = Date()
    private var fixes: [CLLocation] = []   // positions des 3 dernières minutes (la dernière est toujours gardée)
    private var rideStart: Date?           // montée dans le bus
    private var rideMeters: Double = 0     // distance parcourue en bus depuis la montée

    func add(_ l: CLLocation) {
        guard l.horizontalAccuracy >= 0, l.horizontalAccuracy < 65 else { return }
        if let p = fixes.last {
            guard l.timestamp > p.timestamp else { return }
            if mode == .bus { rideMeters += l.distance(from: p) }
        }
        fixes.append(l)
        let last = l.timestamp
        fixes.removeAll { $0 !== l && last.timeIntervalSince($0.timestamp) > 180 }
    }

    /// Vitesse moyenne (m/s) sur les `window` dernières secondes. Sans nouvelle position depuis un moment,
    /// tu ne bouges pas : iOS n'en envoie que quand tu t'es déplacé de quelques mètres.
    func speed(_ window: TimeInterval, _ now: Date) -> Double? {
        guard let last = fixes.last else { return nil }
        let end = now.timeIntervalSince(last.timestamp) > 20 ? now : last.timestamp
        let ref = fixes.first { end.timeIntervalSince($0.timestamp) <= window } ?? last
        let dt = end.timeIntervalSince(ref.timestamp)
        guard dt >= 8 else { return last.speed >= 0 ? last.speed : nil }
        // Le bruit du GPS fait bouger une position immobile de quelques mètres : on le retire
        let noise = (ref.horizontalAccuracy + last.horizontalAccuracy) * 0.3
        return max(0, last.distance(from: ref) - noise) / dt
    }

    /// Mode suggéré par la vitesse du moment (nil : entre deux, on garde le mode actuel)
    private func raw(_ now: Date) -> Mode? {
        guard let v = speed(30, now) else { return nil }
        let peak = fixes.filter { now.timeIntervalSince($0.timestamp) < 45 && $0.speed >= 0 && $0.horizontalAccuracy < 30 }
            .map(\.speed).max() ?? 0
        if v >= 5 || peak >= 7 { return .bus }        // plus de 18 km/h : tu es dans un véhicule
        if v >= 0.6 && v < 2.8 { return .walk }        // de 2 à 10 km/h : tu marches
        if v < 0.4 && peak < 1.5 { return .wait }      // immobile
        return nil
    }

    /// `nearStop` : en bus, près de l'arrêt où tu descends (le changement est alors accepté plus vite)
    func update(_ now: Date, nearStop: Bool) {
        if let last = fixes.last, now.timeIntervalSince(last.timestamp) > 600, mode != nil, now.timeIntervalSince(since) > 600 {
            mode = nil  // plus de nouvelles depuis 10 minutes (app endormie) : on repart de zéro
        }
        guard let r = raw(now) else { return }
        if r == mode { candidate = nil; return }
        if r != candidate { candidate = r; candidateSince = now }
        let delay: TimeInterval
        switch (mode, r) {
        case (nil, _): delay = 0
        case (_, .bus): delay = 10
        case (.bus?, .walk): delay = nearStop ? 15 : 75   // bus dans les bouchons : il faut marcher un moment
        case (.bus?, .wait): delay = nearStop ? 30 : 240  // arrêts et feux rouges : le bus reste un bus
        case (_, .walk): delay = 15
        case (_, .wait): delay = 45
        }
        guard now.timeIntervalSince(candidateSince) >= delay else { return }
        mode = r
        since = now
        candidate = nil
        if r == .bus { rideStart = now; rideMeters = 0 }
    }

    /// Ta vitesse de marche (moyenne des 90 dernières secondes), 4,5 km/h tant qu'on ne la connaît pas
    func walkSpeed(_ now: Date) -> Double {
        let v = fixes.filter { now.timeIntervalSince($0.timestamp) < 90 && $0.speed >= 0.3 && $0.horizontalAccuracy < 30 }.map(\.speed)
        guard mode == .walk, v.count >= 5 else { return 1.25 }
        return min(max(v.reduce(0, +) / Double(v.count), 0.9), 2.2)
    }

    /// Vitesse moyenne du bus depuis la montée, arrêts compris (connue au bout de 2 minutes)
    func busSpeed(_ now: Date) -> Double? {
        guard mode == .bus, let s = rideStart, now.timeIntervalSince(s) > 120, rideMeters > 300 else { return nil }
        return min(max(rideMeters / now.timeIntervalSince(s), 3), 20)
    }

    /// Temps passé dans le bus
    func ride(_ now: Date) -> TimeInterval { mode == .bus ? now.timeIntervalSince(rideStart ?? now) : 0 }
}
