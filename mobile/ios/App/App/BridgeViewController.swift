import Capacitor
import UIKit

// TG-style edge swipe-back (#432) lives in JS (the .InstantNav hook's edge recognizer),
// NOT in WKWebView's native gesture: on a pushState (LiveView) history the native
// same-document traversal proved glitchy — it committed the back, then cancel-reverted
// forward, flashing the just-left chat over the list for a round-trip (user report,
// iPhone). The JS recognizer drives the exact deterministic choreography the header
// back button uses: one history entry, one navigation, finger-followed. Keep the native
// gesture explicitly OFF (when on, it also steals edge touches from the web content).
class BridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        webView?.allowsBackForwardNavigationGestures = false

        // Everything behind the WebView/keyboard defaults to BLACK (UIWindow) — it peeked
        // through the iOS 26 keyboard's rounded top corners as dark triangles, and through
        // every keyboard transition gap (#439, user screenshots). Match the app background
        // in both themes.
        let appBg = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.106, green: 0.106, blue: 0.114, alpha: 1) // ~--ed-bg dark
                : UIColor(red: 0.992, green: 0.992, blue: 0.996, alpha: 1) // #fdfdfe
        }
        view.backgroundColor = appBg
        webView?.superview?.backgroundColor = appBg

        // Capacitor's Keyboard plugin (resize: native) shrinks the WebView only AFTER the
        // keyboard animation finishes (+0.2s grace, see the plugin's
        // `setKeyboardHeight:delay:`) — so the keyboard slid OVER the composer, then the
        // page snapped up (#439, user recording). Resize at WillShow/WillHide instead; the
        // plugin's delayed same-frame set becomes a no-op.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(edKeyboardWillShow(_:)),
                       name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(edKeyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.backgroundColor = view.backgroundColor
    }

    @objc private func edKeyboardWillShow(_ note: Notification) {
        guard let webView = self.webView, let superview = webView.superview,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        // A detached hardware-keyboard bar reports a tiny height — leave those to the
        // plugin's own QuickType handling rather than shrinking for a sliver.
        if end.height < 100 { return }
        // The keyboard frame arrives in SCREEN coordinates; convert into the webView's
        // superview space so an offset container (Split View / safe-area wrapper) can't
        // skew the math (#442 review).
        let kbTop = superview.convert(end, from: nil).origin.y
        var f = webView.frame
        f.size.height = kbTop - f.origin.y
        webView.frame = f
    }

    @objc private func edKeyboardWillHide(_ note: Notification) {
        guard let webView = self.webView, let window = view.window else { return }
        var f = webView.frame
        f.size.height = window.bounds.height - f.origin.y
        webView.frame = f
    }
}
