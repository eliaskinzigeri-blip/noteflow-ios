import SwiftUI

@main
struct NoteFlowApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var ui = NativeUI.shared

    init() {
        _ = Routine.shared  // localisation et activité en direct prêtes dès le lancement (aussi en arrière-plan)
    }

    var body: some Scene {
        WindowGroup {
            WebView(url: URL(string: "https://noteflow-silk-kappa.vercel.app/")!)
                .ignoresSafeArea()
                .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                .sheet(isPresented: $ui.settings) { SettingsView() }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Routine.shared.refresh() }
        }
    }
}
