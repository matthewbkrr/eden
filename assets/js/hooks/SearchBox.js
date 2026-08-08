// Keeps the search input in sync with server-side clears: morphdom won't
// patch a focused input's value, so the server pushes "clear-search" and
// we empty it here. Also forwards the native type=search Escape-clear
// (which fires "search", not "input") to the server.
export default {
  mounted() {
    this.input = this.el.querySelector("input[type=search]")
    this.handleEvent("clear-search", () => { this.input.value = "" })
    this.input.addEventListener("search", () => {
      if (this.input.value === "") this.pushEvent("clear_search", {})
    })
  }
}
