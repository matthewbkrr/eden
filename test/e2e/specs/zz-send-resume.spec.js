// The durable send queue (#361/R016): what survives a reload in the middle of an upload.
//
// `SendStore` is IndexedDB, and its rules are the kind that rot silently — a record older than a
// day is garbage, a record already sent is not resumable, and what remains has to come back in the
// order it was queued. Nothing exercised any of it: a regression here is either a message sent
// twice or a card that hangs forever after a reload, and both look like the app losing a send.
//
// The store is driven through `page.evaluate` with real functions, never a code string. A string is
// invisible to the parser, to prettier and to review — and it proved it: a backtick inside a
// comment inside one silently truncated this file (#580 review).
const { test, expect } = require("../helpers/fixtures")

const ready = (page) => page.waitForFunction(() => window.liveSocket?.isConnected())

test("the store drops what is stale, hides what is sent, and keeps the order (#361/R016)", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForFunction(() => !!window.__edenSendStore)

  const user = await alice.locator("#composer").getAttribute("data-sender-id")
  // Unique per run and swept in a `finally`: these rows live in a real IndexedDB that outlives the
  // test, so a failed assertion used to leave them behind for the next run to trip over.
  const tag = `t${Date.now()}`

  try {
    const rows = await alice.evaluate(
      async ({ user, tag }) => {
        const store = window.__edenSendStore
        const now = Date.now()
        const DAY = 24 * 60 * 60 * 1000
        const base = { userId: user, convId: 1, queueId: tag, kind: "file", status: "queued" }

        // Two live records queued out of order, one long dead, one already delivered.
        await store.put({ ...base, id: `${tag}-second`, order: 1, createdAt: now - 1000 })
        await store.put({ ...base, id: `${tag}-first`, order: 0, createdAt: now - 2000 })
        await store.put({ ...base, id: `${tag}-stale`, order: 0, createdAt: now - DAY - 60_000 })
        await store.put({ ...base, id: `${tag}-sent`, order: 9, status: "sent", createdAt: now })

        // Only OUR rows: listUnfinished answers for the whole user, and this database outlives both
        // the test and the run, so another test's in-flight send — or one stranded by an earlier
        // failure — would otherwise be read as this test's business.
        const ours = (list) => list.filter((r) => r.id.startsWith(tag)).map((r) => r.id)
        const live = await store.listUnfinished(user)
        // Read a second time: the answer has to be stable, not a one-off of the first pass.
        const again = await store.listUnfinished(user)
        return { first: ours(live), second: ours(again) }
      },
      { user, tag },
    )

    expect(rows.first, "the queue came back wrong").toEqual([`${tag}-first`, `${tag}-second`])
    expect(rows.second, "a second read disagreed with the first").toEqual([
      `${tag}-first`,
      `${tag}-second`,
    ])

    // Read the row STRAIGHT out of IndexedDB. Asking listUnfinished again would only prove the
    // record stays hidden from that one API — and hidden is not gone: a store that filters instead
    // of deleting grows without bound.
    const stale = await alice.evaluate(async (tag) => {
      const db = await window.__edenSendStore.db()
      return await new Promise((resolve) => {
        const req = db.transaction("items", "readonly").objectStore("items").get(`${tag}-stale`)
        req.onsuccess = () => resolve(!!req.result)
        req.onerror = () => resolve(true)
      })
    }, tag)

    expect(stale, "the stale record was filtered out of the answer but never deleted").toBe(false)
  } finally {
    await alice.evaluate(async (tag) => {
      for (const suffix of ["-first", "-second", "-stale", "-sent"]) {
        await window.__edenSendStore.remove(`${tag}${suffix}`)
      }
    }, tag)
  }
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
  // Unique per run: this conversation is seeded once and outlives the run, so a fixed name could be
  // satisfied by a file an earlier run had already sent.
  const name = `resumed-${clientId}.txt`

  // What a send interrupted mid-upload leaves behind: the File itself, keyed to this conversation
  // and this person. Written directly rather than by killing a real upload, because the point under
  // test is the RESUME, and a race for when to pull the plug would only make the test flaky about
  // something else.
  //
  // Swept in a `finally` like the first test's rows: on the happy path the product deletes this
  // record itself, but a failed reload or assertion would otherwise leave a File in a database that
  // outlives the run — and the next run would resume it.
  try {
    await alice.evaluate(
      ({ user, conv, clientId, name }) =>
        window.__edenSendStore.put({
          id: `${clientId}:0`,
          userId: user,
          queueId: clientId,
          order: 0,
          convId: conv,
          caption: "",
          captionId: null,
          asFile: true,
          kind: "file",
          albumCid: null,
          clientId,
          groupId: null,
          name,
          sizeLabel: "12 B",
          type: "text/plain",
          file: new File(["resumed-body"], name, { type: "text/plain" }),
          status: "queued",
          createdAt: Date.now(),
        }),
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
          alice.evaluate(
            async ({ user, queueId }) =>
              (await window.__edenSendStore.listUnfinished(user)).filter(
                (r) => r.queueId === queueId,
              ).length,
            { user, queueId: clientId },
          ),
        { message: "the delivered file is still queued for resume", timeout: 10_000 },
      )
      .toBe(0)
  } finally {
    await alice.evaluate((clientId) => window.__edenSendStore.remove(`${clientId}:0`), clientId)
  }
})
