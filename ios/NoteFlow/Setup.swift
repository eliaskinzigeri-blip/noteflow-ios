import ActivityKit
import CoreLocation
import Photos
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// « Activer les extensions » : tout ce que NoteFlow a besoin qu'on autorise ou qu'on ajoute (position « Toujours »,
/// notifications, activité en direct, alarme, Photos, Siri, boutons du Centre de contrôle, widget). Proposé à chaque
/// entrée dans l'app tant que quelque chose manque, et en haut de « Sur cet iPhone ».
/// iOS ne dit pas si Siri ou les boutons sont activés : ces étapes-là se cochent à la main.
@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        var done: Bool
        var manual = false     // à cocher soi-même (iOS ne le dit pas)
        var action = "Activer"
    }

    @Published private(set) var items: [Item] = []
    private let d = UserDefaults.standard

    var missing: [Item] { items.filter { !$0.done } }

    func refresh() async {
        var list: [Item] = []

        let loc = CLLocationManager().authorizationStatus
        list.append(Item(id: "location", title: "Position « Toujours »",
                         detail: "L’activité en direct suit tes trajets, et l’app reste éveillée pour le réveil et les notifications.",
                         icon: "location.fill", done: loc == .authorizedAlways,
                         action: loc == .notDetermined || loc == .authorizedWhenInUse ? "Activer" : "Réglages"))

        let notif = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        list.append(Item(id: "notifications", title: "Notifications",
                         detail: "Pars maintenant, bus raté, notes, informations et devoirs.",
                         icon: "bell.badge.fill", done: notif == .authorized || notif == .provisional,
                         action: notif == .notDetermined ? "Activer" : "Réglages"))

        list.append(Item(id: "live", title: "Activité en direct",
                         detail: "Ta routine et tes trajets sur l’écran verrouillé et dans la Dynamic Island.",
                         icon: "platter.filled.top.iphone", done: ActivityAuthorizationInfo().areActivitiesEnabled, action: "Réglages"))

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let state = AlarmManager.shared.authorizationState
            list.append(Item(id: "alarm", title: "Alarmes",
                             detail: "Le réveil intelligent sonne même en silencieux.",
                             icon: "alarm.fill", done: state == .authorized, action: state == .notDetermined ? "Activer" : "Réglages"))
        }
        #endif

        let photos = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        list.append(Item(id: "photos", title: "Photos (ajout)",
                         detail: "Enregistrer tes leçons reconstituées en image.",
                         icon: "photo.on.rectangle", done: photos == .authorized || photos == .limited,
                         action: photos == .notDetermined ? "Activer" : "Réglages"))

        list.append(Item(id: "siri", title: "Siri",
                         detail: "Réglages › Apps › NoteFlow › Siri : active tout. Puis : « Dis Siri, ma routine, mes devoirs ».",
                         icon: "mic.fill", done: d.bool(forKey: "setup.siri"), manual: true, action: "Réglages"))

        list.append(Item(id: "controls", title: "Boutons du Centre de contrôle",
                         detail: "Centre de contrôle › + › Ajouter une commande › NoteFlow : prochain cours, notes, devoirs, focus.",
                         icon: "switch.2", done: d.bool(forKey: "setup.controls"), manual: true, action: "Comment"))

        list.append(Item(id: "widget", title: "Widget",
                         detail: "Appui long sur l’écran d’accueil ou verrouillé › Modifier › Ajouter un widget › NoteFlow.",
                         icon: "square.grid.2x2.fill", done: d.bool(forKey: "setup.widget"), manual: true, action: "Comment"))
        items = list
    }

    /// Bouton « Activer » : la demande d'iOS quand elle est encore possible, sinon la page de NoteFlow dans Réglages
    func activate(_ item: Item) async {
        switch item.id {
        case "location" where item.action == "Activer":
            Routine.shared.askAlways()
        case "notifications" where item.action == "Activer":
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case "photos" where item.action == "Activer":
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        case "alarm" where item.action == "Activer":
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) { _ = try? await AlarmManager.shared.requestAuthorization() }
            #endif
        case "controls", "widget":
            break  // les explications sont sous le titre : il reste à cocher « C'est fait »
        default:
            openSettings()
        }
        await refresh()
    }

    func confirm(_ item: Item) {
        d.set(true, forKey: "setup.\(item.id)")
        Task { await refresh() }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Liste des extensions (dans la feuille d'accueil et dans « Sur cet iPhone »)
struct SetupList: View {
    @ObservedObject var setup = Setup.shared

    var body: some View {
        Section {
            ForEach(setup.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(item.done ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(item.done ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.body.weight(.semibold))
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        if !item.done {
                            HStack(spacing: 8) {
                                if item.action != "Comment" {
                                    Button(item.action) { Task { await setup.activate(item) } }
                                        .buttonStyle(.borderedProminent)
                                }
                                if item.manual {
                                    Button("C’est fait") { setup.confirm(item) }.buttonStyle(.bordered)
                                }
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Text("Siri, les boutons et le widget ne se vérifient pas tout seuls : coche « C’est fait » une fois ajoutés.")
        }
    }
}

/// Feuille proposée à l'entrée dans l'app tant qu'une extension manque
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var setup = Setup.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(setup.missing.isEmpty ? "Tout est activé. 🎉"
                         : "Encore \(setup.missing.count) chose\(setup.missing.count > 1 ? "s" : "") à activer pour que NoteFlow marche en entier.")
                }
                SetupList()
            }
            .navigationTitle("Activer les extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(setup.missing.isEmpty ? "OK" : "Plus tard") { dismiss() } }
            }
        }
        .task { await setup.refresh() }
    }
}
