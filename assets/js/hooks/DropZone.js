// Drag-and-drop file upload (#207): drop files from Finder/Explorer anywhere in the
// chat (or thread) pane → staged into the composer. Mirrors .PasteUpload — it sets the
// pane's own file input + dispatches `input`, which the SendQueue pick-interceptor
// catches (queue #119 / cap / preview reused, no new server path). ONLY reacts to OS
// FILE drags (dataTransfer has "Files"), so message swipe-reply and the room-list
// sortable (element drags) are untouched. stopPropagation makes the innermost zone win,
// so the thread pane and the main pane never both fire.
export default {
  input() {
    // The pane's own file input (main → :attachment, thread → :thread_attachment); the
    // dedicated Resend input is excluded (#310 review P0) so a drop never lands in the
    // auto-upload retry config. Absent only during the brief inert window mid-send (#207
    // P3) → the drop no-ops then. Drag-drop is a mouse-only enhancement; picker + paste
    // stay the accessible paths.
    return this.el.querySelector('input[type="file"]:not([name="attachment_retry"]):not([name="attachment_seq"])')
  },
  hasFiles(e) {
    return e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")
  },
  show(on) {
    this.el.classList.toggle("ed-dropzone--over", on)
  },
  mounted() {
    // The overlay is SERVER-rendered in the template (#207 P1): appending it from JS got
    // wiped by morphdom on the next re-render, so the hook only toggles --over.
    this.depth = 0
    this.reset = () => {
      this.depth = 0
      this.show(false)
    }
    this.onEnter = (e) => {
      if (!this.hasFiles(e) || !this.input()) return
      e.preventDefault()
      e.stopPropagation()
      this.depth++
      this.show(true)
    }
    this.onOver = (e) => {
      if (!this.hasFiles(e) || !this.input()) return
      e.preventDefault() // required to allow the drop
      e.stopPropagation()
      e.dataTransfer.dropEffect = "copy"
    }
    this.onLeave = (e) => {
      if (!this.hasFiles(e)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) this.show(false)
    }
    this.onDrop = (e) => {
      if (!this.hasFiles(e) || !this.input()) return
      e.preventDefault()
      e.stopPropagation()
      this.reset()
      const files = Array.from(e.dataTransfer.files)
      if (!files.length) return
      const input = this.input()
      const dt = new DataTransfer()
      files.forEach((f) => dt.items.add(f))
      input.files = dt.files
      input.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.el.addEventListener("dragenter", this.onEnter)
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("dragleave", this.onLeave)
    this.el.addEventListener("drop", this.onDrop)
    // P2: a drag that ends ANYWHERE (dropped outside a zone, or cancelled) must clear a
    // stuck overlay — those don't always fire dragleave on us.
    window.addEventListener("drop", this.reset)
    window.addEventListener("dragend", this.reset)
  },
  destroyed() {
    this.el.removeEventListener("dragenter", this.onEnter)
    this.el.removeEventListener("dragover", this.onOver)
    this.el.removeEventListener("dragleave", this.onLeave)
    this.el.removeEventListener("drop", this.onDrop)
    window.removeEventListener("drop", this.reset)
    window.removeEventListener("dragend", this.reset)
  },
}
