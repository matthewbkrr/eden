// #144 — an in-flight media/file upload's optimistic progress node must survive leaving
// its conversation (the upload keeps running, pinned to its conversation) and reappear on
// return, instead of being wiped. Conversation switches are push_patch (the LiveView stays
// alive → SendQueue.updated() fires); a full goto would remount and clear #pending anyway,
// so we switch via the sidebar patch-links.
const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const sampleTxt = path.join(__dirname, "..", "fixtures", "sample.txt")

async function patchTo(page, convId) {
  await page.locator(`#conversations a[href="/app/c/${convId}"]`).first().click()
  await page.waitForFunction(
    (id) => document.querySelector("#composer")?.dataset.conversationId === String(id),
    convId,
  )
}

test("a real optimistic file node is tagged with its conversation (#144)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const convA = Number(await alice.locator("#composer").getAttribute("data-conversation-id"))

  await alice.locator('#composer input[type="file"]').setInputFiles(sampleTxt)
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator('[data-upload-preview] button[type="submit"]').click()

  // The optimistic card (wrapAndAppendOptimistic) carries data-conv-id — without it a switch
  // would treat it as a text twin and wipe it. The card is built synchronously on submit, so
  // this is asserted before the real row swaps it out.
  await expect(alice.locator("#pending-messages [data-client-id]").first()).toHaveAttribute(
    "data-conv-id",
    String(convA),
  )
})

test("an optimistic media node survives a conversation switch + dedups on return (#144)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const convA = Number(await alice.locator("#composer").getAttribute("data-conversation-id"))
  expect(convA).toBe(seed.dm_id)

  // A still-uploading media node tagged for conv A (as wrapAndAppendOptimistic builds it).
  await alice.evaluate((cid) => {
    const n = document.createElement("div")
    n.className = "ed-msg flex justify-end"
    n.dataset.clientId = "fake-144-uploading"
    n.dataset.convId = String(cid)
    n.textContent = "uploading…"
    document.getElementById("pending-messages").appendChild(n)
  }, convA)
  await expect(alice.locator('[data-client-id="fake-144-uploading"]')).toBeVisible()

  // Switch away (patch) → node HIDDEN, not wiped (the old replaceChildren() removed it).
  await patchTo(alice, seed.group_id)
  const away = alice.locator('[data-client-id="fake-144-uploading"]')
  await expect(away).toHaveCount(1)
  await expect(away).toBeHidden()

  // Return (patch) → node visible again (its real row never arrived).
  await patchTo(alice, convA)
  await expect(alice.locator('[data-client-id="fake-144-uploading"]')).toBeVisible()

  // Dedup-on-return: a twin whose real row arrived while away must drop, not double.
  await alice.locator("#composer-body").fill("dedup-probe-144")
  await alice.locator("#composer-body").press("Enter")
  await expect(alice.locator("#messages [data-client-id]").last()).toBeVisible()
  const clientId = await alice
    .locator("#messages [data-client-id]")
    .last()
    .getAttribute("data-client-id")

  await alice.evaluate(
    (arg) => {
      const n = document.createElement("div")
      n.className = "ed-msg flex justify-end"
      n.dataset.clientId = arg.id
      n.dataset.convId = String(arg.conv)
      n.textContent = "stale twin"
      document.getElementById("pending-messages").appendChild(n)
    },
    { id: clientId, conv: convA },
  )

  await patchTo(alice, seed.group_id)
  await patchTo(alice, convA)

  // The stale twin is gone (deduped against the real row); the real row remains, single.
  await expect(alice.locator(`#pending-messages [data-client-id="${clientId}"]`)).toHaveCount(0)
  await expect(alice.locator(`#messages [data-client-id="${clientId}"]`)).toHaveCount(1)
})
