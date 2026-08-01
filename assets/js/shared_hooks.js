// The only two hooks a SIGNED-OUT page uses (#511).
//
// They used to be colocated `<script>` blocks, which put them inside the generated
// `phoenix-colocated/eden` index — a module that statically imports all 42 hooks and hands them
// back as one object. Importing two of them therefore meant bundling all of them, so login,
// invite, reset and the 2FA challenge each shipped the whole chat client: 79 KB gzip to render a
// form that does not even use the socket.
//
// As plain modules they can be imported by both entry points, and the chat hooks stay out of the
// auth bundle entirely.

// Info flashes self-dismiss after a few seconds; errors stay until dismissed.
export const FlashAutoHide = {
  mounted() { this.arm() },
  // A second info flash reuses this same DOM node (morphdom patches the text in
  // place, so mounted() doesn't re-run) — re-arm on the patch or the first flash's
  // timer would dismiss the new one early.
  updated() { this.arm() },
  destroyed() { clearTimeout(this._t) },
  arm() {
    clearTimeout(this._t)
    if (this.el.dataset.autohide !== "true") return
    this._t = setTimeout(() => {
      const x = this.el.querySelector("[data-flash-close]")
      x && x.click()
    }, 5000)
  }
}

// Toggle a password input between hidden and visible, swapping the eye icon
// and keeping aria-pressed / aria-label in sync for screen readers.
//
// The toggle state is CLIENT-owned: the server always renders the masked
// default, and any LiveView patch (e.g. the form's phx-change validate on
// every keystroke) morphs type/aria/classes back — so the state lives on
// the hook and updated() re-applies it after each patch (#306 review; the
// focused-input carve-out only preserves `value`, not `type`).
export const PasswordReveal = {
  mounted() {
    this.showing = false
    this._onClick = () => {
      this.showing = !this.showing
      this.sync()
    }
    const btn = this.el.querySelector("[data-reveal-toggle]")
    btn && btn.addEventListener("click", this._onClick)
  },
  updated() { this.sync() },
  sync() {
    const input = this.el.querySelector("[data-reveal-input]")
    const btn = this.el.querySelector("[data-reveal-toggle]")
    if (!input || !btn) return
    const show = this.showing
    input.type = show ? "text" : "password"
    btn.setAttribute("aria-pressed", String(show))
    // Labels come from data-* so they honour the server-side gettext locale.
    btn.setAttribute("aria-label", show ? btn.dataset.hideLabel : btn.dataset.showLabel)
    const eye = this.el.querySelector("[data-reveal-eye]")
    const eyeOff = this.el.querySelector("[data-reveal-eye-off]")
    eye && eye.classList.toggle("hidden", show)
    eyeOff && eyeOff.classList.toggle("hidden", !show)
  },
  destroyed() {
    const btn = this.el.querySelector("[data-reveal-toggle]")
    btn && this._onClick && btn.removeEventListener("click", this._onClick)
  }
}
