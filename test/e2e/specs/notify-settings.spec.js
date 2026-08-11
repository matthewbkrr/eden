const { test, expect, shot, ready } = require("../helpers/fixtures")

// #214: per-user notification toggles in Settings. Sound flips server-side; the desktop
// toggle requests browser permission inside the click gesture (.NotifyPerm hook) and persists
// the result. Both must survive a reload (stored in FolderPrefs).
test("notification toggles flip, persist, and the desktop one honors permission (#214)", async ({
  alice,
  seed,
}, testInfo) => {
  // Grant Notifications so the desktop toggle's requestPermission() resolves "granted".
  await alice.context().grantPermissions(["notifications"], { origin: seed.base_url })

  // ...and make the STATIC permission agree with it. Measured in this harness: after
  // grantPermissions on the page's own origin, `Notification.requestPermission()` resolves
  // "granted" while `Notification.permission` still reads "denied". The hook takes its
  // turn-OFF branch only on `on && Notification.permission === "granted"` (NotifyPerm.js), so with
  // that mismatch every click re-requests and re-enables, and the switch can never go off —
  // nothing to do with the product, which sees a coherent "granted" in a real browser (#588).
  await alice.addInitScript(() => {
    Object.defineProperty(Notification, "permission", { get: () => "granted", configurable: true })
  })

  await alice.goto("/settings/notifications")
  await ready(alice)

  const sound = alice.locator('button[phx-click="set_notify_sound"]')
  const desktop = alice.locator("#notify-desktop-switch")
  await expect(sound).toBeVisible()
  await shot(alice, testInfo, "notify-settings")

  // Establish the starting point instead of assuming it. These prefs are per-user and persisted,
  // alice is shared across the whole harness, and this test's own restore step at the bottom only
  // runs when everything above it passed — so ONE failure left the desktop toggle on and the
  // "defaults" assertion that used to stand here was red on every run afterwards. A test that
  // poisons the stand and then fails on the poison can never go green again (#588).
  await set(sound, true)
  await set(desktop, false)

  // Flip sound off.
  await sound.click()
  await expect(sound).toHaveAttribute("aria-checked", "false")

  // Desktop: granted permission → turns on.
  await desktop.click()
  await expect(desktop).toHaveAttribute("aria-checked", "true", { timeout: 6000 })

  // Both persist across a reload.
  await alice.reload()
  await ready(alice)
  await expect(alice.locator('button[phx-click="set_notify_sound"]')).toHaveAttribute(
    "aria-checked",
    "false"
  )
  await expect(alice.locator("#notify-desktop-switch")).toHaveAttribute("aria-checked", "true")

  // Restore, and CHECK the restore landed — an unverified cleanup click is how the stand got
  // dirty in the first place.
  await set(alice.locator('button[phx-click="set_notify_sound"]'), true)
  await set(alice.locator("#notify-desktop-switch"), false)
})

// Put a toggle into a known state, whatever it was in. Asserts the result, so a click that never
// registered fails here rather than silently later.
async function set(toggle, on) {
  const want = String(on)
  if ((await toggle.getAttribute("aria-checked")) !== want) await toggle.click()
  await expect(toggle).toHaveAttribute("aria-checked", want, { timeout: 6000 })
}
