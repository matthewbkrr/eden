// Telegram-style video: the in-stream clip is a poster + centered play button with
// NO inline controls. Clicking opens the clip full-screen (wide) in a shared overlay
// with real controls, and plays immediately — the click is a user gesture, so
// autoplay with sound is allowed. Cmd/Ctrl/Shift/middle click fall through to the
// <a>'s "open original in a new tab" (the box has no href, so they just no-op there).
// The overlay nav-close guard (#380/R187) is registered once at bundle load from the .Lightbox
// script's module top-level; it closes THIS overlay too (queries #ed-video-modal by id), so
// there's nothing to wire here.
export default {
  mounted() {
    this._open = (e) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
      e.preventDefault()
      this.open()
    }
    this.el.addEventListener("click", this._open)
    this._key = (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault()
        this.open()
      }
    }
    this.el.addEventListener("keydown", this._key)
  },
  open() {
    const src = this.el.dataset.src
    if (!src) return
    const type = this.el.dataset.type || ""
    const box = this.modal()
    const video = box.querySelector(".ed-video-modal__player")
    // Build the <source> programmatically (no innerHTML) — src/type are
    // server-controlled today, but this keeps the markup path injection-proof
    // by construction, like the neighbouring hooks.
    video.replaceChildren()
    const source = document.createElement("source")
    source.src = src
    if (type) source.type = type
    video.appendChild(source)
    video.load()
    box.classList.add("ed-video-modal--open")
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", box.__onKey)
    // The opening tap is a user gesture, so play-with-sound is permitted.
    video.play && video.play().catch(() => {})
  },
  modal() {
    let box = document.getElementById("ed-video-modal")
    if (box) return box

    box = document.createElement("div")
    box.id = "ed-video-modal"
    box.className = "ed-video-modal"
    const lbl = document.getElementById("message-scroll")?.dataset || {}
    const xmark =
      "M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
    box.innerHTML =
      `<button class="ed-video-modal__close" aria-label="${lbl.lbClose || "Close"}"><svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="${xmark}" clip-rule="evenodd"/></svg></button>` +
      '<video class="ed-video-modal__player" controls playsinline></video>'

    const close = () => {
      box.classList.remove("ed-video-modal--open")
      document.body.style.overflow = ""
      document.removeEventListener("keydown", box.__onKey)
      const v = box.querySelector(".ed-video-modal__player")
      // Stop playback + release the source so the clip can't keep playing audio
      // behind the closed overlay.
      v.pause()
      v.innerHTML = ""
      v.removeAttribute("src")
      v.load()
    }
    // Expose close for the global nav guard (#380/R187), like the Lightbox overlay.
    box.__close = close
    box.__onKey = (e) => {
      if (e.key === "Escape") close()
    }
    box.addEventListener("click", (e) => {
      if (e.target.closest(".ed-video-modal__close")) return close()
      // Click on the scrim (anything but the player) closes.
      if (!e.target.closest(".ed-video-modal__player")) close()
    })
    document.body.appendChild(box)
    return box
  },
  destroyed() {
    this.el.removeEventListener("click", this._open)
    this.el.removeEventListener("keydown", this._key)
  },
}
