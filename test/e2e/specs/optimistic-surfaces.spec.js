// Every surface draws an optimistic text node on send (#351): rooms (flat) + groups get a FADED
// node with NO clock (the fade is the "sending" indicator), DMs keep the clock. All appear
// instantly (ed-msg--sent, no rise-in) and swap to the real row.
const { test, expect } = require("../helpers/fixtures")

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

// Record the first optimistic node added to #pending-messages before it swaps out.
async function watch(alice) {
  await alice.evaluate(() => {
    window.__opt = null
    const pend = document.getElementById("pending-messages")
    new MutationObserver((muts) => {
      for (const m of muts)
        for (const n of m.addedNodes) {
          if (n.nodeType !== 1 || !n.dataset || !n.dataset.clientId || window.__opt) continue
          window.__opt = {
            cls: n.className,
            hasClock: !!n.querySelector(".hero-clock-micro"),
            hasSent: n.classList.contains("ed-msg--sent"),
            hasEnter: n.classList.contains("ed-msg--enter"),
            isFlat: n.classList.contains("ed-flat"),
            bubbleOpacity: (() => {
              const b = n.querySelector(".ed-bubble")
              const body = n.querySelector(".ed-flat__body")
              const el = b || body
              return el ? getComputedStyle(el).opacity : (n.style.opacity || null)
            })(),
          }
        }
    }).observe(pend, { childList: true })
  })
}
const read = (alice) => alice.evaluate(() => window.__opt)

async function sendText(alice, url, bodySel = "#composer-body", formSel = "#composer") {
  await alice.goto(url)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await watch(alice)
  await alice.locator(bodySel).fill(`opt-probe ${Date.now()}`)
  await alice.locator(formSel).evaluate((f) => f.requestSubmit())
  await alice.waitForFunction(() => window.__opt, { timeout: 6000 })
  return read(alice)
}

test("room text send shows a faded optimistic node with NO clock (#351)", async ({ alice, seed }) => {
  const opt = await sendText(alice, room(seed))
  expect(opt, `optimistic node seen (got ${JSON.stringify(opt)})`).toBeTruthy()
  expect(opt.isFlat, "room optimistic is a flat row").toBeTruthy()
  expect(opt.hasClock, "room optimistic has NO clock").toBeFalsy()
  expect(opt.hasSent, "uses ed-msg--sent (instant fade, no rise)").toBeTruthy()
  expect(opt.hasEnter, "does NOT use ed-msg--enter (rise-in)").toBeFalsy()
  // The real row swaps in.
  await expect(alice.locator("#messages .ed-flat").last()).toBeVisible()
  expect(alice.__diag.pageErrors).toEqual([])
})

test("group text send shows a faded optimistic bubble with NO clock (#351)", async ({ alice, seed }) => {
  const opt = await sendText(alice, `/app/c/${seed.group_id}`)
  expect(opt, `optimistic node seen (got ${JSON.stringify(opt)})`).toBeTruthy()
  expect(opt.hasClock, "group optimistic has NO clock (no receipt)").toBeFalsy()
  expect(opt.hasSent, "uses ed-msg--sent").toBeTruthy()
  expect(alice.__diag.pageErrors).toEqual([])
})

test("DM text send still shows the sending clock (#351)", async ({ alice, seed }) => {
  const opt = await sendText(alice, `/app/c/${seed.dm_id}`)
  expect(opt, `optimistic node seen (got ${JSON.stringify(opt)})`).toBeTruthy()
  expect(opt.hasClock, "DM optimistic keeps the sending clock").toBeTruthy()
  expect(opt.hasSent, "uses ed-msg--sent (instant, no rise → no swap jump)").toBeTruthy()
  expect(alice.__diag.pageErrors).toEqual([])
})
