// Play a staged clip locally before it uploads (#117). The File is only
// reachable at selection (an upload entry never hands a hook its File), so
// the SendQueue hook stashes URL.createObjectURL(file) on #composer in a
// Map keyed "name:size:lastModified". We look ours up by those data-* attrs,
// point the <video> at it, and revoke on teardown so a clip can't leak.
export default {
  key() {
    return this.el.dataset.name + ":" + this.el.dataset.size + ":" + this.el.dataset.modified
  },
  mounted() {
    // Cache the store now: in destroyed() the node is already detached, so
    // closest("#composer") would return null.
    this.store = this.el.closest("#composer, #reply-composer")?.edenVideoUrls
    const url = this.store && this.store.get(this.key())
    if (url) {
      this.el.src = url
      this.el.load()
      // Reflect the clip's real aspect once known (#117) so a single portrait
      // preview shows full-frame, not a centre-cropped square. No-op in the
      // album grid: there the square tile fixes width+height, which overrides
      // aspect-ratio.
      this.onMeta = () => {
        const w = this.el.videoWidth
        const h = this.el.videoHeight
        if (!w || !h) return
        if (this.el.closest(".ed-compose__grid--single")) {
          // Lone clip: size the box to the decoded dimensions, then grow + fade it in
          // (matches .ImgPreview) so the preview settles instead of snapping open when
          // metadata lands.
          const body = this.el.closest(".ed-compose__body")
          const maxW = (body ? body.clientWidth : 320) - 28 // body padding (0.875rem*2)
          const maxH = Math.round(window.innerHeight * 0.6)
          const s = Math.min(maxW / w, maxH / h, 1)
          this.el.style.width = Math.round(w * s) + "px"
          this.el.style.height = Math.round(h * s) + "px"
          requestAnimationFrame(() => this.el.classList.add("is-ready"))
        } else {
          // Album grid: the square tile fixes width+height, so this is a no-op there.
          this.el.style.aspectRatio = w + " / " + h
        }
      }
      this.el.addEventListener("loadedmetadata", this.onMeta)
    } else {
      // No local frame (rare) — hide the empty player so the film icon shows.
      this.el.style.display = "none"
    }
  },
  destroyed() {
    if (this.onMeta) this.el.removeEventListener("loadedmetadata", this.onMeta)
    const url = this.store && this.store.get(this.key())
    if (url) {
      URL.revokeObjectURL(url)
      this.store.delete(this.key())
    }
  },
}
