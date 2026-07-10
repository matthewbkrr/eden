// Forward matrix (#fwdmatrix): SOURCE × DEST × FORMAT × MODE, on real Firefox.
// A forwarded copy always renders `.ed-forwarded` (attribution "Forwarded from X"), so:
//  - text/caption/quote sources carry a unique needle → assert a forwarded row with that needle;
//  - no-caption media (photo/album/file) → assert the dest `.ed-forwarded` count grew by N.
// Starts as a VALIDATION SLICE (small arrays); widened to the full matrix once the helpers are green.
const { test, expect, openMenu } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

// NOT serial: each cell must be independent (fresh page/context) so one failure never masks the
// rest, and no residual composer/menu state leaks between cells. The config's single worker keeps
// them sequential (shared server sessions), which is what we want.

// A fresh, empty room (FM_CHANNEL/FM_ROOM) keeps media staging off the heavily-loaded general
// room whose huge stream races the upload. Falls back to the seed's general room.
const CH = process.env.FM_CHANNEL
const RM = process.env.FM_ROOM
const url = {
  dm: (s) => `/app/c/${s.dm_id}`,
  group: (s) => `/app/c/${s.group_id}`,
  room: (s) => `/channels/${CH || s.channel_id}/r/${RM || s.general_room_id}`,
}
const streamSel = (surface) => (surface === "thread" ? "#thread-replies" : "#messages")
const rowSel = (surface) => (surface === "dm" || surface === "group" ? ".ed-bubble" : ".ed-flat")
const destStreamSel = (dest) => (dest === "thread" ? "#thread-replies" : "#messages")

let seq = 0
const tok = () => `fm${Date.now()}_${seq++}`
const connect = (page) => page.waitForFunction(() => window.liveSocket?.isConnected())

const comp = (surface) =>
  surface === "thread"
    ? { form: "#reply-composer", body: "#reply-body", file: '#reply-composer input[type="file"]' }
    : { form: "#composer", body: "#composer-body", file: '#composer input[name="attachment"]' }

async function postText(page, form, bodySel, body) {
  await page.locator(bodySel).fill(body)
  await page.locator(form).evaluate((f) => f.requestSubmit())
}

async function openSurface(page, s, surface) {
  await page.goto(surface === "dm" ? url.dm(s) : surface === "group" ? url.group(s) : url.room(s))
  await connect(page)
  if (surface === "thread") {
    const root = `sroot ${tok()}`
    await postText(page, "#composer", "#composer-body", root)
    const rootRow = page.locator(`#messages .ed-flat`, { hasText: root }).first()
    const menu = await openMenu(page, rootRow)
    await menu.getByText("Reply in thread", { exact: true }).click()
    await expect(page.locator("#reply-composer")).toBeVisible()
  }
}

// Create a source message of FORMAT in the open surface; return {needle, media}.
async function makeSource(page, surface, format) {
  const c = comp(surface)
  const stream = streamSel(surface)
  const row = rowSel(surface)
  const t = tok()
  // Wait for the composer to be fully rendered before posting — setInputFiles firing before the
  // LiveView upload hook is wired silently drops the pick (no preview overlay ever appears).
  await expect(page.locator(c.body)).toBeVisible({ timeout: 10000 })
  const seeText = async (needle) =>
    expect(page.locator(`${stream} ${row}`, { hasText: needle }).first()).toBeVisible({ timeout: 12000 })

  if (format === "text") {
    const needle = `text ${t}`
    await postText(page, c.form, c.body, needle)
    await seeText(needle)
    return { needle, media: null }
  }
  if (format === "markdown") {
    const needle = `head ${t}`
    await postText(page, c.form, c.body, `# ${needle}\n**bold** *it* \`code\` http://example.com/${t}`)
    await seeText(needle)
    return { needle, media: null }
  }
  if (format === "quote") {
    const base = `base ${t}`
    await postText(page, c.form, c.body, base)
    await seeText(base)
    const menu = await openMenu(page, page.locator(`${stream} ${row}`, { hasText: base }).first())
    // Exact name — "Reply" must not match "Reply in thread".
    await menu.getByRole("menuitem", { name: "Reply", exact: true }).click()
    await expect(page.locator(`${c.form} .ed-reply-bar`)).toBeVisible()
    const needle = `quote ${t}`
    await postText(page, c.form, c.body, needle)
    await seeText(needle)
    return { needle, media: null }
  }
  // media
  const files =
    format === "album"
      ? [fix("sample1.png"), fix("sample2.png"), fix("sample3.png")]
      : format === "file"
        ? [fix("sample.txt")]
        : [fix("sample1.png")]
  await page.locator(c.file).setInputFiles(files)
  const cap = format === "caption" ? `cap ${t}` : null
  // Both surfaces now open the SAME compose lightbox (#348): only one overlay is open at a time
  // (this surface's), so gate on the global submit button (the container is transiently
  // non-"visible" while it animates in), fill the scoped caption, and submit.
  const submit = page.locator('[data-upload-preview] button[type="submit"]')
  await expect(submit).toBeVisible({ timeout: 15000 })
  if (cap) {
    await page.locator(surface === "thread" ? "#thread-compose-caption" : "#compose-caption").fill(cap)
  }
  await submit.click()
  await expect(page.locator(`${stream} ${row}`).last().locator("img, a[download]").first()).toBeVisible({ timeout: 15000 })
  return { needle: cap, media: format }
}

const sourceRow = (page, surface, made) => {
  const q = `${streamSel(surface)} ${rowSel(surface)}`
  return made.needle ? page.locator(q, { hasText: made.needle }).first() : page.locator(q).last()
}

async function forward(page, surface, made, mode) {
  const menu = await openMenu(page, sourceRow(page, surface, made))
  if (mode === "single") {
    await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
  } else {
    await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
    await expect(page.locator(".ed-selbar")).toBeVisible()
    await page.locator(".ed-selbar button").nth(1).click()
  }
  await expect(page.locator(".ed-reply-bar--forward").first()).toBeVisible({ timeout: 8000 })
}

// Navigate to DEST (carry survives via sessionStorage), snapshot the row ids present before the
// drop, then drop. The forwarded copies are the rows whose ids weren't there before — robust for
// any format (no text needle needed) and immune to forwards accumulated by earlier cells.
async function dropInto(page, s, dest) {
  const stream = destStreamSel(dest)
  if (dest !== "current") {
    await page.goto({ dm: url.dm(s), group: url.group(s), room: url.room(s) }[dest])
    await connect(page)
    await expect(page.locator(".ed-reply-bar--forward").first()).toBeVisible({ timeout: 8000 })
  }
  const rowsSel = `${stream} .ed-flat, ${stream} .ed-msg`
  const beforeIds = await page.locator(rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))
  await page.locator("#composer").evaluate((f) => f.requestSubmit())
  return { stream, rowsSel, beforeIds }
}

async function assertLanded(page, ctx, made, n) {
  const { rowsSel, beforeIds } = ctx
  const before = new Set(beforeIds)
  const newIds = async () =>
    (await page.locator(rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))).filter((id) => !before.has(id))

  // n new rows appear LIVE (no reload).
  await expect.poll(async () => (await newIds()).length, { timeout: 12000 }).toBeGreaterThanOrEqual(n)
  const ids = (await newIds()).slice(-n)
  for (const id of ids) {
    const row = page.locator(`#${id}`)
    await expect(row.locator(".ed-forwarded")).toContainText("Forwarded from", { timeout: 8000 })
  }
  // Single-cell content check on the (one) new copy.
  if (n === 1) {
    const row = page.locator(`#${ids[0]}`)
    if (made.needle) await expect(row).toContainText(made.needle)
    if (made.media === "file") await expect(row.locator("a[download]").first()).toBeVisible({ timeout: 10000 })
    else if (made.media) await expect(row.locator("img").first()).toBeVisible({ timeout: 10000 })
  }
}

// ============ FULL MATRIX ============
const SOURCES = ["dm", "group", "room", "thread"]
const DESTS = ["dm", "group", "room", "current"] // thread-dest + cross-channel are edge cells below
const FORMATS = ["text", "markdown", "quote", "photo", "album", "file", "caption"]

// SINGLE: source × dest × format
for (const src of SOURCES)
  for (const dest of DESTS)
    for (const fmt of FORMATS) {
      test(`fwd single ${fmt}: ${src} -> ${dest} (#fwdmatrix)`, async ({ alice, seed }) => {
        await openSurface(alice, seed, src)
        const made = await makeSource(alice, src, fmt)
        await forward(alice, src, made, "single")
        const ctx = await dropInto(alice, seed, dest)
        await assertLanded(alice, ctx, made, 1)
        expect(alice.__diag?.pageErrors || []).toEqual([])
      })
    }

// MULTI: select 3 (text + photo + file) in the source, forward all, assert 3 forwarded copies.
for (const src of ["dm", "room", "thread"])
  for (const dest of ["room", "dm"]) {
    test(`fwd multi [text,photo,file]: ${src} -> ${dest} (#fwdmatrix)`, async ({ alice, seed }) => {
      await openSurface(alice, seed, src)
      const a = await makeSource(alice, src, "text")
      await makeSource(alice, src, "photo")
      await makeSource(alice, src, "file")
      // Enter select from the text message, then tap the other two rows' overlays.
      const menu = await openMenu(alice, sourceRow(alice, src, a))
      await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
      await expect(alice.locator(".ed-selbar")).toBeVisible()
      const rows = alice.locator(`${streamSel(src)} ${rowSel(src)}`)
      const total = await rows.count()
      for (const i of [total - 2, total - 1]) await rows.nth(i).locator(".ed-select-hit").click()
      await expect(alice.locator(".ed-selbar__count")).toContainText("3")
      await alice.locator(".ed-selbar button").nth(1).click() // Forward
      await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible({ timeout: 8000 })
      const ctx = await dropInto(alice, seed, dest)
      await assertLanded(alice, ctx, { needle: null, media: null }, 3)
      expect(alice.__diag?.pageErrors || []).toEqual([])
    })
  }

// EDGE: cross-channel (source room ch15 → seed general room ch13).
for (const fmt of ["text", "photo"]) {
  test(`fwd single ${fmt}: room -> cross-channel (#fwdmatrix)`, async ({ alice, seed }) => {
    await openSurface(alice, seed, "room")
    const made = await makeSource(alice, "room", fmt)
    await forward(alice, "room", made, "single")
    await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
    await connect(alice)
    await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible({ timeout: 8000 })
    const rowsSel = `#messages .ed-flat, #messages .ed-msg`
    const beforeIds = await alice.locator(rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))
    await alice.locator("#composer").evaluate((f) => f.requestSubmit())
    await assertLanded(alice, { rowsSel, beforeIds }, made, 1)
  })
}

// EDGE: forward INTO a thread (bob posts the root so the carry doesn't hijack the composer).
for (const fmt of ["text", "photo"]) {
  test(`fwd single ${fmt}: room -> into-thread (#fwdmatrix)`, async ({ alice, bob, seed }) => {
    const room = url.room(seed)
    await bob.goto(room)
    await connect(bob)
    const rootText = `troot ${tok()}`
    await bob.locator("#composer-body").fill(rootText)
    await bob.locator("#composer").evaluate((f) => f.requestSubmit())
    await expect(bob.locator("#messages .ed-flat", { hasText: rootText }).first()).toBeVisible({ timeout: 12000 })

    await openSurface(alice, seed, "room")
    const made = await makeSource(alice, "room", fmt)
    await forward(alice, "room", made, "single")
    await alice.goto(room)
    await connect(alice)
    await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible({ timeout: 8000 })
    const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
    const menu = await openMenu(alice, rootRow)
    await menu.getByText("Reply in thread", { exact: true }).click()
    await expect(alice.locator("#reply-composer .ed-reply-bar--forward")).toBeVisible({ timeout: 8000 })
    const rowsSel = `#thread-replies .ed-flat`
    const beforeIds = await alice.locator(rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))
    await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
    await assertLanded(alice, { rowsSel, beforeIds }, made, 1)
  })
}

// EDGE: re-forward — forwarding a forwarded copy keeps the ORIGINAL sender's attribution.
test("re-forward keeps original attribution (#fwdmatrix)", async ({ alice, seed }) => {
  await openSurface(alice, seed, "room")
  const made = await makeSource(alice, "room", "text")
  await forward(alice, "room", made, "single")
  let ctx = await dropInto(alice, seed, "current")
  await assertLanded(alice, ctx, made, 1)
  const copyId = (await alice.locator(ctx.rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))).filter(
    (id) => !new Set(ctx.beforeIds).has(id),
  )[0]
  const attr = (await alice.locator(`#${copyId} .ed-forwarded`).textContent())?.trim()
  // Re-forward the copy; the attribution should still name the ORIGINAL sender, not the re-forwarder.
  const menu = await openMenu(alice, alice.locator(`#${copyId}`))
  await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
  await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible()
  ctx = await dropInto(alice, seed, "current")
  await assertLanded(alice, ctx, made, 1)
  const reId = (await alice.locator(ctx.rowsSel).evaluateAll((els) => els.map((e) => e.id).filter(Boolean))).filter(
    (id) => !new Set(ctx.beforeIds).has(id),
  )[0]
  await expect(alice.locator(`#${reId} .ed-forwarded`)).toHaveText(attr)
})

// NEGATIVE: a tombstone (deleted-for-both) offers no Forward.
test("a deleted (tombstone) message has no Forward (#fwdmatrix)", async ({ alice, seed }) => {
  await openSurface(alice, seed, "room")
  const made = await makeSource(alice, "room", "text")
  const row = sourceRow(alice, "room", made)
  let menu = await openMenu(alice, row)
  await menu.locator(".ed-menu__item", { hasText: "Delete" }).click()
  // confirm sheet or direct — click "Delete for everyone" if present
  const both = alice.locator('#dlg-delete button, [phx-value-scope="both"], .ed-menu__item', {
    hasText: "everyone",
  })
  if (await both.count()) await both.first().click()
  await expect(alice.locator("#messages .ed-flat", { hasText: made.needle })).toHaveCount(0, { timeout: 8000 })
  // The tombstone row (now "Message deleted") — its menu (if any) must not offer Forward.
  const tomb = alice.locator("#messages .ed-flat").filter({ hasText: /deleted/i }).last()
  if (await tomb.count()) {
    menu = await openMenu(alice, tomb).catch(() => null)
    if (menu) await expect(menu.locator(".ed-menu__item", { hasText: "Forward" })).toHaveCount(0)
  }
})
