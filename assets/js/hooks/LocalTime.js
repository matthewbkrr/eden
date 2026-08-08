// A single label outside any feed (sidebar row, search result, thread list). Inside a feed
// the container formats them all instead — see `.LocalTimes` for the shared body.
export default {
  mounted() { this.fmt() },
  updated() { this.fmt() },
  fmt() { window.__edFmtTime(this.el) }
}
