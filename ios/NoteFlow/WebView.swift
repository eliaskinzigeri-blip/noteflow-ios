import SwiftUI
import UIKit
import WebKit

/// Le site NoteFlow en plein écran. Il envoie le planning à l'app par `window.webkit.messageHandlers.noteflow`.
struct WebView: UIViewRepresentable {
    let url: URL

    /// Lu par l'app dans la page, sans rien changer au site : la clé du mode focus du compte connecté. Elle sert aux
    /// notifications de l'école (Inbox.swift) et à lier les tweaks YouTube et Twitch. Le jeton de session reste dans la page.
    private static let keyScript = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.noteflow;
      if (!bridge) return;
      var sent = '', tries = 0;
      async function run() {
        try {
          var token = null;
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            if (/^sb-.*-auth-token$/.test(k)) {
              var v = JSON.parse(localStorage.getItem(k) || 'null');
              token = (v && (v.access_token || (v.currentSession && v.currentSession.access_token))) || token;
            }
          }
          if (!token) return;
          var res = await fetch('/api/v2/routine/focus', { headers: { Authorization: 'Bearer ' + token } });
          if (!res.ok) return;
          var f = await res.json();
          if (f && f.key && f.key !== sent) {
            sent = f.key;
            bridge.postMessage(JSON.stringify({ type: 'focus', key: f.key }));
          }
        } catch (e) { /* hors ligne ou pas encore connecté : nouvel essai plus tard */ }
      }
      // Session pas encore prête ou jeton en cours de renouvellement : quelques essais, puis à chaque retour dans l'app
      var timer = setInterval(function () { if (sent || ++tries > 20) clearInterval(timer); else run(); }, 5000);
      document.addEventListener('visibilitychange', function () { if (!document.hidden) run(); });
    })();
    """

    private static weak var current: WKWebView?
    private static var pending: String?

    /// Ouvre une page de NoteFlow (« #/notes ») depuis une notification ; un lien complet part dans Safari.
    static func open(_ target: String) {
        if target.hasPrefix("https://") {
            if let link = URL(string: target) { UIApplication.shared.open(link) }
            return
        }
        guard target.hasPrefix("#") else { return }
        guard let view = current, !view.isLoading else { pending = target; return }
        go(view, target)
    }

    private static func go(_ view: WKWebView, _ target: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [target]), let list = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("location.hash = \(list)[0]")
    }

    func makeCoordinator() -> Coordinator { Coordinator(home: url) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        // Domaine lié à l'app (WKAppBoundDomains) : le service worker du site tourne aussi dans l'app,
        // donc les pages et les parcours déjà chargés marchent hors ligne
        config.limitsNavigationsToAppBoundDomains = true
        config.userContentController.add(context.coordinator, name: "noteflow")
        config.userContentController.addUserScript(WKUserScript(source: WebView.keyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        if #available(iOS 16.4, *) { view.isInspectable = true }
        view.load(URLRequest(url: url))
        WebView.current = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let home: URL

        init(home: URL) { self.home = home }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String, let data = text.data(using: .utf8) else { return }
            // {type:'settings'} : bouton « Régler » de Ma routine ; sinon le planning
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["type"] as? String == "settings" {
                NativeUI.shared.settings = true
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["type"] as? String == "focus" {
                if let key = obj["key"] as? String { Inbox.shared.link(key) }
                return
            }
            Routine.shared.receive(data)
        }

        /// Autres sites (Prépa Basket, Pronote, cartes) : dans Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Seul le site est lié à l'app : toute page d'un autre domaine (lien ou redirection) s'ouvre dans Safari
            if let target = action.request.url, action.targetFrame?.isMainFrame ?? true,
               target.host != nil, target.host != home.host {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// Page chargée : la notification touchée pendant le lancement ouvre sa page.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let target = WebView.pending else { return }
            WebView.pending = nil
            // Le site lit sa session avant d'afficher : la page demandée s'ouvre une fois l'app prête
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WebView.go(webView, target) }
        }

        /// `target="_blank"` : même règle, le site dans la vue, le reste dans Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url {
                if target.host == home.host { webView.load(action.request) } else { UIApplication.shared.open(target) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, or: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert) { completionHandler(false) }
        }

        private func present(_ alert: UIAlertController, or fallback: @escaping () -> Void) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { fallback(); return }
            while let shown = top.presentedViewController { top = shown }
            top.present(alert, animated: true)
        }
    }
}
