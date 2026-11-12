import Foundation

/// Planning envoyé par le site (frontend/routine.js, pushNative) : les étapes du jour et du lendemain,
/// l'heure de réveil de chaque jour et les rappels à programmer.
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
struct PlanDay: Codable {
    let day: String
    let wake: Double?   // réveil (minutes depuis minuit), recalculé si un prof est absent
    let school: Bool?   // jour de cours
    let steps: [PlanStep]
}
struct PlanAlert: Codable { let at: String; let title: String; let body: String }
struct Plan: Codable {
    let type: String
    let home: PlanPoint?
    let school: PlanPoint?
    let days: [PlanDay]
    let alerts: [PlanAlert]?
}

enum PlanClock {
    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Minuit du jour « yyyy-MM-dd » (heure locale).
    static func midnight(_ day: String) -> Date? {
        dayFormat.date(from: day).map { Calendar.current.startOfDay(for: $0) }
    }

    static func clock(_ minutes: Double) -> String {
        let m = ((Int(minutes.rounded()) % 1440) + 1440) % 1440
        return String(format: "%dh%02d", m / 60, m % 60)
    }
}

/// Stockage partagé entre l'app et le widget (groupe d'apps). SideStore renomme le groupe à l'installation
/// (il y ajoute l'identifiant de l'équipe Apple) : on lit le vrai nom dans le profil de l'app.
enum SharedStore {
    static let base = "group.com.noteflow.app"

    static let defaults: UserDefaults = {
        for id in groups() where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
            if let d = UserDefaults(suiteName: id) { return d }
        }
        return .standard
    }()

    private static func groups() -> [String] {
        var out: [String] = []
        let here = Bundle.main.bundleURL
        // L'extension est dans NoteFlow.app/PlugIns/ : on regarde aussi l'app
        for dir in [here, here.deletingLastPathComponent().deletingLastPathComponent()] {
            if let info = NSDictionary(contentsOf: dir.appendingPathComponent("Info.plist")),
               let g = info["ALTAppGroups"] as? [String] { out += g }
            out += profileGroups(dir.appendingPathComponent("embedded.mobileprovision"))
        }
        out.append(base)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Groupes d'apps du profil d'installation (plist signé : on lit le XML qu'il contient).
    private static func profileGroups(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
              let a = text.range(of: "<?xml"), let b = text.range(of: "</plist>"), a.lowerBound < b.upperBound,
              let xml = String(text[a.lowerBound..<b.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }
}
