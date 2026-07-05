const { test, expect, shot } = require("../helpers/fixtures")

// #214: per-user notification toggles in Settings. Sound flips server-side; the desktop
// toggle requests browser permission inside the click gesture (.NotifyPerm hook) and persists
// the result. Both must survive a reload (stored in FolderPrefs).
test("notification toggles flip, persist, and the desktop one honors permission (#214)", async ({
  alice,
  seed,
}, testInfo) => {
  // Grant Notifications so the desktop toggle's requestPermission() resolves "granted".
  await alice.context().grantPermissions(["notifications"], { origin: seed.base_url })

  await alice.goto("/settings/notifications")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  const sound = alice.locator('button[phx-click="set_notify_sound"]')
  const desktop = alice.locator("#notify-desktop-switch")
  await expect(sound).toBeVisible()
  await shot(alice, testInfo, "notify-settings")

  // Defaults: sound on, desktop off.
  await expect(sound).toHaveAttribute("aria-checked", "true")
  await expect(desktop).toHaveAttribute("aria-checked", "false")

  // Flip sound off.
  await sound.click()
  await expect(sound).toHaveAttribute("aria-checked", "false")

  // Desktop: granted permission → turns on.
  await desktop.click()
  await expect(desktop).toHaveAttribute("aria-checked", "true", { timeout: 6000 })

  // Both persist across a reload.
  await alice.reload()
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await expect(alice.locator('button[phx-click="set_notify_sound"]')).toHaveAttribute(
    "aria-checked",
    "false"
  )
  await expect(alice.locator("#notify-desktop-switch")).toHaveAttribute("aria-checked", "true")

  // Restore defaults so other specs / the user see a clean state.
  await alice.locator('button[phx-click="set_notify_sound"]').click()
  await alice.locator("#notify-desktop-switch").click()
})
