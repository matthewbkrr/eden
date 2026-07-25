import Capacitor

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
    }
}
