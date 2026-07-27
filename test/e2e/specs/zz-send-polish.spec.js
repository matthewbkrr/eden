// Send polish (#439): the optimistic bubble must materialize FLUSH under the last
// message (stretching #messages for the rubber-band shoved it to the scroller bottom,
// then it "jumped up" on ack — user screenshot, desktop), the pending clock's hands
// actually run, and an own send floats up TG-style. Asserted with the transport
// stalled, so nothing here is the server's doing.
const { test, expect } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

test("an optimistic send sits flush under the run, clock ticking, rising in", async ({
  alice,
  seed,
}, testInfo) => {
  const page = alice
  const mobile = testInfo.project.name.startsWith("mobile")
  await page.goto(`/app/c/${seed.dm_id}`)
  await connected(page)

  await page.evaluate(() => {
    window.__edOrigSend = window.liveSocket.socket.conn.send.bind(window.liveSocket.socket.conn)
    window.liveSocket.socket.conn.send = () => {}
  })

  const input = page.locator("#composer-body")
  await input.click()
  await input.fill(`polish-${Date.now()}`)
  const send = page.locator('#composer button[type="submit"]')
  if (mobile) {
    await send.tap()
  } else {
    await send.click()
  }

  const pendingRow = page.locator("#pending-messages .ed-msg")
  await expect(pendingRow).toBeVisible()

  // 1. The row entered with the send float-up (checked FIRST — it's only live for
  //    280ms; the geometry below is measured after it settles, since a mid-flight
  //    translateY(12px) rides into getBoundingClientRect).
  const entry = await pendingRow.evaluate((el) => getComputedStyle(el).animationName)
  expect(entry).toBe("ed-msg-send-in")
  await page.waitForTimeout(400)

  // 2. Flush placement: the optimistic row's gap to the last real row EQUALS the
  //    stream's own row gap — the exact spot the real row will land on ack (#351
  //    invariant; the bug put the whole empty pane in between).
  const gaps = await page.evaluate(() => {
    const rows = document.querySelectorAll("#messages .ed-msg, #messages .ed-flat")
    const prev = rows[rows.length - 2]
    const last = rows[rows.length - 1]
    const pend = document.querySelector("#pending-messages .ed-msg")
    return {
      real: last.getBoundingClientRect().top - prev.getBoundingClientRect().bottom,
      pend: pend.getBoundingClientRect().top - last.getBoundingClientRect().bottom,
    }
  })
  expect(Math.abs(gaps.pend - gaps.real), "optimistic row sits exactly where the real one lands").toBeLessThanOrEqual(1)

  // 3. The clock is the animated SVG with running hands.
  const clock = pendingRow.locator("svg .ed-clock__m")
  await expect(clock).toHaveCount(1)
  const anim = await clock.evaluate((el) => getComputedStyle(el).animationName)
  expect(anim).toBe("ed-clock-spin")

  // 4. The rubber-band tail exists and #messages itself is no longer stretched —
  //    the tail (not the stream) absorbs the leftover height.
  const layout = await page.evaluate(() => {
    const tail = document.querySelector("#message-scroll .ed-msgs-tail")
    const scroll = document.getElementById("message-scroll")
    return {
      tail: !!tail,
      flex: getComputedStyle(scroll).display,
      content: scroll.scrollHeight > scroll.clientHeight,
    }
  })
  expect(layout.tail).toBe(true)
  expect(layout.flex).toBe("flex")
  expect(layout.content, "scroller still overflows for the iOS bounce").toBe(true)

  // Recover the socket for the next test's login state.
  await page.evaluate(() => {
    window.liveSocket.socket.conn.send = window.__edOrigSend
    window.liveSocket.socket.conn.close()
  })
})
