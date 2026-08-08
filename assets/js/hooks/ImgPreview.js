// Crash-safe staged-photo preview — replaces LiveView's <.live_img_preview>, whose
// mounted() calls URL.createObjectURL(entry.file) and threw "Argument 1 could not be
// converted to Blob" when the entry's File was already gone mid-send (consumed). That
// uncaught throw aborted the DOM patch and left the compose modal blank — the "empty
// lightbox". Same model as .VideoPreview: read the object URL the SendQueue stashed at
// selection (keyed name:size:lastModified); no URL → leave blank, never throw.
export default {
  key() {
    return this.el.dataset.name + ":" + this.el.dataset.size + ":" + this.el.dataset.modified
  },
  mounted() {
    this.store = this.el.closest("#composer, #reply-composer")?.edenVideoUrls
    const url = this.store && this.store.get(this.key())
    if (!url) return
    // A grid tile is an already-reserved square — just show it. A LONE photo's box
    // has no reserved size, so decode the file off-DOM FIRST to learn its dimensions,
    // size the box, then grow + fade it in — the preview settles smoothly instead of
    // snapping the modal open as the blob decodes (anti layout-shift).
    if (!this.el.closest(".ed-compose__grid--single")) {
      this.el.src = url
      return
    }
    const probe = new Image()
    probe.onload = () => {
      const w = probe.naturalWidth
      const h = probe.naturalHeight
      if (w && h) {
        const body = this.el.closest(".ed-compose__body")
        const maxW = (body ? body.clientWidth : 320) - 28 // body padding (0.875rem*2)
        const maxH = Math.round(window.innerHeight * 0.6)
        const s = Math.min(maxW / w, maxH / h, 1)
        this.el.style.width = Math.round(w * s) + "px"
        this.el.style.height = Math.round(h * s) + "px"
      }
      this.el.src = url
      requestAnimationFrame(() => this.el.classList.add("is-ready"))
    }
    probe.onerror = () => {
      this.el.style.width = "auto"
      this.el.style.height = "auto"
      this.el.src = url
      this.el.classList.add("is-ready")
    }
    probe.src = url
  },
  destroyed() {
    const url = this.store && this.store.get(this.key())
    if (url) {
      URL.revokeObjectURL(url)
      this.store.delete(this.key())
    }
  },
}
