// HTML5 drag-and-drop reorder. Items rearrange live as you drag; on
// drop we push the new id order to the server. Handlers bind once per
// node (guarded), so they survive LiveView re-renders.
export default {
  mounted() { this.bind() },
  updated() { this.bind() },
  bind() {
    this.el.querySelectorAll("li[draggable=true]").forEach((item) => {
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
      if (after == null) this.el.appendChild(this.dragging)
      else this.el.insertBefore(this.dragging, after)
    })
  },
  afterElement(y) {
    const items = [...this.el.querySelectorAll("li[draggable=true]:not(.ed-dragging)")]
    return items.find((item) => {
      const box = item.getBoundingClientRect()
      return y < box.top + box.height / 2
    }) || null
  },
  commit() {
    this.dragging = null
    const ids = this.order()
    // A click on the handle or a cancelled drag isn't a reorder.
    if (ids.join() !== this.startOrder) this.pushEvent("reorder_folders", { ids })
  },
  order() {
    return [...this.el.querySelectorAll("li[draggable=true]")].map((i) => i.dataset.id)
  }
}
