import BackgroundTasks
import SwiftUI

@main
struct NoteFlowApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var ui = NativeUI.shared

    init() {
        _ = Routine.shared  // localisation et activité en direct prêtes dès le lancement (aussi en arrière-plan)
        if Prefs.school { Reminders.shared.authorize() }
        Inbox.shared.poll(force: true)  // notifications de l'école (notes, informations, devoirs)
        NoteFlowShortcuts.updateAppShortcutParameters()  // questions à Siri (Siri.swift)
    }

    var body: some Scene {
        WindowGroup {
            WebView(url: URL(string: "https://noteflow-silk-kappa.vercel.app/")!)
                .ignoresSafeArea()
                .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                .sheet(isPresented: $ui.settings) { SettingsView() }
                // Panneau « Focus » (bouton du Centre de contrôle) : sur une vue à part, une seule feuille par vue
                .background(Color.clear.sheet(isPresented: $ui.focusAdd) { FocusAddView() })
                .background(Color.clear.sheet(isPresented: $ui.setup) { SetupView() })
                // Boutons du Centre de contrôle : noteflow://open?to=notes ouvre la page #/notes
                .onOpenURL { url in
                    guard url.scheme == "noteflow",
                          let to = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "to" })?.value,
                          to.allSatisfy({ $0.isLetter || $0 == "/" || $0 == "-" }) else { return }
                    WebView.open("#/\(to)")
                }
                // Boutons du Centre de contrôle (OpenPageIntent) : la page demandée s'ouvre
                .onReceive(NotificationCenter.default.publisher(for: OpenPageIntent.notice)) { _ in
                    if let page = OpenPageIntent.take() { NoteFlowApp.show(page) }
                }
        }
        .onChange(of: phase) { _, now in
            if now == .active {
                if let page = OpenPageIntent.take() { NoteFlowApp.show(page) }
                // Une extension manque (position, notifications, Siri…) : on le propose à chaque entrée dans l'app
                Task { @MainActor in
                    await Setup.shared.refresh()
                    let ui = NativeUI.shared
                    if !Setup.shared.missing.isEmpty, !ui.settings, !ui.focusAdd { ui.setup = true }
                }
                Routine.shared.refresh()
                Inbox.shared.poll(force: true)
            }
            if now == .background { NoteFlowApp.scheduleRefresh() }
        }
        // Réveil d'iOS en arrière-plan (app suspendue, sans localisation « Toujours ») : relevé des notifications de l'école
        .backgroundTask(.appRefresh(Inbox.refreshTask)) {
            NoteFlowApp.scheduleRefresh()
            await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { Inbox.shared.poll(force: true) { _ in next.resume() } }
            }
        }
    }

    /// Page demandée par un bouton : « focus-add » ouvre le panneau du focus, le reste une page du site
    @MainActor
    static func show(_ page: String) {
        if page == "focus-add" { NativeUI.shared.focusAdd = true } else { WebView.open("#/\(page)") }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Inbox.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
