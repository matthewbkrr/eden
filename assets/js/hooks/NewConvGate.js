// #369/R190: the member checkboxes are native (no server-tracked @selected), so gate
// the Start submit here — disabled until at least one person is checked, matching the
// other modals (room_add / folders). The server still re-validates the empty case.
export default {
  mounted() {
    this.btn = this.el.querySelector('button[type="submit"]')
    this.sync = () => {
      const any = !!this.el.querySelector('input[name="member_ids[]"]:checked')
      if (this.btn) this.btn.disabled = !any
    }
    this.el.addEventListener("change", this.sync)
    this.sync()
  },
  destroyed() {
    this.el.removeEventListener("change", this.sync)
  },
}
