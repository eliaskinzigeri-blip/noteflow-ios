import SwiftUI

/// Fiche « Sur cet iPhone », ouverte depuis Ma routine (bouton Régler) : rappels, arrivée, widget,
/// réveil intelligent et lumières Philips Hue.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("notify") private var notify = true
    @AppStorage("arrival") private var arrival = true
    @AppStorage("wakeOn") private var wakeOn = false
    @AppStorage("wakeSchoolOnly") private var schoolOnly = true
    @AppStorage("wakeMode") private var wakeMode = "phone"
    @AppStorage("sunrise") private var sunrise = 20
    @AppStorage("stimulate") private var stimulate = true
    @AppStorage("hueIP") private var hueIP = ""
    @AppStorage("hueUser") private var hueUser = ""
    @AppStorage("hueGroup") private var hueGroup = ""
    @AppStorage("hueGroupName") private var hueGroupName = ""

    @State private var bridges: [String] = []
    @State private var rooms: [HueRoom] = []
    @State private var working = ""
    @State private var message = ""
    @State private var manualIP = ""

    private var nextWake: Date? { Wake.shared.next(Routine.shared.current) }

    var body: some View {
        NavigationStack {
            Form {
                wakeSection
                if wakeOn && wakeMode != "phone" { hueSection }
                Section {
                    Toggle("Rappels de ta routine", isOn: $notify)
                } footer: {
                    Text("Notifications de l’iPhone à chaque étape, et « Départ dans 5 min » avant chaque trajet. Si tu les reçois en double, coupe les notifications du raccourci NoteFlow de l’écran d’accueil.")
                }
                Section {
                    Toggle("Arrivée détectée", isOn: $arrival)
                } footer: {
                    Text("En arrivant au collège ou à la maison, NoteFlow passe tout seul à l’étape suivante. Il faut la position « Toujours » (Réglages › NoteFlow › Position).")
                }
                Section("Widget") {
                    Label("Maintiens ton doigt sur l’écran d’accueil ou l’écran verrouillé, touche Modifier, puis Ajouter un widget et choisis NoteFlow.", systemImage: "square.grid.2x2")
                        .font(.callout)
                }
            }
            .navigationTitle("Sur cet iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .onDisappear { Routine.shared.settingsChanged() }
        }
    }

    // MARK: Réveil

    private var wakeSection: some View {
        Section {
            Toggle("Réveil intelligent", isOn: $wakeOn)
            if wakeOn {
                Picker("Pour te réveiller", selection: $wakeMode) {
                    Text("Alarme de l’iPhone").tag("phone")
                    Text("Lumières Hue").tag("hue")
                    Text("Les deux").tag("both")
                }
                Toggle("Seulement les jours de cours", isOn: $schoolOnly)
                LabeledContent("Prochain réveil", value: nextWake.map(Self.when) ?? "aucun prévu")
                if wakeMode != "hue" && !PhoneAlarm.available {
                    Text("L’alarme de l’iPhone demande iOS 26 ou plus récent.").font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Réveil")
        } footer: {
            Text("L’heure suit ton planning : ton premier cours, ton temps de préparation et ton bus. Si un prof est absent en première heure, le réveil recule tout seul.")
        }
    }

    // MARK: Philips Hue

    @ViewBuilder private var hueSection: some View {
        Section {
            if hueUser.isEmpty {
                if bridges.isEmpty {
                    Button { Task { await find() } } label: { Label("Chercher le pont Hue", systemImage: "magnifyingglass") }
                    HStack {
                        TextField("ou son adresse IP (ex. 192.168.1.20)", text: $manualIP)
                            .keyboardType(.decimalPad)
                        Button("Utiliser") { bridges = [manualIP.trimmingCharacters(in: .whitespaces)] }
                            .disabled(manualIP.isEmpty)
                    }
                } else {
                    Picker("Pont", selection: $hueIP) { ForEach(bridges, id: \.self) { Text($0).tag($0) } }
                    Text("Appuie sur le gros bouton rond du pont Hue, puis touche Associer dans les 30 secondes.").font(.callout)
                    Button { Task { await link() } } label: { Label("Associer", systemImage: "link") }
                        .disabled(hueIP.isEmpty)
                }
            } else {
                Picker("Pièce à allumer", selection: $hueGroup) {
                    if hueGroup.isEmpty { Text("Choisis…").tag("") }
                    ForEach(rooms) { Text($0.name).tag($0.id) }
                    if !hueGroup.isEmpty && !rooms.contains(where: { $0.id == hueGroup }) { Text(hueGroupName).tag(hueGroup) }
                }
                .onChange(of: hueGroup) { _, id in hueGroupName = rooms.first { $0.id == id }?.name ?? hueGroupName }
                Stepper("Lever de soleil : \(sunrise) min", value: $sunrise, in: 5...60, step: 5)
                Toggle("Stimulation au réveil", isOn: $stimulate)
                Button { Task { await test() } } label: { Label("Essayer maintenant (30 s)", systemImage: "sun.max") }
                    .disabled(hueGroup.isEmpty)
                Button("Dissocier le pont", role: .destructive) {
                    hueUser = ""; hueGroup = ""; hueGroupName = ""; rooms = []; bridges = []
                }
            }
            if !working.isEmpty { HStack { ProgressView(); Text(working) } }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Lumières Philips Hue")
        } footer: {
            Text("La lumière monte doucement avant l’heure du réveil, comme un lever de soleil. Avec la stimulation, elle passe en blanc froid et clignote à l’heure pile, puis 5 minutes après. Le programme est enregistré dans le pont : il marche même si ton iPhone est éteint. L’iPhone doit juste passer sur le Wi-Fi de la maison après chaque changement d’horaire.")
        }
        .task { if !hueUser.isEmpty && rooms.isEmpty { await loadRooms() } }
    }

    private func run(_ label: String, _ job: () async throws -> Void) async {
        working = label
        message = ""
        do { try await job() } catch { message = error.localizedDescription }
        working = ""
    }

    private func find() async {
        await run("Recherche du pont…") {
            bridges = try await Hue.discover()
            if bridges.isEmpty { message = "Aucun pont trouvé : entre son adresse IP (app Hue › Paramètres › Ponts Hue › ⓘ)." }
            if hueIP.isEmpty || !bridges.contains(hueIP) { hueIP = bridges.first ?? "" }
        }
    }

    private func link() async {
        await run("Association…") {
            // Le bouton du pont reste actif 30 secondes : on réessaie pendant ce temps
            for attempt in 0..<10 {
                do {
                    hueUser = try await Hue.link(hueIP)
                    await loadRooms()
                    message = "Pont associé. Choisis la pièce de ta chambre."
                    return
                } catch HueError.button where attempt < 9 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private func loadRooms() async {
        await run("Lecture des pièces…") { rooms = try await Hue.rooms(hueIP, hueUser) }
    }

    private func test() async {
        await run("Lever de soleil en accéléré…") {
            try await Hue.test(hueIP, hueUser, group: hueGroup, stimulate: stimulate)
            message = "Essai terminé."
        }
    }

    private static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'aujourd’hui à' H'h'mm" : Calendar.current.isDateInTomorrow(d) ? "'demain à' H'h'mm" : "EEEE 'à' H'h'mm"
        return f.string(from: d)
    }
}
