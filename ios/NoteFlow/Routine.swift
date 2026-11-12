import ActivityKit
import CoreLocation
import Foundation
import UIKit

/// Planning envoyé par le site (frontend/routine.js, pushNative) : les étapes du jour et du lendemain.
struct PlanPoint: Codable { let lat: Double; let lon: Double }
struct PlanStep: Codable {
    let label: String
    let detail: String
    let start: Double  // minutes depuis minuit
    let end: Double
    let kind: String
    let travel: Bool
    let pts: [PlanPoint]
}
struct PlanDay: Codable { let day: String; let steps: [PlanStep] }
struct Plan: Codable {
    let type: String
    let home: PlanPoint?
    let school: PlanPoint?
    let days: [PlanDay]
}

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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        startLocation()
    }

    // MARK: Planning reçu du site

    func receive(_ data: Data) {
        guard let p = try? JSONDecoder().decode(Plan.self, from: data), p.type == "plan" else { return }
        plan = p
        UserDefaults.standard.set(data, forKey: "plan")
        startLocation()
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
        default:
            break
        }
    }

    /// Précis pendant un trajet, économe le reste du temps (l'app reste éveillée pour changer d'étape).
    private func tune() {
        location.desiredAccuracy = traveling ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        location.distanceFilter = traveling ? 10 : 100
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

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded()) % 1440
        return String(format: "%dh%02d", m / 60, m % 60)
    }

    func refresh() {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let minute = now.timeIntervalSince(midnight) / 60
        let today = Routine.dayFormat.string(from: now)
        guard let steps = plan?.days.first(where: { $0.day == today })?.steps,
              let i = steps.firstIndex(where: { $0.start <= minute && minute < $0.end && $0.kind != "sleep" }) else {
            finish()
            return
        }
        let cur = steps[i]
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
        var a = i, b = i
        while a > 0, steps[a - 1].travel, steps[a].start - steps[a - 1].end < 2 { a -= 1 }
        while b < steps.count - 1, steps[b + 1].travel, steps[b + 1].start - steps[b].end < 2 { b += 1 }
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
