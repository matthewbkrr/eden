import Capacitor

// TG-style edge swipe-back (#432): WKWebView's native interactive gesture — the page
// snapshot follows the finger from the left edge, release commits — drives
// history.back(), which LiveView receives as a popstate patch (chat → list, room →
// room list). The exact iOS push-navigation feel with zero JS; wired here because the
// stock CAPBridgeViewController ships with the gesture disabled.
class BridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        webView?.allowsBackForwardNavigationGestures = true
    }
}
