// Select the whole value on focus, so clicking a folder name makes
// it obvious the entire name is being edited (Finder-style).
export default {
  mounted() { this.el.addEventListener("focus", () => this.el.select()) }
}
