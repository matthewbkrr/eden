const { test, expect, send } = require("../helpers/fixtures")

// #206: a chat open in a BACKGROUND tab must not auto-mark incoming messages read (no false
// ✓✓); reading resumes when the tab returns to the foreground. Drives the .IdleTracker hook's
// visibilitychange path, which also flips presence to away (reusing the #102 presence_idle path).
const setHidden = (page, hidden) =>
  page.evaluate((h) => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => h })
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => (h ? "hidden" : "visible"),
    })
    document.dispatchEvent(new Event("visibilitychange"))
  }, hidden)

test("a chat in a background tab doesn't send a false read receipt (#206)", async ({ alice, bob }) => {
  await alice.goto("/app/c/34")
  await bob.goto("/app/c/34")
  await alice.waitForSelector("#composer", { timeout: 15000 })
  await bob.waitForSelector("#composer", { timeout: 15000 })
  await bob.waitForTimeout(600)

  await setHidden(bob, true) // bob backgrounds his tab
  await bob.waitForTimeout(300)

  await send(alice, "hidden-tab msg") // bob (hidden) must NOT auto-read
  await alice.waitForTimeout(1200)
  const checks = () => alice.locator(".ed-msg").last().locator(".hero-check-micro").count()
  expect(await checks()).toBe(1) // ✓ sent, not read

  await setHidden(bob, false) // bob returns → reads
  await expect.poll(() => checks(), { timeout: 6000 }).toBe(2) // ✓✓ read
})
