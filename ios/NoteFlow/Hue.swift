import Foundation

struct HueRoom: Identifiable, Hashable { let id: String; let name: String }

enum HueError: LocalizedError {
    case button, unreachable, refused(String)
    var errorDescription: String? {
        switch self {
        case .button: return "Appuie sur le gros bouton rond du pont Hue, puis réessaie dans les 30 secondes."
        case .unreachable: return "Pont Hue introuvable : l’iPhone doit être sur le Wi-Fi de la maison."
        case .refused(let why): return "Le pont Hue a refusé : \(why)"
        }
    }
}

/// Pont Philips Hue sur le Wi-Fi de la maison (API locale). Le lever de soleil est programmé dans le pont
/// lui-même : il s'allume à l'heure même si l'iPhone est éteint ou loin.
enum Hue {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        return URLSession(configuration: c)
    }()

    private static func call(_ method: String, _ url: String, _ body: Any? = nil) async throws -> Any {
        guard let u = URL(string: url) else { throw HueError.unreachable }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, _) = try await session.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data)
            if let list = json as? [[String: Any]], let err = list.first?["error"] as? [String: Any] {
                if (err["type"] as? Int) == 101 { throw HueError.button }
                throw HueError.refused(err["description"] as? String ?? "erreur inconnue")
            }
            return json
        } catch let e as HueError {
            throw e
        } catch {
            throw HueError.unreachable
        }
    }

    /// Ponts du réseau (service de découverte de Philips)
    static func discover() async throws -> [String] {
        let json = try await call("GET", "https://discovery.meethue.com/")
        return (json as? [[String: Any]] ?? []).compactMap { $0["internalipaddress"] as? String }
    }

    /// Association : renvoie la clé d'accès une fois le bouton du pont pressé
    static func link(_ ip: String) async throws -> String {
        let json = try await call("POST", "http://\(ip)/api", ["devicetype": "noteflow#iphone"])
        guard let ok = (json as? [[String: Any]])?.first?["success"] as? [String: Any],
              let user = ok["username"] as? String else { throw HueError.refused("réponse inattendue") }
        return user
    }

    /// Pièces et zones
    static func rooms(_ ip: String, _ user: String) async throws -> [HueRoom] {
        let json = try await call("GET", "http://\(ip)/api/\(user)/groups")
        guard let groups = json as? [String: [String: Any]] else { throw HueError.refused("liste des pièces illisible") }
        return groups.compactMap { id, g in
            let type = g["type"] as? String ?? ""
            guard type == "Room" || type == "Zone" else { return nil }
            return HueRoom(id: id, name: g["name"] as? String ?? "Pièce \(id)")
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Supprime les programmes posés par NoteFlow
    static func clear(_ ip: String, _ user: String) async throws {
        let json = try await call("GET", "http://\(ip)/api/\(user)/schedules")
        for (id, s) in json as? [String: [String: Any]] ?? [:] where (s["name"] as? String ?? "").hasPrefix("NoteFlow") {
            _ = try? await call("DELETE", "http://\(ip)/api/\(user)/schedules/\(id)")
        }
    }

    /// Lever de soleil : lumière très douce et chaude `sunrise` minutes avant le réveil, qui monte jusqu'à
    /// la pleine lumière. À l'heure du réveil, avec `stimulate` : lumière blanche froide (elle coupe la
    /// mélatonine) et clignotements, répétés 5 minutes plus tard.
    static func schedule(_ ip: String, _ user: String, group: String, wake: Date, sunrise: Int, stimulate: Bool) async throws {
        try await clear(ip, user)
        let address = "/api/\(user)/groups/\(group)/action"
        let start = wake.addingTimeInterval(Double(-sunrise * 60))
        let ramp = min(65535, max(10, sunrise * 600 - 60))  // dixièmes de seconde
        var steps: [(String, Date, [String: Any])] = [
            ("NoteFlow aube", start, ["on": true, "bri": 1, "ct": 454, "transitiontime": 0]),
            ("NoteFlow lever", start.addingTimeInterval(5), ["on": true, "bri": 254, "ct": 280, "transitiontime": ramp]),
        ]
        if stimulate {
            steps.append(("NoteFlow debout", wake, ["on": true, "bri": 254, "ct": 153, "alert": "lselect", "transitiontime": 20]))
            steps.append(("NoteFlow rappel", wake.addingTimeInterval(300), ["on": true, "alert": "lselect"]))
        }
        for (name, at, body) in steps where at > Date() {
            _ = try await call("POST", "http://\(ip)/api/\(user)/schedules", [
                "name": name, "autodelete": true, "localtime": local.string(from: at),
                "command": ["address": address, "method": "PUT", "body": body],
            ])
        }
    }

    /// Essai en accéléré : 30 secondes de lever de soleil, puis la stimulation
    static func test(_ ip: String, _ user: String, group: String, stimulate: Bool) async throws {
        let url = "http://\(ip)/api/\(user)/groups/\(group)/action"
        _ = try await call("PUT", url, ["on": true, "bri": 1, "ct": 454, "transitiontime": 0])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try await call("PUT", url, ["bri": 254, "ct": 280, "transitiontime": 300])
        try await Task.sleep(nanoseconds: 31_000_000_000)
        if stimulate { _ = try await call("PUT", url, ["bri": 254, "ct": 153, "alert": "lselect", "transitiontime": 20]) }
    }
}
