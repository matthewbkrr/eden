// Preview a chime preset (#289) client-side. The click is a user
// gesture, so it can create / resume the shared AudioContext; the
// synth + preset table live on window.edSound (shared with Notifier).
export default {
  mounted() {
    this.el.addEventListener("click", () => {
      const AC = window.AudioContext || window.webkitAudioContext
      if (!AC) return
      if (!window.__edAudio) window.__edAudio = new AC()
      const ctx = window.__edAudio
      const go = () => window.edSound && window.edSound.play(ctx, this.el.dataset.soundKey)
      if (ctx.state === "suspended") ctx.resume().then(go).catch(() => {})
      else go()
    })
  }
}
