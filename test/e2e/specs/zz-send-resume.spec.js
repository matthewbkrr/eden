// The durable send queue (#361/R016): what survives a reload in the middle of an upload.
//
// `SendStore` is IndexedDB, and its rules are the kind that rot silently — a record older than a
// day is garbage, a record already sent is not resumable, and what remains has to come back in the
// order it was queued. Nothing exercised any of it: a regression here is either a message sent
// twice or a card that hangs forever after a reload, and both look like the app losing a send.
const { test, expect } = require("../helpers/fixtures")

const ready = (page) => page.waitForFunction(() => window.liveSocket?.isConnected())

const store = (page, fn, arg) =>
  page.evaluate(
    ([body, a]) => new Function("store", "arg", body)(window.__edenSendStore, a),
    [fn, arg],
  )

test("the store drops what is stale, hides what is sent, and keeps the order (#361/R016)", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForFunction(() => !!window.__edenSendStore)

  const user = await alice.locator("#composer").getAttribute("data-sender-id")

  const rows = await store(
    alice,
    `
    const now = Date.now()
    const DAY = 24 * 60 * 60 * 1000
    const base = { userId: arg.user, convId: 1, queueId: "q", kind: "file", status: "queued" }
    return (async () => {
      // Two live records queued out of order, one long dead, one already delivered.
      await store.put({ ...base, id: "r-second", order: 1, createdAt: now - 1000 })
      await store.put({ ...base, id: "r-first", order: 0, createdAt: now - 2000 })
      await store.put({ ...base, id: "r-stale", order: 0, createdAt: now - DAY - 60_000 })
      await store.put({ ...base, id: "r-sent", order: 9, status: "sent", createdAt: now })
      const live = await store.listUnfinished(arg.user)
      // Read a second time: the answer has to be stable, not a one-off of the first pass.
      const again = await store.listUnfinished(arg.user)
      return { first: live.map((r) => r.id), second: again.map((r) => r.id) }
    })()
  `,
    { user },
  )

  expect(rows.first, "the queue came back wrong").toEqual(["r-first", "r-second"])
  expect(rows.second, "a second read disagreed with the first").toEqual(["r-first", "r-second"])

  // Read the row STRAIGHT out of IndexedDB. Asking `listUnfinished` again would only prove the
  // record stays hidden from that one API — and hidden is not gone: a store that filters instead
  // of deleting grows without bound (#580 review).
  const stale = await store(
    alice,
    `return (async () => {
       const db = await store.db()
       return await new Promise((resolve) => {
         const req = db.transaction("items", "readonly").objectStore("items").get("r-stale")
         req.onsuccess = () => resolve(!!req.result)
         req.onerror = () => resolve(true)
       })
     })()`,
    {},
  )
  expect(stale, "the stale record was filtered out of the answer but never deleted").toBe(false)

  await store(
    alice,
    `return (async () => {
       for (const id of ["r-first", "r-second", "r-sent"]) await store.remove(id)
     })()`,
    {},
  )
})

test("a file left in the store is picked back up after a reload (#361/R016)", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForFunction(() => !!window.__edenSendStore)

  const user = await alice.locator("#composer").getAttribute("data-sender-id")
  const conv = await alice.locator("#composer").getAttribute("data-conversation-id")
  const clientId = `resume-${Date.now()}`
  // Unique per run: this conversation is seeded once and outlives the run, so a fixed name could
  // be satisfied by a file an earlier run had already sent (#580 review).
  const name = `resumed-${clientId}.txt`

  // What a send that was interrupted mid-upload leaves behind: the File itself, keyed to this
  // conversation and this person. Written directly rather than by killing a real upload, because
  // the point under test is the RESUME, and a race for when to pull the plug would only make the
  // test flaky about something else.
  await store(
    alice,
    `return store.put({
       id: arg.clientId + ":0",
       userId: arg.user,
       queueId: arg.clientId,
       order: 0,
       convId: arg.conv,
       caption: "",
       captionId: null,
       asFile: true,
       kind: "file",
       albumCid: null,
       clientId: arg.clientId,
       groupId: null,
       name: arg.name,
       sizeLabel: "12 B",
       type: "text/plain",
       file: new File(["resumed-body"], arg.name, { type: "text/plain" }),
       status: "queued",
       createdAt: Date.now(),
     })`,
    { user, conv, clientId, name },
  )

  await alice.reload()
  await ready(alice)

  // The outcome, not the moment. The optimistic card the resume draws is real, but a twelve-byte
  // file finishes uploading faster than a poll interval on a local server, so asserting on the
  // card is a race with the product rather than a test of it: what has to be true is that the
  // interrupted file ends up sent, and that its optimistic twin does not outlive it.
  await expect(
    alice.locator("#messages").getByText(name).first(),
    "the interrupted file was never resumed after the reload",
  ).toBeVisible({ timeout: 30_000 })

  await expect(alice.locator(`#pending-messages [data-client-id="${clientId}"]`)).toHaveCount(0, {
    timeout: 15_000,
  })

  // Nothing is left to resume a second time — a record that outlives its send is how one file
  // becomes two. Polled, not read once: the record is dropped when the send SETTLES, a beat after
  // the row appears, so a single read here was racing the product rather than testing it.
  await expect
    .poll(
      () =>
        store(
          alice,
          `return (async () => (await store.listUnfinished(arg.user)).filter((r) => r.queueId === arg.q).length)()`,
          { user, q: clientId },
        ),
      { message: "the delivered file is still queued for resume", timeout: 10_000 },
    )
    .toBe(0)
})
