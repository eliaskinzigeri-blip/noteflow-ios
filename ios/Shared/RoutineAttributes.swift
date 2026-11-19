import ActivityKit
import Foundation

/// Activité en direct de la routine : l'étape en cours, et la navigation pendant les déplacements.
/// Trajet : `kind` vaut « walk » (à pied), « bus », « wait » (attente du bus) ou « pause » (arrêté ailleurs),
/// deviné par l'app avec ta vitesse et ta position. Tout tient dans l'état (moins de 4 Ko).
struct RoutineAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var kind: String
        var start: Date
        var end: Date
        var next: String
        var travel: Bool
        // Navigation (trajets) : arrivée recalculée, destination, distance restante, avancement
        var eta: Date? = nil
        var dest: String? = nil
        var meters: Double? = nil
        var progress: Double? = nil
        // Lignes en plus sous l'étape (sac du lendemain : cours, devoirs, évaluations) et météo du trajet
        var lines: [String]? = nil
        var weather: String? = nil
    }

    var day: String
}
