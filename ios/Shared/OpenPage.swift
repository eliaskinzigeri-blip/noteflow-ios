import AppIntents
import Foundation

/// Ouvre NoteFlow à une page du site (« notes », « tasks », « focus »…). Sert aux boutons du Centre de contrôle et
/// de l'écran verrouillé : un lien noteflow:// ne s'y ouvre pas, une action « ouvrir l'app » si. Dans l'app et dans
/// l'extension : la page demandée passe par le stockage partagé, l'app l'ouvre en arrivant au premier plan.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir NoteFlow"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Page") var page: String

    init() {}
    init(page: String) { self.page = page }

    static let notice = Notification.Name("NoteFlowOpenPage")

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.defaults.set(page, forKey: "openPage")
        NotificationCenter.default.post(name: OpenPageIntent.notice, object: nil)
        return .result()
    }

    /// Page demandée par un bouton, à ouvrir une seule fois (lue par l'app)
    static func take() -> String? {
        guard let page = SharedStore.defaults.string(forKey: "openPage"), !page.isEmpty else { return nil }
        SharedStore.defaults.removeObject(forKey: "openPage")
        return page.allSatisfy({ $0.isLetter || $0 == "/" || $0 == "-" }) ? page : nil
    }
}
