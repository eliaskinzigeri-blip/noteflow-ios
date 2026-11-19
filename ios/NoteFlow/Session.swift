import Foundation
import Security

/// Copie de secours de la session du site (jeton Supabase « sb-…-auth-token » du localStorage), gardée dans le
/// trousseau de l'iPhone. Si la page démarre sans sa session (stockage web illisible ou effacé, par exemple
/// après un redémarrage), elle est remise dans le localStorage avant que le site ne la lise : plus besoin de
/// se reconnecter. Se déconnecter sur le site efface aussi la copie.
enum Session {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.noteflow.app.session",
        kSecAttrAccount as String: "web",
    ]

    static var saved: [String: String] {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let items = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return items
    }

    static func save(_ items: [String: String]) {
        let keep = items.filter { $0.key.hasPrefix("sb-") && $0.key.hasSuffix("-auth-token") }
        guard keep != saved else { return }
        SecItemDelete(base as CFDictionary)
        guard !keep.isEmpty, let data = try? JSONEncoder().encode(keep) else { return }
        var q = base
        q[kSecValueData as String] = data
        // Lisible dès le premier déverrouillage après le démarrage, y compris en arrière-plan
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Script injecté au tout début de la page : remet la session si le localStorage ne l'a plus.
    static func restoreScript() -> String? {
        let items = saved
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function () {
          try {
            var saved = \(json);
            Object.keys(saved).forEach(function (k) {
              if (/^sb-.*-auth-token$/.test(k) && !localStorage.getItem(k)) localStorage.setItem(k, saved[k]);
            });
          } catch (e) { /* stockage indisponible */ }
        })();
        """
    }

    /// Script de la page : envoie à l'app la session à chaque changement (connexion, jeton renouvelé, déconnexion).
    static let watchScript = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.noteflow;
      if (!bridge) return;
      var last = null;
      function snap() {
        try {
          var items = {};
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            if (/^sb-.*-auth-token$/.test(k)) items[k] = localStorage.getItem(k);
          }
          var s = JSON.stringify(items);
          if (last === null && s === '{}') { last = s; return; }  // pas connecté au chargement : rien à effacer
          if (s !== last) { last = s; bridge.postMessage(JSON.stringify({ type: 'auth', items: items })); }
        } catch (e) { /* stockage indisponible */ }
      }
      snap();
      setInterval(snap, 10000);
      document.addEventListener('visibilitychange', snap);
      window.addEventListener('pagehide', snap);
    })();
    """
}
