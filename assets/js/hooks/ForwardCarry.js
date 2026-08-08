export default {
  mounted() {
    // Re-hydrate: if messages are being carried, re-arm the server-side plaque with
    // the ids kept across this navigation/remount.
    let ids = []
    try { ids = JSON.parse(sessionStorage.getItem("ed:carry") || "[]") } catch (_e) {}
    // Tolerate a malformed / legacy single-id value (JSON.parse("123") → a number).
    if (!Array.isArray(ids)) ids = ids ? [ids] : []
    if (ids.length) this.pushEvent("forward_rehydrate", { ids })
    this.handleEvent("carry_set", ({ ids }) =>
      sessionStorage.setItem("ed:carry", JSON.stringify(ids)),
    )
    this.handleEvent("carry_clear", () => sessionStorage.removeItem("ed:carry"))
  },
}
