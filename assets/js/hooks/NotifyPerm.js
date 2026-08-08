// Desktop-notifications toggle (#214). Notification.requestPermission() must be
// called INSIDE the user gesture (Safari is strict; a server round-trip wouldn't
// count), so the click is handled here — not via phx-click — and only the RESULT
// is pushed. data-on reflects the current pref so we know which way we're toggling.
export default {
  mounted() {
    this.el.addEventListener("click", async () => {
      const on = this.el.dataset.on === "true"
      if (!("Notification" in window)) {
        this.pushEvent("set_notify_desktop", { on: false, perm: "unsupported" })
        return
      }
      // Only an ON pref that's ALSO granted on THIS origin toggles off. A pref that's
      // "on" but ungranted here — e.g. the same account on a new domain (prod vs the
      // dev origin), where browser permission is per-origin — (re)requests instead,
      // so re-enabling is one click, not off-then-on.
      if (on && Notification.permission === "granted") {
        this.pushEvent("set_notify_desktop", { on: false })
        return
      }
      // Safari ≤15 has only the callback form of requestPermission(); the
      // promise resolves to undefined there, so `perm === "granted"` fails and
      // the toggle flips on with a SECOND click after the grant (the catch
      // fallback reads Notification.permission). Negligible audience in 2026 —
      // recorded, not worked around (#273).
      let perm
      try { perm = await Notification.requestPermission() }
      catch (_e) { perm = Notification.permission }
      this.pushEvent("set_notify_desktop", { on: perm === "granted", perm })
    })
  }
}
