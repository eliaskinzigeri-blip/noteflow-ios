import AppIntents
import Foundation

/// Moyennes et dernières notes de la période, envoyées par le site (routine.js, pushGrades) : pour Siri.
struct Grades: Codable {
    struct Subject: Codable { let name: String; let short: String?; let abbr: String?; let avg: Double; let cls: Double? }
    struct Recent: Codable { let subject: String; let title: String?; let date: String?; let value: Double?; let raw: String?; let out: Double? }
    let general: Double?
    let subjects: [Subject]
    let recent: [Recent]

    static func save(_ data: Data) {
        guard (try? JSONDecoder().decode(Grades.self, from: data)) != nil else { return }
        let changed = UserDefaults.standard.data(forKey: "grades") != data
        UserDefaults.standard.set(data, forKey: "grades")
        // Nouvelles matières : Siri les reconnaît dans « ma moyenne en … »
        if changed { NoteFlowShortcuts.updateAppShortcutParameters() }
    }

    static var saved: Grades? {
        UserDefaults.standard.data(forKey: "grades").flatMap { try? JSONDecoder().decode(Grades.self, from: $0) }
    }
}

/// Une matière (pour « ma moyenne en maths ») : synonymes tirés des noms courts du site
struct SubjectEntity: AppEntity {
    let id: String
    var synonyms: [String] = []

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Matière"
    static let defaultQuery = SubjectQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", synonyms: synonyms.map { "\($0)" })
    }

    init(id: String, synonyms: [String] = []) {
        self.id = id
        self.synonyms = synonyms
    }

    init(_ s: Grades.Subject) {
        var words = [s.short, s.abbr].compactMap { $0 }.filter { !$0.isEmpty && $0 != s.name && !$0.hasSuffix("…") }
        let n = s.name.lowercased()
        let extra: [(String, [String])] = [
            ("math", ["maths", "math"]), ("français", ["français"]), ("anglais", ["anglais"]), ("espagnol", ["espagnol"]),
            ("allemand", ["allemand"]), ("histoire", ["histoire", "histoire-géo", "histoire géo"]), ("physique", ["physique", "physique-chimie"]),
            ("vie et de la terre", ["SVT"]), ("svt", ["SVT"]), ("physique et sportive", ["EPS", "sport"]), ("eps", ["EPS", "sport"]),
            ("musical", ["musique"]), ("plastique", ["arts plastiques", "dessin"]), ("technologie", ["techno", "technologie"]),
            ("latin", ["latin"]), ("morale", ["EMC"]),
        ]
        for (key, more) in extra where n.contains(key) { words += more }
        self.init(id: s.name, synonyms: Array(Set(words)))
    }
}

struct SubjectQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SubjectEntity] {
        let all = Grades.saved?.subjects ?? []
        return identifiers.map { id in all.first { $0.name == id }.map(SubjectEntity.init) ?? SubjectEntity(id: id) }
    }

    func suggestedEntities() async throws -> [SubjectEntity] {
        (Grades.saved?.subjects ?? []).map(SubjectEntity.init)
    }
}
