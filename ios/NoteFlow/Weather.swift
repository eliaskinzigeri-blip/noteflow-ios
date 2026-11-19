import Foundation

/// Météo des trajets (Open-Meteo : gratuit, sans compte ni clé) : pluie, neige ou froid aux heures où tu es dehors.
/// Prévisions heure par heure sur 2 jours, relues au plus une fois par heure.
final class Weather {
    static let shared = Weather()

    private struct Hourly: Codable {
        let time: [Double]
        let temperature_2m: [Double?]
        let precipitation_probability: [Double?]
        let precipitation: [Double?]
        let weather_code: [Int?]
    }
    private struct Reply: Codable { let hourly: Hourly }

    private let d = UserDefaults.standard
    private var hourly: Hourly?
    private var fetched = Date.distantPast
    private var busy = false

    private init() {
        if let data = d.data(forKey: "weather"), let h = try? JSONDecoder().decode(Hourly.self, from: data) {
            hourly = h
            fetched = Date(timeIntervalSince1970: d.double(forKey: "weatherAt"))
        }
    }

    func update(lat: Double, lon: Double) {
        guard !busy, Date().timeIntervalSince(fetched) > 3600 else { return }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", lon)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,precipitation,weather_code"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        guard let url = parts.url else { return }
        busy = true
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                // Échec (hors ligne) : nouvel essai dans 10 minutes
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                    self.fetched = Date().addingTimeInterval(-3000)
                    return
                }
                self.hourly = reply.hourly
                self.fetched = Date()
                self.d.set(try? JSONEncoder().encode(reply.hourly), forKey: "weather")
                self.d.set(self.fetched.timeIntervalSince1970, forKey: "weatherAt")
            }
        }.resume()
    }

    /// Résumé pour les heures de `from` à `to` : « Pluie vers 8h (70 %) · prends un parapluie · 6°C »
    func summary(_ from: Date, _ to: Date) -> String? {
        guard let h = hourly else { return nil }
        let a = from.timeIntervalSince1970 - 3599, b = max(to.timeIntervalSince1970, a + 3600)
        let idx = h.time.indices.filter { h.time[$0] >= a && h.time[$0] <= b }
        guard !idx.isEmpty else { return nil }
        let value = { (list: [Double?], i: Int) -> Double in i < list.count ? (list[i] ?? 0) : 0 }
        let temps = idx.compactMap { $0 < h.temperature_2m.count ? h.temperature_2m[$0] : nil }
        let deg = temps.min().map { "\(Int($0.rounded()))°C" } ?? ""
        let snow = idx.contains { i in i < h.weather_code.count && [71, 73, 75, 77, 85, 86].contains(h.weather_code[i] ?? 0) }
        if snow { return "Neige · couvre-toi bien · \(deg)" }
        if let w = idx.first(where: { value(h.precipitation_probability, $0) >= 50 || value(h.precipitation, $0) >= 0.3 }) {
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: h.time[w]))
            let p = Int(value(h.precipitation_probability, w))
            return "Pluie vers \(hour)h\(p > 0 ? " (\(p) %)" : "") · prends un parapluie · \(deg)"
        }
        if let t = temps.min(), t <= 3 { return "Froid : \(Int(t.rounded()))°C · mets un manteau chaud" }
        return deg.isEmpty ? nil : "\(deg) · pas de pluie"
    }
}
