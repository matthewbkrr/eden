// Admin drag-and-drop room ordering in the channel sidebar (the folder
// settings .Sortable pattern). Rows are draggable only for admins
// (draggable attr is server-rendered). The displayed sequence becomes
// the canonical position order on drop.
export default {
  mounted() { this.bind() },
  updated() { this.bind() },
  bind() {
    if (this.el.dataset.admin !== "true") return
    this.el.querySelectorAll(".ed-room-wrap[draggable=true]").forEach((item) => {
      if (item._dnd) return
      item._dnd = true
      item.addEventListener("dragstart", (e) => {
        this.dragging = item
        this.startOrder = this.order().join()
        item.classList.add("ed-dragging")
        e.dataTransfer.effectAllowed = "move"
      })
      item.addEventListener("dragend", () => {
        item.classList.remove("ed-dragging")
        this.commit()
      })
    })
    if (this._listBound) return
    this._listBound = true
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
      if (!this.dragging) return
      const after = this.afterElement(e.clientY)
      if (after == null) {
        // Below the last row: land right after it — never appendChild,
        // which would park the row below "+ New room".
        const rows = this.el.querySelectorAll(".ed-room-wrap[draggable=true]:not(.ed-dragging)")
        const last = rows[rows.length - 1]
        if (last) last.after(this.dragging)
      } else {
        // Rows live inside the .ed-bounce-wrap wrapper now (#443 review, a REAL P0
        // catch): insertBefore on this.el (the scroller) with a wrapper-child
        // reference throws NotFoundError. Insert via the rows' actual parent.
        after.parentElement.insertBefore(this.dragging, after)
      }
    })
  },
  afterElement(y) {
    const items = [...this.el.querySelectorAll(".ed-room-wrap[draggable=true]:not(.ed-dragging)")]
    return items.find((item) => {
      const box = item.getBoundingClientRect()
      return y < box.top + box.height / 2
    }) || null
  },
  commit() {
    this.dragging = null
    const ids = this.order()
    if (ids.join() !== this.startOrder) this.pushEvent("reorder_rooms", { ids })
  },
  order() {
    return [...this.el.querySelectorAll(".ed-room-wrap[draggable=true]")].map((i) => i.dataset.id)
  }
}
