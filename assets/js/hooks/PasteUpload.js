// Paste files/images from the clipboard straight into the composer's
// upload (#58): screenshots and copied files land in the attachment tray.
export default {
  mounted() {
    this.el.addEventListener("paste", (e) => {
      const files = [...(e.clipboardData?.files || [])]
      if (!files.length) return
      // A paste while a send is uploading is fine now (#119): it sets the input +
      // dispatches `input`, which the SendQueue hook's pick interceptor catches and
      // routes into the upload queue instead of merging into the in-flight config. Exclude
      // the dedicated Resend input (#310 review P0) — it's the first file input in the
      // composer form, and a paste must reach :attachment (or the thread's), not the retry.
      const input = this.el
        .closest("form")
        ?.querySelector('input[type="file"]:not([name="attachment_retry"]):not([name="attachment_seq"])')
      if (!input) return
      e.preventDefault()
      const dt = new DataTransfer()
      files.forEach((f) => dt.items.add(f))
      input.files = dt.files
      input.dispatchEvent(new Event("input", { bubbles: true }))
    })
  },
}
