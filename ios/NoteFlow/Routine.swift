import ActivityKit
import CoreLocation
import Foundation
import UIKit
import WidgetKit

/// Tient l'activité en direct à jour : l'étape en cours en texte, et la mini-carte pendant les trajets.
/// La localisation en arrière-plan garde l'app éveillée : l'activité change d'étape même NoteFlow fermé.
final class Routine: NSObject, CLLocationManagerDelegate {
    static let shared = Routine()

    private let location = CLLocationManager()
    private var plan: Plan?
    private var here: CLLocation?
    private var timer: Timer?
    private var last: RoutineAttributes.ContentState?
    private var traveling = false

    private override init() {
        super.init()
        location.delegate = self
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .otherNavigation
        if let data = UserDefaults.standard.data(forKey: "plan") { plan = try? JSONDecoder().decode(Plan.self, from: data) }
        _ = Reminders.shared  // délégué des notifications (bannière même app ouverte)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        startLocation()
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
            tune()
            location.startUpdatingLocation()
            watchPlaces()
        default:
            break
        }
    }

    /// Précis pendant un trajet, économe le reste du temps (l'app reste éveillée pour changer d'étape).
    private func tune() {
        location.desiredAccuracy = traveling ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        location.distanceFilter = traveling ? 10 : 100
    }

    /// Zones de la maison et du collège : iOS réveille l'app en y entrant, même si elle a été fermée
    private func watchPlaces() {
        for r in location.monitoredRegions where r.identifier == "home" || r.identifier == "school" { location.stopMonitoring(for: r) }
        guard Prefs.arrival, location.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for (id, p) in [("home", plan?.home), ("school", plan?.school)] {
            guard let p else { continue }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: 150, identifier: id)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            location.startMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if let l = manager.location { here = l }
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        here = locations.last
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: Activité en direct

    private static let clock = PlanClock.clock

    func refresh() {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let minute = now.timeIntervalSince(midnight) / 60
        let today = PlanClock.dayFormat.string(from: now)
        Wake.shared.sync(plan)
        guard let steps = plan?.days.first(where: { $0.day == today })?.steps,
              let i = steps.firstIndex(where: { $0.start <= minute && minute < $0.end && $0.kind != "sleep" }) else {
            finish()
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

        var path: [MapPoint] = []
        var me: MapPoint?
        if cur.travel { (path, me) = trip(steps, around: i) }

        let start = midnight.addingTimeInterval(cur.start * 60)
        let end = midnight.addingTimeInterval(max(cur.end, cur.start + 1) * 60)
        let state = RoutineAttributes.ContentState(title: cur.label, detail: cur.detail, kind: cur.kind, start: start, end: end,
                                                   next: nextText, travel: cur.travel, path: path, me: me)
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
    /// L'arrivée vaut pour tout le déplacement et n'est annoncée qu'une fois.
    private func arrived(_ steps: [PlanStep], around i: Int, day: String) -> Int? {
        guard Prefs.arrival else { return nil }
        let (a, b) = block(steps, around: i)
        guard b + 1 < steps.count else { return nil }
        let key = "\(day)|\(Int(steps[a].start))"
        if UserDefaults.standard.string(forKey: "arrived") == key { return b + 1 }
        guard let dest = steps[b].pts.last, let me = here, me.horizontalAccuracy < 100,
              me.distance(from: CLLocation(latitude: dest.lat, longitude: dest.lon)) < 120 else { return nil }
        UserDefaults.standard.set(key, forKey: "arrived")
        let near = { (p: PlanPoint?) -> Bool in p.map { me.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) < 300 } ?? false }
        let place = near(plan?.school) ? "Arrivé au collège" : near(plan?.home) ? "Arrivé à la maison" : "Arrivé"
        let n = steps[b + 1]
        let what = n.kind == "lesson" ? "Cours de \(n.label)" : n.label
        Reminders.shared.now(id: key, title: place, body: "\(what) à \(Routine.clock(n.start))")
        return b + 1
    }

    private func show(_ state: RoutineAttributes.ContentState, day: String) {
        let content = ActivityContent(state: state, staleDate: state.end.addingTimeInterval(120))
        let running = Activity<RoutineAttributes>.activities.filter { $0.activityState == .active }
        if let activity = running.first {
            guard state != last else { return }
            last = state
            Task { await activity.update(content) }
            return
        }
        // Une activité ne peut démarrer que NoteFlow ouvert : elle reprend à la prochaine ouverture
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            _ = try Activity.request(attributes: RoutineAttributes(day: day), content: content, pushType: nil)
            last = state
        } catch {
            last = nil
        }
    }

    private func finish() {
        last = nil
        if traveling { traveling = false; tune() }
        for activity in Activity<RoutineAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
