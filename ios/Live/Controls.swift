import AppIntents
import SwiftUI
import WidgetKit

// Boutons de NoteFlow pour le Centre de contrôle et l'écran verrouillé (iOS 18) : ils vivent dans l'extension
// existante (aucun identifiant d'app en plus) et ouvrent l'app à la bonne page (OpenPageIntent).
// À ajouter : Centre de contrôle › + › Ajouter une commande › NoteFlow (ou écran verrouillé › Personnaliser).

@available(iOS 18.0, *)
private func open(_ page: String) -> OpenPageIntent {
    OpenPageIntent(page: page)
}

/// Prochain cours (matière, heure, salle) : touche pour ouvrir l'emploi du temps
@available(iOS 18.0, *)
struct NextLessonControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.noteflow.app.control.lesson", provider: LessonProvider()) { lesson in
            ControlWidgetButton(action: open("routine")) {
                Label {
                    Text(lesson.title)
                    Text(lesson.subtitle)
                } icon: {
                    Image(systemName: "book.fill")
                }
            }
        }
        .displayName("Prochain cours")
        .description("Ton prochain cours, son heure et sa salle.")
    }
}

@available(iOS 18.0, *)
struct LessonProvider: ControlValueProvider {
    struct Lesson { let title: String; let subtitle: String }

    var previewValue: Lesson { Lesson(title: "Mathématiques", subtitle: "10h · Salle 12") }

    func currentValue() async throws -> Lesson {
        guard let data = SharedStore.defaults.data(forKey: "plan"),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return Lesson(title: "Prochain cours", subtitle: "Ouvre NoteFlow") }
        let now = Date()
        for day in plan.days {
            guard let midnight = PlanClock.midnight(day.day) else { continue }
            // Cours en cours ou à venir
            if let s = day.steps.filter({ $0.kind == "lesson" }).sorted(by: { $0.start < $1.start })
                .first(where: { midnight.addingTimeInterval($0.end * 60) > now }) {
                let room = s.detail.components(separatedBy: " · ").first ?? ""
                let today = Calendar.current.isDate(midnight, inSameDayAs: now)
                let when = (today ? "" : "Demain ") + PlanClock.clock(s.start)
                return Lesson(title: s.label, subtitle: room.isEmpty ? when : "\(when) · \(room)")
            }
        }
        return Lesson(title: "Prochain cours", subtitle: "Aucun cours prévu")
    }
}

@available(iOS 18.0, *)
struct NotesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.noteflow.app.control.notes") {
            ControlWidgetButton(action: open("notes")) { Label("Mes notes", systemImage: "chart.line.uptrend.xyaxis") }
        }
        .displayName("Mes notes")
        .description("Ouvre tes notes dans NoteFlow.")
    }
}

@available(iOS 18.0, *)
struct TasksControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.noteflow.app.control.tasks") {
            ControlWidgetButton(action: open("tasks")) { Label("Devoirs", systemImage: "checklist") }
        }
        .displayName("Devoirs")
        .description("Ouvre tes devoirs et évaluations dans NoteFlow.")
    }
}

@available(iOS 18.0, *)
struct FocusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.noteflow.app.control.focus") {
            ControlWidgetButton(action: open("focus-add")) { Label("Focus", systemImage: "timer") }
        }
        .displayName("Focus")
        .description("Ajoute des minutes au focus, ou en lance un.")
    }
}
