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
    }

    var body: some Scene {
        WindowGroup {
            WebView(url: URL(string: "https://noteflow-silk-kappa.vercel.app/")!)
                .ignoresSafeArea()
                .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                .sheet(isPresented: $ui.settings) { SettingsView() }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Routine.shared.refresh(); Inbox.shared.poll(force: true) }
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

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Inbox.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
