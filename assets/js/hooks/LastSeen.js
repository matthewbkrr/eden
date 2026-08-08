// "last seen" timestamp (#102), formatted in the viewer's locale: just the
// time when today, otherwise a short date + time so it's never ambiguous.
export default {
  mounted() { this.fmt() },
  updated() { this.fmt() },
  fmt() {
    const d = new Date(this.el.getAttribute("datetime"))
    if (isNaN(d)) return
    const sameDay = d.toDateString() === new Date().toDateString()
    this.el.textContent = sameDay
      ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      : d.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
  }
}
