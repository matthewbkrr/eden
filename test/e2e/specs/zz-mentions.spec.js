// `@`-mentions (#576): the autocomplete, the chip, and what a mention is worth if the handle was
// typed by hand.
const { test, expect, send } = require("../helpers/fixtures")

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

test("the composer offers members after @ and inserts a real handle", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)

  await alice.locator("#composer-body").click()
  await alice.keyboard.type("@")

  const pop = alice.locator("#mention-pop")
  await expect(pop, "no autocomplete appeared").toBeVisible({ timeout: 5000 })
  const first = pop.locator("[data-handle]").first()
  await expect(first).toBeVisible()
  const handle = await first.getAttribute("data-handle")

  await first.click()
  await expect(alice.locator("#composer-body")).toHaveValue(`@${handle} `)
  await expect(pop, "the popover stayed open after picking").toBeHidden()
})

test("a mention renders as a chip and names the person; an unknown handle stays text", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)

  // The peer's handle, taken from the autocomplete so the test cannot drift from the seed.
  await alice.locator("#composer-body").click()
  await alice.keyboard.type("@")
  await expect(alice.locator("#mention-pop")).toBeVisible({ timeout: 5000 })
  const handle = await alice.locator("#mention-pop [data-handle]").first().getAttribute("data-handle")
  await alice.keyboard.press("Escape")
  await alice.locator("#composer-body").fill("")

  const body = `ping @${handle} and @nobody_${Date.now()}`
  await send(alice, body)

  const row = alice.locator("#messages .ed-msg", { hasText: "ping @" }).last()
  await expect(row).toBeVisible({ timeout: 10_000 })
  await expect(row.locator(".ed-mention"), "the known handle did not become a chip").toHaveCount(1)
  await expect(row.locator(".ed-mention")).toHaveText(`@${handle}`)
  await expect(row, "the unknown handle must stay plain text").toContainText("@nobody_")
})
