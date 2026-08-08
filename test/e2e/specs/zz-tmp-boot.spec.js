const { test } = require("../helpers/fixtures")
test("boot errors", async ({ alice, seed }) => {
  const errs = []
  alice.on("pageerror", (e) => errs.push("PAGEERROR " + String(e).slice(0, 160)))
  alice.on("console", (m) => { if (m.type() === "error") errs.push("CONSOLE " + m.text().slice(0, 160)) })
  alice.on("response", (r) => { if (r.status() >= 400) errs.push(`HTTP ${r.status()} ${r.url().slice(-60)}`) })
  await alice.goto(`/app/c/${seed.dm_id}`).catch((e) => errs.push("GOTO " + String(e).slice(0, 100)))
  await alice.waitForTimeout(3000)
  console.log("ERRS", JSON.stringify(errs.slice(0, 6), null, 1))
  console.log("STATE", JSON.stringify(await alice.evaluate(() => ({
    ls: !!window.liveSocket, connected: window.liveSocket?.isConnected?.(), root: !!document.querySelector(".ed-root"),
  }))))
})
