import AppKit
import WebKit

/// Which defences are on. The spike runs the attack file under several
/// combinations to show each layer holds on its own.
struct Defences: CustomStringConvertible {
    var sanitize: Bool       // DOMPurify on Markdown HTML
    var csp: Bool            // CSP header on the preview page
    var contentJS: Bool      // WKWebpagePreferences.allowsContentJavaScript

    var description: String {
        [sanitize ? "DOMPurify" : nil, csp ? "CSP" : nil, contentJS ? nil : "page JS off"]
            .compactMap { $0 }.joined(separator: " + ").ifEmpty("no defences (baseline)")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

let pageHTML = """
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="referrer" content="no-referrer">
<style>body { font: 14px -apple-system, sans-serif; margin: 12px } img { max-width: 64px; max-height: 64px }</style>
</head><body><main id="content"></main></body></html>
"""

/// Marklight's own JS. It runs in an isolated content world, so the page
/// world never sees `DOMPurify`, `marklight`, or the message handler.
let isolatedScriptGlue = """
;(() => {
  const purify = globalThis.DOMPurify;
  const violations = [];
  document.addEventListener('securitypolicyviolation', e => {
    violations.push(e.violatedDirective + ' ' + e.blockedURI);
  });
  const config = {
    FORBID_TAGS: ['style', 'form', 'input', 'button', 'textarea', 'select', 'iframe', 'frame', 'frameset',
                  'object', 'embed', 'base', 'meta', 'link'],
    FORBID_ATTR: ['action', 'formaction'],
  };
  globalThis.marklight = {
    render(html, sanitize) {
      document.getElementById('content').innerHTML = sanitize ? purify.sanitize(html, config) : html;
    },
    rectOf(text) {
      const a = [...document.querySelectorAll('#content a')].find(a => a.textContent === text);
      if (!a) return null;
      a.scrollIntoView({ block: 'center' });
      const r = a.getBoundingClientRect();
      return [r.left + Math.min(r.width / 2, 20), r.top + r.height / 2];
    },
    state() {
      const main = document.getElementById('content');
      const all = [...main.querySelectorAll('*')];
      return JSON.stringify({
        title: document.title,
        images: [...main.querySelectorAll('img')].map(i => [i.getAttribute('src') || '', i.complete && i.naturalWidth > 0]),
        dangerousTags: all.map(e => e.tagName.toLowerCase())
          .filter(t => ['script', 'iframe', 'object', 'embed', 'form', 'meta', 'base', 'link', 'style', 'frame'].includes(t)),
        handlers: all.flatMap(e => [...e.attributes].filter(a => a.name.startsWith('on')).map(a => e.tagName.toLowerCase() + '[' + a.name + ']')),
        scriptLinks: [...main.querySelectorAll('a')].filter(a => /^\\s*(javascript|data):/i.test(a.getAttribute('href') || '')).map(a => a.textContent),
        styledBackground: [...main.querySelectorAll('[style]')].length,
        violations,
      });
    },
  };
  window.webkit.messageHandlers.marklight.postMessage({ type: 'ready' });
})();
"""

/// Navigation, new-window, and bridge policy.
final class PreviewController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let allowedMessages: Set<String> = ["ready"]

    private(set) var navigations: [String] = []
    private(set) var externalOpens: [String] = []
    private(set) var internalOpens: [String] = []
    private(set) var rejectedMessages: [String] = []
    var onReady: (() -> Void)?
    private var pageLoaded = false

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let isMain = action.targetFrame?.isMainFrame ?? false
        var decision = WKNavigationActionPolicy.cancel
        if !pageLoaded, isMain, url == PreviewScheme.pageURL {
            decision = .allow
        } else if isMain, let url, url.fragment != nil,
                  url.absoluteString.hasPrefix(PreviewScheme.pageURL.absoluteString + "#") {
            decision = .allow // same-document anchor
        } else {
            route(url, userClick: action.navigationType == .linkActivated)
        }
        navigations.append("\(decision == .allow ? "allow" : "cancel") type=\(action.navigationType.rawValue) main=\(isMain) \(url?.absoluteString ?? "nil")")
        decisionHandler(decision)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }

    /// target=_blank and window.open land here. Never create a web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        navigations.append("new-window type=\(action.navigationType.rawValue) \(action.request.url?.absoluteString ?? "nil")")
        route(action.request.url, userClick: action.navigationType == .linkActivated)
        return nil
    }

    /// The app would call NSWorkspace.shared.open for external links and open
    /// Markdown files in a new Marklight window. The spike only records it.
    private func route(_ url: URL?, userClick: Bool) {
        guard let url, userClick else { return }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            externalOpens.append(url.absoluteString)
        case PreviewScheme.name where url.host == PreviewScheme.host && ["md", "markdown"].contains(url.pathExtension.lowercased()):
            internalOpens.append(url.path)
        default:
            break
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              PreviewController.allowedMessages.contains(type), body.count == 1 else {
            rejectedMessages.append("\(message.body)")
            return
        }
        if type == "ready" { onReady?() }
    }
}
