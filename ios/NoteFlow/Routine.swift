import ActivityKit
import CoreLocation
import Foundation
import UIKit
import WidgetKit

/// Tient à jour une seule activité en direct, affichée en permanence : l'étape en cours, la navigation
/// (« arrivée dans », recalculée avec ta vitesse) et la mini-carte pendant les trajets, les séances Prépa Basket,
/// le temps libre et la nuit. La localisation en arrière-plan garde l'app éveillée pour changer d'étape ;
/// si iOS ferme l'app, les changements de position importants et les zones maison/collège la relancent.
final class Routine: NSObject, CLLocationManagerDelegate {
    static let shared = Routine()

    private let location = CLLocationManager()
    private var plan: Plan?
    private var here: CLLocation?
    private var speed: Double = 0  // vitesse lissée (m/s)
    private var timer: Timer?
    private var last: RoutineAttributes.ContentState?
    private var traveling = false
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

    /// Précis pendant un trajet, économe le reste du temps (l'app reste éveillée pour changer d'étape).
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
        if l.speed >= 0 && l.horizontalAccuracy < 65 { speed = speed == 0 ? l.speed : speed * 0.7 + l.speed * 0.3 }
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
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let minute = now.timeIntervalSince(midnight) / 60
        let today = PlanClock.dayFormat.string(from: now)
        Wake.shared.sync(plan)
        guard let day = plan?.days.first(where: { $0.day == today }) else { idle(now, today: today); return }
        let steps = daySteps(day)
        let covering = steps.indices.filter { steps[$0].start <= minute && minute < steps[$0].end && steps[$0].kind != "sleep" }
        guard let i = covering.first(where: { steps[$0].kind == "session" }) ?? covering.first else {
            idle(now, today: today)
            return
        }
        let cur = steps[i]

        // Arrivée détectée : trajet fini en avance, on passe à l'étape qui suit le déplacement
        if cur.travel, let after = arrived(steps, around: i, day: today) {
            if traveling { traveling = false; tune() }
            let step = steps[after]
            let next = steps[(after + 1)...].first { $0.kind != "sleep" }
            let startAt = midnight.addingTimeInterval(step.start * 60)
            let state = RoutineAttributes.ContentState(
                title: step.label, detail: "Tu es arrivé · début à \(Routine.clock(step.start))",
                kind: step.kind, start: now, end: max(startAt, now.addingTimeInterval(60)),
                next: next.map { "Puis \($0.label) à \(Routine.clock($0.start))" } ?? "", travel: false, path: [], me: nil)
            show(state, day: today)
            return
        }
        if cur.travel != traveling { traveling = cur.travel; tune() }

        // Prochaine étape, pour savoir ce qui vient après
        let next = steps[(i + 1)...].first { $0.start >= cur.end - 0.5 && $0.kind != "sleep" && $0.kind != cur.kind }
        let nextText = next.map { "Puis \($0.label) à \(Routine.clock($0.start))" } ?? ""

        let start = midnight.addingTimeInterval(cur.start * 60)
        let end = midnight.addingTimeInterval(max(cur.end, cur.start + 1) * 60)
        var state = RoutineAttributes.ContentState(title: cur.label, detail: cur.detail, kind: cur.kind, start: start, end: end,
                                                   next: nextText, travel: cur.travel, path: [], me: nil)
        if cur.travel {
            (state.path, state.me) = trip(steps, around: i)
            navigate(&state, steps: steps, i: i, now: now)
        }
        show(state, day: today)
    }

    // MARK: Navigation

    /// Destination de l'étape : arrêt, collège ou maison (point et nom)
    private func target(_ steps: [PlanStep], _ i: Int) -> (PlanPoint?, String) {
        let s = steps[i]
        switch s.kind {
        case "bus":
            // L'étape du bus n'a pas de points : l'arrêt d'arrivée est le départ de la marche qui suit
            let name = s.detail.components(separatedBy: "→").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return (i + 1 < steps.count ? steps[i + 1].pts.first : nil, name)
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

    /// Heure d'arrivée recalculée avec la position et la vitesse : marche (4,5 km/h par défaut, ta vitesse si tu
    /// marches plus vite), bus (horaire prévu, ou ta vitesse dans le bus s'il roule). Attente : départ du bus.
    private func navigate(_ state: inout RoutineAttributes.ContentState, steps: [PlanStep], i: Int, now: Date) {
        let s = steps[i]
        let (dest, name) = target(steps, i)
        state.dest = name
        guard s.kind != "wait" else {
            state.eta = state.end  // le bus part à l'heure prévue (pas de temps réel sur les cars régionaux)
            return
        }
        guard let dest, let me = here, me.horizontalAccuracy < 200 else { state.eta = state.end; return }
        let to = CLLocation(latitude: dest.lat, longitude: dest.lon)
        let factor = s.kind == "bus" ? 1.25 : 1.3  // détours des rues
        let left = me.distance(from: to) * factor
        guard left < 30_000 else { state.eta = state.end; return }

        // Départ de l'étape : point précédent (sinon la maison) pour la barre de progression
        let from = s.pts.count > 1 ? s.pts.first : (i > 0 ? steps[i - 1].pts.last : nil) ?? plan?.home
        let total = from.map { CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: to) * factor } ?? left
        state.meters = left
        state.progress = total > 1 ? min(1, max(0, 1 - left / total)) : 0

        let eta: Date
        if s.kind == "bus" {
            eta = speed > 3 ? now.addingTimeInterval(left / speed) : max(state.end, now.addingTimeInterval(left / 9))
        } else {
            let v = speed > 0.7 ? min(max(speed, 1.0), 3.0) : 1.25
            eta = now.addingTimeInterval(left / v)
        }
        state.eta = eta
        state.end = max(state.end, eta)
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
            travel: false, path: [], me: nil)
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
    private func arrived(_ steps: [PlanStep], around i: Int, day: String) -> Int? {
        guard Prefs.arrival else { return nil }
        let (a, b) = block(steps, around: i)
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
        x.eta = nil; y.eta = nil; x.meters = nil; y.meters = nil; x.progress = nil; y.progress = nil; x.me = nil; y.me = nil
        x.end = y.end
        if x != y { return true }
        if abs((a.eta ?? a.end).timeIntervalSince(b.eta ?? b.end)) >= 8 { return true }
        if abs((a.progress ?? 0) - (b.progress ?? 0)) >= 0.02 { return true }
        if let p = a.me, let q = b.me, hypot(p.x - q.x, p.y - q.y) >= 0.02 { return true }
        return (a.me == nil) != (b.me == nil)
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

    // MARK: Mini-carte

    /// Tracé du trajet en cours (étapes de déplacement qui se suivent) et position actuelle, ramenés entre 0 et 1.
    private func trip(_ steps: [PlanStep], around i: Int) -> ([MapPoint], MapPoint?) {
        let (a, b) = block(steps, around: i)
        var pts = steps[a...b].flatMap { $0.pts }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        // Trajet du matin : il part de la maison, que l'étape « Marche jusqu'à l'arrêt » ne donne pas
        if let h = plan?.home, let first = pts.first, let lastPt = pts.last {
            let home = CLLocation(latitude: h.lat, longitude: h.lon)
            let far = { (c: CLLocationCoordinate2D) in home.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) > 150 }
            if far(first) && far(lastPt) { pts.insert(CLLocationCoordinate2D(latitude: h.lat, longitude: h.lon), at: 0) }
        }
        // Points en double (arrivée d'une étape = départ de la suivante)
        var clean: [CLLocationCoordinate2D] = []
        for p in pts {
            if let q = clean.last, CLLocation(latitude: q.latitude, longitude: q.longitude)
                .distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude)) < 20 { continue }
            clean.append(p)
        }
        var all = clean
        var mine: CLLocationCoordinate2D?
        if let h = here?.coordinate, let c = clean.first,
           CLLocation(latitude: h.latitude, longitude: h.longitude).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 20_000 {
            mine = h
            all.append(h)
        }
        guard !all.isEmpty else { return ([], nil) }

        // Projection simple (degrés de longitude raccourcis selon la latitude), même échelle sur les deux axes
        let lat0 = all.map { $0.latitude }.reduce(0, +) / Double(all.count)
        let k = cos(lat0 * .pi / 180)
        let xs = all.map { $0.longitude * k }, ys = all.map { $0.latitude }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let span = max(maxX - minX, maxY - minY, 0.002)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let pad = 0.14
        let norm = { (c: CLLocationCoordinate2D) -> MapPoint in
            MapPoint(x: 0.5 + (c.longitude * k - cx) / span * (1 - 2 * pad),
                     y: 0.5 - (c.latitude - cy) / span * (1 - 2 * pad))
        }
        return (Array(clean.map(norm).prefix(24)), mine.map(norm))
    }
}
