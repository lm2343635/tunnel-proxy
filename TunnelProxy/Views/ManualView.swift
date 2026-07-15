import SwiftUI
import WebKit

/// The user guide, shown in a dedicated in-app window rather than the default
/// browser. Wraps a `WKWebView` that loads the bundled HTML manual straight from
/// the app's Resources, so the guide works offline and stays inside the app.
struct ManualView: View {
    var body: some View {
        Group {
            if let guide = AppPaths.userGuide {
                ManualWebView(url: guide)
            } else {
                // Should never happen (the guide is bundled), but degrade
                // gracefully instead of showing a blank window.
                ContentUnavailableView(
                    "User guide unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The bundled guide is missing — reinstall the app."))
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Bridges a `WKWebView` into SwiftUI. Loads a local file URL and grants read
/// access to the whole `manual` directory so the in-page language-switch links
/// (User-Guide.html ⇄ 使用手册.html) resolve as file:// navigations.
private struct ManualWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        // Bounce back so the elastic scroll edge shows the page background,
        // matching a native document window.
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The window loads one fixed guide; nothing to reload on state change.
    }

    /// Keeps navigation inside the guide: local pages open in place, external
    /// http(s) links go to the default browser instead of hijacking the window.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if target.isFileURL {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
            }
        }
    }
}
