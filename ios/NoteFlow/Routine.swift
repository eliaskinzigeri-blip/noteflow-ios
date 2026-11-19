import ActivityKit
import CoreLocation
import Foundation
import UIKit
import WidgetKit

/// Tient à jour une seule activité en direct, affichée en permanence : l'étape en cours, la navigation pendant
/// les trajets (à pied, en bus ou en attente, deviné avec ta vitesse et ta position, et le temps qu'il reste),
/// les séances Prépa Basket, le temps libre et la nuit. La localisation en arrière-plan garde l'app éveillée pour changer d'étape ;
/// si iOS ferme l'app, les changements de position importants et les zones maison/collège la relancent.
final class Routine: NSObject, CLLocationManagerDelegate {
    static let shared = Routine()

    private let location = CLLocationManager()
    private var plan: Plan?
    private var here: CLLocation?
    private let guess = ModeGuess()  // à pied, en bus ou à l'arrêt
    private var legKey = ""          // trajet en cours (jour|début)
    private var leg = 0              // étape du trajet atteinte (on n'y revient pas en arrière)
    private var busEnd: CLLocation?  // en bus : l'arrêt où tu descends
    private var timer: Timer?
    private var last: RoutineAttributes.ContentState?
    private var traveling = false  // GPS précis (autour des trajets)
    private var session: AnyObject?  // CLBackgroundActivitySession (iOS 17)

    private override init() {
        super.init()
        location.delegate = self
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .otherNavigation
        if let data = UserDefaults.standard.data(forKey: "plan") { plan = try? JSONDecoder().decode(Plan.self, from: data) }
        _ = Reminders.shared  // délégué des notifications (bannière même app ouverte)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        startLocation()
        refresh()
    }

    var current: Plan? { plan }

    // MARK: Planning reçu du site

    func receive(_ data: Data) {
        guard let p = try? JSONDecoder().decode(Plan.self, from: data), p.type == "plan" else { return }
        plan = p
        UserDefaults.standard.set(data, forKey: "plan")
        SharedStore.defaults.set(data, forKey: "plan")
        WidgetCenter.shared.reloadAllTimelines()
        Reminders.shared.schedule(p)
        Wake.shared.sync(p)
        startLocation()
        refresh()
    }

    /// Réglages changés dans la fiche « Sur cet iPhone »
    func settingsChanged() {
        if let p = plan { Reminders.shared.schedule(p) } else { Reminders.shared.clear() }
        Wake.shared.sync(plan, force: true)
        watchPlaces()
        refresh()
    }

    // MARK: Localisation

    private func startLocation() {
        guard plan != nil else { return }
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            if session == nil, #available(iOS 17.0, *) { session = CLBackgroundActivitySession() }
            tune()
            location.startUpdatingLocation()
            // Relance l'app si iOS l'a fermée (nuit, mémoire) : sinon l'activité resterait figée
            if location.authorizationStatus == .authorizedAlways { location.startMonitoringSignificantLocationChanges() }
            watchPlaces()
        default:
            break
        }
    }

    /// Précis autour des trajets, économe le reste du temps (l'app reste éveillée pour changer d'étape).
    private func tune() {
        location.desiredAccuracy = traveling ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        location.distanceFilter = traveling ? 5 : 50
    }

    /// Zones de la maison et du collège : iOS réveille l'app en y entrant, même si elle a été fermée
    private func watchPlaces() {
        for r in location.monitoredRegions where r.identifier == "home" || r.identifier == "school" { location.stopMonitoring(for: r) }
        guard location.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for (id, p) in [("home", plan?.home), ("school", plan?.school)] {
            guard let p else { continue }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: 150, identifier: id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            location.startMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if let l = manager.location { here = l }
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if let l = manager.location { here = l }
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        locations.forEach(guess.add)
        here = l
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: Étapes du jour

    private static let clock = PlanClock.clock

    /// Étapes du jour avec les séances Prépa Basket (une séance passe devant l'étape qu'elle recouvre)
    private func daySteps(_ day: PlanDay) -> [PlanStep] {
        let sessions = (day.sessions ?? []).map {
            PlanStep(label: $0.label, detail: "Séance Prépa Basket", start: $0.start, end: $0.end, kind: "session", travel: false, pts: [])
        }
        return (day.steps + sessions).sorted { $0.start < $1.start }
    }

    func refresh() {
        Inbox.shared.poll()  // notifications de l'école : au plus un relevé toutes les 3 minutes
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let minute = now.timeIntervalSince(midnight) / 60
        let today = PlanClock.dayFormat.string(from: now)
        Wake.shared.sync(plan)
        let nearStop = busEnd.flatMap { end in here.map { $0.distance(from: end) < 200 } } ?? false
        guess.update(now, nearStop: nearStop)
        guard let day = plan?.days.first(where: { $0.day == today }) else { idle(now, today: today); return }
        let steps = daySteps(day)
        let covering = steps.indices.filter { steps[$0].start <= minute && minute < steps[$0].end && steps[$0].kind != "sleep" }
        let i = covering.first(where: { steps[$0].kind == "session" }) ?? covering.first

        // GPS précis autour des trajets (pour deviner un départ en avance ou un retard), économe le reste du temps
        let precise = steps.contains { $0.travel && $0.start - 25 <= minute && minute < $0.end + 30 }
        if precise != traveling { traveling = precise; tune() }

        // Trajet : celui du planning, ou un trajet voisin si tu es parti en avance ou pas encore arrivé
        if i.map({ steps[$0].kind != "session" }) ?? true, let blk = liveBlock(steps, i, minute) {
            guard let after = arrived(steps, blk, day: today) else {
                show(travelState(steps, blk, i, now: now, minute: minute, day: today), day: today)
                return
            }
            if minute < steps[after].start {
                // Arrivée détectée : trajet fini en avance, on annonce l'étape qui suit le déplacement
                let step = steps[after]
                let next = steps[(after + 1)...].first { $0.kind != "sleep" }
                let startAt = midnight.addingTimeInterval(step.start * 60)
                let state = RoutineAttributes.ContentState(
                    title: step.label, detail: "Tu es arrivé · début à \(Routine.clock(step.start))",
                    kind: step.kind, start: now, end: max(startAt, now.addingTimeInterval(60)),
                    next: next.map { "Puis \($0.label) à \(Routine.clock($0.start))" } ?? "", travel: false)
                busEnd = nil
                show(state, day: today)
                return
            }
        }
        busEnd = nil
        guard let i, !steps[i].travel else { idle(now, today: today); return }
        let cur = steps[i]

        // Prochaine étape, pour savoir ce qui vient après
        let next = steps[(i + 1)...].first { $0.start >= cur.end - 0.5 && $0.kind != "sleep" && $0.kind != cur.kind }
        let nextText = next.map { "Puis \($0.label) à \(Routine.clock($0.start))" } ?? ""
        let start = midnight.addingTimeInterval(cur.start * 60)
        let end = midnight.addingTimeInterval(max(cur.end, cur.start + 1) * 60)
        show(RoutineAttributes.ContentState(title: cur.label, detail: cur.detail, kind: cur.kind, start: start, end: end,
                                            next: nextText, travel: false), day: today)
    }

    // MARK: Trajets (mode deviné)

    private func loc(_ p: PlanPoint) -> CLLocation { CLLocation(latitude: p.lat, longitude: p.lon) }

    /// Trajet à afficher : celui du planning en cours, ou un trajet voisin si tu bouges déjà (à pied ou en bus)
    /// en dehors de ses heures : jusqu'à 20 minutes avant son début (parti en avance) et 30 minutes après sa fin
    /// (pas encore arrivé), à condition d'être sur le chemin.
    private func liveBlock(_ steps: [PlanStep], _ i: Int?, _ minute: Double) -> (Int, Int)? {
        if let i, steps[i].travel { return block(steps, around: i) }
        guard guess.mode == .walk || guess.mode == .bus, let me = here, me.horizontalAccuracy < 100 else { return nil }
        var k = 0
        while k < steps.count {
            guard steps[k].travel else { k += 1; continue }
            let (a, b) = block(steps, around: k)
            k = b + 1
            let early = steps[a].start - 20 <= minute && minute < steps[a].start
            let late = steps[b].end <= minute && minute < steps[b].end + 30
            guard early || late, let dest = steps[b].pts.last, let from = legStart(steps, a, first: a) else { continue }
            if me.distance(from: loc(dest)) < 150 { continue }           // déjà à destination
            if early && me.distance(from: loc(from)) < 150 { continue }  // pas encore parti
            let away = (a...b).map { legDistance(me, steps, $0, first: a) }.min() ?? .infinity
            if away > 2000 { continue }                                  // ailleurs : ce n'est pas ce trajet
            return (a, b)
        }
        return nil
    }

    /// Point de départ d'une étape de trajet : son premier point, sinon la fin de l'étape d'avant, sinon la maison
    /// ou le collège (le plus proche de son arrivée).
    private func legStart(_ steps: [PlanStep], _ k: Int, first a: Int) -> PlanPoint? {
        let s = steps[k]
        if s.pts.count > 1 { return s.pts.first }
        if k > a, let p = steps[k - 1].pts.last { return p }
        let places = [plan?.home, plan?.school].compactMap { $0 }
        guard let end = legEnd(steps, k) else { return places.first }
        return places.min { loc($0).distance(from: loc(end)) < loc($1).distance(from: loc(end)) }
    }

    /// Point d'arrivée d'une étape : son dernier point (bus : l'arrêt où commence la marche qui suit)
    private func legEnd(_ steps: [PlanStep], _ k: Int) -> PlanPoint? {
        if steps[k].kind == "bus" { return k + 1 < steps.count ? steps[k + 1].pts.first : nil }
        return steps[k].pts.last
    }

    /// Distance (m) entre toi et le chemin d'une étape (segments entre ses points)
    private func legDistance(_ me: CLLocation, _ steps: [PlanStep], _ k: Int, first a: Int) -> Double {
        var line: [PlanPoint] = []
        if let p = legStart(steps, k, first: a) { line.append(p) }
        if steps[k].kind == "bus" {
            if let e = legEnd(steps, k) { line.append(e) }
        } else {
            line += steps[k].pts
        }
        guard let p0 = line.first else { return .infinity }
        let lat = me.coordinate.latitude, lon = me.coordinate.longitude
        let kx = cos(lat * .pi / 180) * 111_320
        let xy = { (p: PlanPoint) -> (Double, Double) in ((p.lon - lon) * kx, (p.lat - lat) * 110_540) }
        var best = hypot(xy(p0).0, xy(p0).1)
        for (u, v) in zip(line, line.dropFirst()) {
            let (ax, ay) = xy(u), (bx, by) = xy(v)
            let dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy
            let t = len > 0 ? min(max(-(ax * dx + ay * dy) / len, 0), 1) : 0
            best = min(best, hypot(ax + t * dx, ay + t * dy))
        }
        return best
    }

    /// Étape du trajet (celle en cours ou une suivante) qui correspond au mode deviné : la plus proche de toi.
    /// Une étape plus loin dans le trajet n'est choisie que si elle est nettement plus proche (200 m).
    private func pick(_ steps: [PlanStep], _ kind: String, _ a: Int, _ b: Int) -> Int? {
        let ks = (min(max(leg, a), b)...b).filter { steps[$0].kind == kind }
        guard let me = here, ks.count > 1 else { return ks.first }
        let d = ks.map { legDistance(me, steps, $0, first: a) }
        var best = 0
        for n in 1..<ks.count where d[n] + 200 < d[best] { best = n }
        return ks[best]
    }

    /// Trajet en cours, comme un GPS : ce que tu fais (à pied, en bus, attente, deviné avec ta vitesse et ta
    /// position), l'étape du planning qui y correspond et le temps qu'il reste avant la fin, recalculé en continu.
    private func travelState(_ steps: [PlanStep], _ blk: (Int, Int), _ i: Int?, now: Date, minute: Double,
                             day: String) -> RoutineAttributes.ContentState {
        let (a, b) = blk
        let key = "\(day)|\(Int(steps[a].start))"
        if key != legKey { legKey = key; leg = a }
        let midnight = Calendar.current.startOfDay(for: now)
        let at = { (m: Double) in midnight.addingTimeInterval(m * 60) }

        let kind: String
        var j: Int?    // étape du planning qui correspond à ce que tu fais (nil : aucune, on vise la fin du trajet)
        var bus: Int?  // attente : le bus attendu
        switch guess.mode {
        case nil:
            // Pas encore de vitesse fiable : on suit le planning
            let p = i.flatMap { steps[$0].travel ? $0 : nil } ?? (minute < steps[a].start ? a : b)
            j = p
            kind = steps[p].kind
            if kind == "wait" { bus = (p...b).first { steps[$0].kind == "bus" } }
        case .walk?:
            kind = "walk"
            j = pick(steps, "walk", a, b)
        case .bus?:
            kind = "bus"
            j = pick(steps, "bus", a, b)
        case .wait?:
            // Immobile près de l'arrêt d'un bus à prendre : attente du bus ; ailleurs : simple pause
            bus = (min(max(leg, a), b)...b).first { k in
                guard steps[k].kind == "bus", let p = legStart(steps, k, first: a), let me = here else { return false }
                return me.distance(from: loc(p)) < 250
            }
            if let bus {
                kind = "wait"
                j = bus > a && steps[bus - 1].kind == "wait" ? bus - 1 : bus
            } else {
                kind = "pause"
                j = min(max(leg, a), b)
            }
        }
        if let j, guess.mode == .walk || guess.mode == .bus { leg = max(leg, j) }

        // Destination de ce que tu fais
        let t = j ?? b
        var (dest, name) = target(steps, t)
        if kind == "wait", let bus, steps[t].kind == "bus" {
            dest = legStart(steps, bus, first: a)
            name = steps[bus].detail.components(separatedBy: "→").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }

        // Ce qui vient après
        let base = kind == "wait" ? (bus ?? t) : t
        let n = steps[(base + 1)...].first { $0.kind != "sleep" && $0.kind != "wait" && $0.kind != kind }
        var nextText = ""
        if let n {
            let label = n.label.prefix(1).lowercased() + n.label.dropFirst()
            nextText = n.travel && n.kind != "bus" ? "Puis \(label)" : "Puis \(n.label) à \(Routine.clock(n.start))"
        }

        let planned = at(steps[t].end)
        let title = j.map { steps[$0].label } ?? (kind == "bus" ? "En bus" : "")
        var state = RoutineAttributes.ContentState(title: title, detail: "", kind: kind,
                                                   start: guess.mode == nil ? at(steps[t].start) : guess.since,
                                                   end: planned, next: nextText, travel: true)
        state.dest = name
        var eta = planned
        if kind == "wait" {
            // Le bus part à l'heure prévue (pas de temps réel sur les cars régionaux)
            eta = at(steps[bus ?? t].start)
            if eta < now.addingTimeInterval(30) {
                eta = now.addingTimeInterval(60)
                state.detail = "Bus en retard"
            }
            let waited = max(0, now.timeIntervalSince(state.start)), left = eta.timeIntervalSince(now)
            state.progress = waited + left > 0 ? waited / (waited + left) : 0
        } else if let dest, let me = here, me.horizontalAccuracy < 200 {
            let to = loc(dest)
            let factor = kind == "bus" ? 1.25 : 1.3  // détours des rues
            let left = me.distance(from: to) * factor
            if left < 30_000 {
                let total = legStart(steps, t, first: a).map { loc($0).distance(from: to) * factor } ?? left
                state.meters = left
                state.progress = total > 1 ? min(1, max(0, 1 - left / total)) : 0
                switch kind {
                case "bus":
                    let est = now.addingTimeInterval(left / (guess.busSpeed(now) ?? 8))
                    // Début du trajet en bus : l'horaire prévu compte encore pour moitié
                    let blend = guess.ride(now) < 180 && planned > now && steps[t].kind == "bus"
                    eta = blend ? est.addingTimeInterval(planned.timeIntervalSince(est) / 2) : est
                case "pause":
                    eta = now.addingTimeInterval(left / (steps[t].kind == "bus" ? 8 : 1.25))
                default:
                    eta = now.addingTimeInterval(left / guess.walkSpeed(now))
                }
            }
        }
        state.eta = eta
        state.end = max(eta, now.addingTimeInterval(30))
        busEnd = kind == "bus" ? dest.map(loc) : nil
        return state
    }

    /// Destination de l'étape : arrêt, collège ou maison (point et nom)
    private func target(_ steps: [PlanStep], _ i: Int) -> (PlanPoint?, String) {
        let s = steps[i]
        switch s.kind {
        case "bus":
            // L'étape du bus n'a pas de points : l'arrêt d'arrivée est le départ de la marche qui suit
            let name = s.detail.components(separatedBy: "→").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return (legEnd(steps, i), name)
        case "wait":
            return (s.pts.last, s.label.replacingOccurrences(of: "Attente à ", with: ""))
        default:
            var name = s.label
            for p in ["Marche jusqu’à la ", "Marche jusqu’à ", "Marche jusqu’au ", "Trajet vers ", "Retour à la "] where name.hasPrefix(p) {
                name = String(name.dropFirst(p.count))
                break
            }
            return (s.pts.last, name.prefix(1).uppercased() + name.dropFirst())
        }
    }

    // MARK: Hors étape

    /// Nuit, soirée, temps libre : l'activité reste affichée et annonce la prochaine étape
    private func idle(_ now: Date, today: String) {
        guard let plan else { return }
        if traveling { traveling = false; tune() }
        var prevEnd = Calendar.current.startOfDay(for: now)
        var upcoming: (Date, PlanStep)?
        var sleeping = false
        for d in plan.days {
            guard let m = PlanClock.midnight(d.day) else { continue }
            for s in daySteps(d) {
                let a = m.addingTimeInterval(s.start * 60), e = m.addingTimeInterval(s.end * 60)
                if s.kind == "sleep" && a <= now && now < e { sleeping = true }
                if e <= now && e > prevEnd { prevEnd = e }
                if s.kind != "sleep", a > now, upcoming == nil || a < upcoming!.0 { upcoming = (a, s) }
            }
        }
        guard let up = upcoming else { return }  // planning épuisé : on garde l'affichage jusqu'au prochain envoi
        let (at, n) = up
        let when = Calendar.current.isDate(at, inSameDayAs: now) ? Routine.clock(n.start) : "demain \(Routine.clock(n.start))"
        let wake = Wake.shared.next(plan).map { d -> String in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return String(format: "Réveil à %dh%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let state = RoutineAttributes.ContentState(
            title: sleeping ? "Bonne nuit" : "Temps libre",
            detail: sleeping ? (wake ?? "") : "",
            kind: sleeping ? "sleep" : "free", start: min(prevEnd, now), end: at,
            next: "Ensuite : \(n.kind == "lesson" ? "cours de \(n.label)" : n.label) à \(when)",
            travel: false)
        show(state, day: today)
    }

    /// Déplacement en cours (étapes de trajet qui se suivent) : bornes dans `steps`
    private func block(_ steps: [PlanStep], around i: Int) -> (Int, Int) {
        var a = i, b = i
        while a > 0, steps[a - 1].travel, steps[a].start - steps[a - 1].end < 2 { a -= 1 }
        while b < steps.count - 1, steps[b + 1].travel, steps[b + 1].start - steps[b].end < 2 { b += 1 }
        return (a, b)
    }

    /// Élève déjà à destination (à moins de 120 m de la fin du trajet) : index de l'étape d'après.
    /// L'arrivée vaut pour tout le déplacement.
    private func arrived(_ steps: [PlanStep], _ blk: (Int, Int), day: String) -> Int? {
        guard Prefs.arrival else { return nil }
        let (a, b) = blk
        guard b + 1 < steps.count else { return nil }
        let key = "\(day)|\(Int(steps[a].start))"
        if UserDefaults.standard.string(forKey: "arrived") == key { return b + 1 }
        guard let dest = steps[b].pts.last, let me = here, me.horizontalAccuracy < 100,
              me.distance(from: CLLocation(latitude: dest.lat, longitude: dest.lon)) < 120 else { return nil }
        UserDefaults.standard.set(key, forKey: "arrived")
        return b + 1
    }

    // MARK: Activité en direct (toujours la même)

    /// Assez de changement pour mettre à jour l'écran verrouillé (la navigation bouge à chaque position)
    private func changed(_ a: RoutineAttributes.ContentState?, _ b: RoutineAttributes.ContentState) -> Bool {
        guard let a else { return true }
        var x = a, y = b
        x.eta = nil; y.eta = nil; x.meters = nil; y.meters = nil; x.progress = nil; y.progress = nil
        x.end = y.end; x.start = y.start
        if x != y { return true }
        if abs((a.eta ?? a.end).timeIntervalSince(b.eta ?? b.end)) >= 8 { return true }
        if abs(a.end.timeIntervalSince(b.end)) >= 8 || abs(a.start.timeIntervalSince(b.start)) >= 8 { return true }
        if abs((a.meters ?? 0) - (b.meters ?? 0)) >= 20 { return true }
        return abs((a.progress ?? 0) - (b.progress ?? 0)) >= 0.02
    }

    private func show(_ state: RoutineAttributes.ContentState, day: String) {
        let content = ActivityContent(state: state, staleDate: nil)
        let all = Activity<RoutineAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        if let activity = all.first {
            // Une seule activité, toujours la même : les doublons éventuels disparaissent
            for extra in all.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
            guard changed(last, state) else { return }
            last = state
            Task { await activity.update(content) }
            return
        }
        // Aucune activité (première fois, ou arrêtée par iOS au bout de 8 h) : on en démarre une
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: RoutineAttributes(day: day), content: content, pushType: nil)
            last = state
        } catch {
            last = nil  // refusé hors de l'app : nouvel essai à la prochaine ouverture
        }
    }
}
