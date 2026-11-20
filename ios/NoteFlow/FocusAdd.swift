import SwiftUI

/// Focus ajouté depuis l'iPhone, comme une puce NFC : la fonction « noteflow-focus » (q=add) ajoute des minutes au
/// focus en cours, ou en lance un s'il n'y en a pas. C'est le même temps que celui des puces : une puce « − » le retire.
enum FocusAPI {
    private static let base = "https://ieagkscoaoutrvsgihat.supabase.co/functions/v1/noteflow-focus"

    struct State: Decodable {
        let active: Bool
        let until: String?
        let next: String?
        let error: String?
    }

    private static func url(_ q: String, minutes: Int? = nil) -> URL? {
        var parts = URLComponents(string: base)
        parts?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "k", value: Inbox.shared.key)]
            + (minutes.map { [URLQueryItem(name: "m", value: String($0))] } ?? [])
        return parts?.url
    }

    static func state() async -> State? {
        guard Inbox.shared.linked, let url = url("state") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// Ajoute (minutes > 0) ou retire (minutes < 0) du temps de focus ; renvoie l'état après le changement
    static func add(_ minutes: Int) async throws -> State {
        guard Inbox.shared.linked, let url = url("add", minutes: minutes) else {
            throw NSError(domain: "Focus", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ouvre NoteFlow connecté à ton compte : la liaison se fait toute seule."])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let state = try? JSONDecoder().decode(State.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let state else {
            throw NSError(domain: "Focus", code: 1, userInfo: [NSLocalizedDescriptionKey: state?.error ?? "Le focus n’a pas pu être changé. Réessaie."])
        }
        return state
    }
}

/// Panneau « Focus » (bouton du Centre de contrôle) : combien de minutes ajouter, ou lancer un focus s'il n'y en a pas.
struct FocusAddView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("focusAddMinutes") private var minutes = 30
    @State private var current: FocusAPI.State?
    @State private var loaded = false
    @State private var busy = false
    @State private var message = ""

    private let quick = [15, 30, 45, 60, 90, 120]
    private var active: Bool { current?.active == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !Inbox.shared.linked {
                        Text("Ouvre NoteFlow connecté à ton compte : la liaison avec ton focus se fait toute seule en quelques secondes.")
                    } else if !loaded {
                        HStack(spacing: 10) { ProgressView(); Text("Lecture de ton focus…") }
                    } else if let c = current, c.active {
                        Label("Focus en cours jusqu’à \(c.until ?? "?")", systemImage: "timer")
                    } else {
                        Label("Pas de focus en cours\(current?.next.map { " · prochain \($0)" } ?? "")", systemImage: "moon.zzz")
                    }
                }

                Section {
                    Stepper(value: $minutes, in: 5...240, step: 5) {
                        Text("\(minutes) min").font(.title2.weight(.semibold)).monospacedDigit()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(quick, id: \.self) { m in
                            Button("\(m) min") { minutes = m }
                                .buttonStyle(.bordered)
                                .tint(minutes == m ? Color.accentColor : Color.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text(active ? "Ajouter au focus" : "Lancer un focus")
                } footer: {
                    Text("C’est le même temps que celui des puces NFC : une puce « − » peut le retirer.")
                }

                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else {
                                Text(active ? "Ajouter \(minutes) min" : "Lancer \(minutes) min de focus").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || !Inbox.shared.linked)
                    if !message.isEmpty {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .task {
                current = await FocusAPI.state()
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() async {
        busy = true
        message = ""
        do {
            let state = try await FocusAPI.add(minutes)
            current = state
            message = state.active ? "C’est parti : focus jusqu’à \(state.until ?? "?")." : "Focus changé."
            WebView.focusChanged()  // le bandeau du focus dans NoteFlow suit
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }
}
