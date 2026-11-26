import Combine
import Foundation

/// Réglages propres à l'iPhone (écran « Sur cet iPhone » ouvert depuis Ma routine).
/// Les clés sont aussi celles des @AppStorage de SettingsView.
enum Prefs {
    static let d = UserDefaults.standard

    static func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

    /// Rappels personnels en notifications de l'iPhone (jamais les étapes de la routine : l'activité en direct les montre)
    static var notify: Bool { flag("notify", true) }
    /// Notifications de l'école (nouvelle note, information, devoirs pour demain, évaluation) : voir Inbox.swift
    static var school: Bool { flag("notifySchool", true) }
    /// Arrivée au collège et à la maison détectée par la position
    static var arrival: Bool { flag("arrival", true) }
    /// « Pars maintenant » (heure de départ calculée avec ta position) et bus raté (plan B)
    static var leave: Bool { flag("leaveAlert", true) }

    /// Réveil intelligent : désactivé tant que l'élève ne l'a pas allumé
    static var wakeOn: Bool { flag("wakeOn", false) }
    static var schoolOnly: Bool { flag("wakeSchoolOnly", true) }
    /// "phone", "hue" ou "both"
    static var wakeMode: String { d.string(forKey: "wakeMode") ?? "phone" }
    static var sunrise: Int { d.object(forKey: "sunrise") == nil ? 20 : d.integer(forKey: "sunrise") }
    static var stimulate: Bool { flag("stimulate", true) }

    static var hueIP: String { d.string(forKey: "hueIP") ?? "" }
    static var hueUser: String { d.string(forKey: "hueUser") ?? "" }
    static var hueGroup: String { d.string(forKey: "hueGroup") ?? "" }
    static var hueReady: Bool { !hueIP.isEmpty && !hueUser.isEmpty && !hueGroup.isEmpty }
}

/// État de l'interface native (fiche des réglages par-dessus le site).
final class NativeUI: ObservableObject {
    static let shared = NativeUI()
    @Published var settings = false
    @Published var focusAdd = false  // panneau « Focus » du bouton du Centre de contrôle
    @Published var setup = false     // « Activer les extensions » (à l'entrée dans l'app, s'il en manque)
}
