// Zero-flash stream video (#130). A just-sent clip's FIRST load can transiently
// error (the blob was only just stored; the metadata/Range fetch right after the
// optimistic→real swap races) and then play fine — Firefox would paint its
// "unsupported format" icon for a beat before recovering. We mask the player
// with a poster COVER (its own frame, mirrored from the <video>'s poster — the
// client snapshot via the riser, or the server thumbnail) and reveal the real
// player only once it can actually show a frame (loadeddata/canplay). So no
// load/error state is ever visible. A transient error also retries load() once,
// which then reaches canplay and fades the cover.
export default {
  mounted() {
    // The cover lives in the HEEx (phx-update="ignore" so morphdom leaves it
    // alone); we just fill its src + fade it out.
    this.cover = this.el.closest(".ed-video-box")?.querySelector(".ed-video-cover")
    if (!this.cover) return
    // Mirror the <video>'s poster (the riser's client snapshot, or the server
    // thumbnail) — it can arrive after mount, so observe it.
    this.syncCover = () => {
      const p = this.el.getAttribute("poster")
      if (p && this.cover.getAttribute("src") !== p) this.cover.setAttribute("src", p)
    }
    this.syncCover()
    this.posterObs = new MutationObserver(this.syncCover)
    this.posterObs.observe(this.el, { attributes: true, attributeFilter: ["poster"] })

    this.reveal = () => this.cover.classList.add("ed-video-cover--gone")
    this.el.addEventListener("loadeddata", this.reveal)
    this.el.addEventListener("canplay", this.reveal)
    // Already decodable (e.g. cached) — reveal immediately.
    if (this.el.readyState >= 2) this.reveal()

    this.onError = () => {
      if (this._retried) return
      this._retried = true
      this.el.load()
    }
    this.el.addEventListener("error", this.onError)
  },
  destroyed() {
    this.posterObs && this.posterObs.disconnect()
    if (this.reveal) {
      this.el.removeEventListener("loadeddata", this.reveal)
      this.el.removeEventListener("canplay", this.reveal)
    }
    this.onError && this.el.removeEventListener("error", this.onError)
  },
}
