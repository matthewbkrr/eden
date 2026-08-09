// Wave 4 — resilience on a flaky connection (the core PRODUCT.md promise). Playwright's
// setOffline/route don't tear down an already-upgraded Phoenix WebSocket, so we drive the
// real disconnect/reconnect via the LiveSocket API — exactly the path the SendQueue's
// offline-queue + flush-on-reconnect logic (#95/#142) handles.
const { test, expect, shot } = require("../helpers/fixtures")

async function submit(page, msg) {
  await page.fill("#composer-body", msg)
  await page.locator("#composer").evaluate((f) => f.requestSubmit())
}

// Switch conversations via the sidebar patch-link (push_patch — the LiveView stays alive, so
// SendQueue.updated() fires and #pending-messages persists; a goto would remount + clear it).
async function patchTo(page, convId) {
  await page.locator(`#conversations a[href="/app/c/${convId}"]`).first().click()
  await page.waitForFunction(
    (id) => document.querySelector("#composer")?.dataset.conversationId === String(id),
    convId,
  )
}

test.describe("resilience", () => {
  test("a message composed while disconnected is queued and delivers on reconnect", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())

    // Drop alice's socket (a flaky link).
    await alice.evaluate(() => window.liveSocket.disconnect())
    await alice.waitForFunction(() => !window.liveSocket?.isConnected(), null, { timeout: 10_000 })

    const msg = `offline ${testInfo.project.name} ${Date.now()}`
    await submit(alice, msg)
    // The SendQueue keeps it as an optimistic node while disconnected (not lost).
    await expect(alice.locator("#pending-messages").getByText(msg)).toBeVisible({ timeout: 8_000 })
    await shot(alice, testInfo, "offline-queued")

    // Reconnect → the queue flushes → the peer receives it, and alice's optimistic swaps.
    await alice.evaluate(() => window.liveSocket.connect())
    await alice.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 15_000 })
    await shot(alice, testInfo, "offline-delivered")
    expect(bob.__diag.pageErrors).toEqual([])
  })

  test("messages queued during a drop survive and arrive in order", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())

    await alice.evaluate(() => window.liveSocket.disconnect())
    await alice.waitForFunction(() => !window.liveSocket?.isConnected(), null, { timeout: 10_000 })

    const stamp = Date.now()
    const a = `burst-a ${testInfo.project.name} ${stamp}`
    const b = `burst-b ${testInfo.project.name} ${stamp}`
    await submit(alice, a)
    await submit(alice, b)

    await alice.evaluate(() => window.liveSocket.connect())
    await alice.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(a).first()).toBeVisible({ timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(b).first()).toBeVisible({ timeout: 15_000 })
    expect(bob.__diag.pageErrors).toEqual([])
  })

  test("a failed text node survives a chat switch and stays resendable (#380/R064)", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    // The SendQueue hook exposes itself a beat after connect — wait for it before driving markFailed.
    await alice.waitForFunction(() => !!window.__edSendQueue)
    const convA = Number(await alice.locator("#composer").getAttribute("data-conversation-id"))

    // Materialize a failed ●! node through the REAL markFailed path (the nack/timeout outcome),
    // which now tags it with its conversation (#380/R064) so a chat switch HIDES it like a #144
    // media node instead of the blind-remove untagged text nodes used to get. The client_id is
    // unique per run — the Resend below persists a real message under it, so a fixed id would
    // collide with a prior run's row on the next markFailed(findNode).
    const cid = `r064-${Date.now()}`
    const body = `r064 ${testInfo.project.name} ${Date.now()}`
    await alice.evaluate(([id, b]) => window.__edSendQueue.markFailed(id, b), [cid, body])
    const failed = alice.locator(`#pending-messages .ed-msg-failed[data-client-id="${cid}"]`)
    await expect(failed).toBeVisible()
    await expect(failed).toHaveAttribute("data-conv-id", String(convA))

    // Switch to the group and back (push_patch) — the failed node used to vanish here.
    await patchTo(alice, seed.group_id)
    await expect(alice.locator(`#pending-messages [data-client-id="${cid}"]`)).toBeHidden()
    await patchTo(alice, convA)
    await expect(failed).toBeVisible()

    // Resend from the ●! menu → the message actually sends (lands in the stream), node clears.
    await failed.locator(".ed-msg-failed__bang").click()
    await alice.locator(".ed-fail-menu").getByText("Resend", { exact: true }).click()
    await expect(alice.locator("#messages").getByText(body).first()).toBeVisible({ timeout: 15_000 })
    await expect(alice.locator(`#pending-messages .ed-msg-failed[data-client-id="${cid}"]`)).toHaveCount(0)
    expect(alice.__diag.pageErrors).toEqual([])
  })

  // The other two ways out of a failed send (#393/R009). Resend was covered above; these are the
  // ones that decide whether a person can clear the red ●! without reloading — and "Resend N",
  // which only exists once more than one send has failed and is therefore the branch most likely
  // to rot unnoticed.
  test("the fail menu deletes a failed node, and offers Resend N once a second one fails", async ({
    alice,
    seed,
  }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.waitForFunction(() => !!window.__edSendQueue)

    const fail = (id, body) =>
      alice.evaluate(([i, b]) => window.__edSendQueue.markFailed(i, b), [id, body])

    // Slugged: the id goes into a `[data-client-id="…"]` selector, and a project name carrying a
    // quote would break the selector rather than the product (#581 review).
    const tag = testInfo.project.name.replace(/\W/g, "")
    const first = `r009-del-${tag}-${Date.now()}`
    await fail(first, `${first} body`)
    const firstNode = alice.locator(`#pending-messages .ed-msg-failed[data-client-id="${first}"]`)
    await expect(firstNode).toBeVisible()

    // One failed send: the batch item has nothing to batch, so it must not be offered.
    await firstNode.locator(".ed-msg-failed__bang").click()
    const menu = alice.locator(".ed-fail-menu")
    await expect(menu).toBeVisible()
    await expect(menu.locator(".ed-menu__item")).toHaveCount(2)
    await alice.keyboard.press("Escape")
    await expect(menu).toHaveCount(0)

    // A second failure brings it out.
    const second = `r009-del2-${tag}-${Date.now()}`
    await fail(second, `${second} body`)
    await expect(
      alice.locator(`#pending-messages .ed-msg-failed[data-client-id="${second}"]`),
    ).toBeVisible()

    await firstNode.locator(".ed-msg-failed__bang").click()
    await expect(menu).toBeVisible()

    // By CONTENT, not by count: three items would also be satisfied by a duplicated Resend. The
    // batch item is the only one carrying the number of failed sends, and the number is the same
    // in every locale (#581 review).
    await expect(
      menu.locator(".ed-menu__item", { hasText: "2" }),
      "the batch resend never appeared with two failed sends",
    ).toHaveCount(1)

    // Delete removes THIS node and leaves the other one alone — the failed pile is per message,
    // not one lump. Addressed by its danger class rather than by position: the batch item appears
    // and disappears above it, and a test that counts from the end would fire a resend the day the
    // order changes (#581 review).
    await menu.locator(".ed-menu__item--danger").click()
    await expect(firstNode).toHaveCount(0)
    await expect(
      alice.locator(`#pending-messages .ed-msg-failed[data-client-id="${second}"]`),
      "deleting one failed message took the other with it",
    ).toBeVisible()

    // Nothing was sent by any of this: Delete is a discard, not a send.
    await expect(alice.locator("#messages").getByText(`${first} body`)).toHaveCount(0)
    expect(alice.__diag.pageErrors).toEqual([])
  })
})
