import Capacitor
import UIKit

// TG-style edge swipe-back (#432) lives in JS (the .InstantNav hook's edge recognizer),
// NOT in WKWebView's native gesture: on a pushState (LiveView) history the native
// same-document traversal proved glitchy — it committed the back, then cancel-reverted
// forward, flashing the just-left chat over the list for a round-trip (user report,
// iPhone). The JS recognizer drives the exact deterministic choreography the header
// back button uses: one history entry, one navigation, finger-followed. Keep the native
// gesture explicitly OFF (when on, it also steals edge touches from the web content).
//
// Keyboard architecture v2 (#439 wave 4): the WebView frame NEVER changes for the
// keyboard (Keyboard resize: 'none' in capacitor.config). The v1 frame resize — ours at
// WillShow or the plugin's delayed one — always produced one visible artifact or
// another: the instant shrink read as a harsh jump, and WebKit's own focused-input
// reveal panned the native scrollView down/up around it (the header dip; the Keyboard
// plugin fights the same pan with its resetScrollView calls at every keyboard event and
// a contentOffset-zeroing scroll delegate behind its disableScroll option). Instead the
// PAGE lifts its own composer with a CSS transition driven by the keyboardWillShow/Hide
// events (native.js), gliding alongside the keyboard. Here we only pin the scrollView
// so WebKit's native pan can never move the page: config scrollEnabled=false stops user
// scrolling of the outer scrollView, and the KVO below reverts programmatic offsets
// (setContentOffset works even with isScrollEnabled=false, so the config alone is not
// enough).
class BridgeViewController: CAPBridgeViewController {
    private var edOffsetPin: NSKeyValueObservation?

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

        // The h-screen layout never overflows the outer scrollView, so any non-zero
        // offset is WebKit's focused-input reveal shoving the page around (#439: the
        // header dipped down and snapped back on keyboard focus). Revert it in place.
        if let sv = webView?.scrollView {
            edOffsetPin = sv.observe(\.contentOffset, options: [.new]) { scrollView, _ in
                if scrollView.contentOffset != .zero {
                    scrollView.setContentOffset(.zero, animated: false)
                }
            }
        }
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.backgroundColor = view.backgroundColor
    }
}
