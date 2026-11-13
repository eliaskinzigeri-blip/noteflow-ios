import ActivityKit
import Foundation

/// Point de la mini-carte, ramené entre 0 et 1 (x vers l'est, y vers le sud).
struct MapPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Activité en direct de la routine : l'étape en cours, et le tracé du trajet pendant les déplacements.
/// Tout tient dans l'état (moins de 4 Ko) : pas besoin de partager de fichier entre l'app et l'extension.
struct RoutineAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var kind: String
        var start: Date
        var end: Date
        var next: String
        var travel: Bool
        var path: [MapPoint]
        var me: MapPoint?
        // Navigation (trajets) : arrivée recalculée, destination, distance restante, avancement
        var eta: Date? = nil
        var dest: String? = nil
        var meters: Double? = nil
        var progress: Double? = nil
    }

    var day: String
}
