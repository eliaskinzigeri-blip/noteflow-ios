import SwiftUI
import UIKit
import WebKit

/// Le site NoteFlow en plein écran. Il envoie le planning à l'app par `window.webkit.messageHandlers.noteflow`.
struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(home: url) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(context.coordinator, name: "noteflow")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        if #available(iOS 16.4, *) { view.isInspectable = true }
        view.load(URLRequest(url: url))
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
            Routine.shared.receive(data)
        }

        /// Liens vers d'autres sites (Prépa Basket, Pronote, cartes) : dans Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let target = action.request.url, action.navigationType == .linkActivated,
               target.host != nil, target.host != home.host {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
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
