// Wave 6b — settings: per-user quick-react set + theme switch.
const { test, expect, shot } = require("../helpers/fixtures")

test.describe("settings-ext", () => {
  test("toggling a quick-react updates the set", async ({ alice }, testInfo) => {
    await alice.goto("/settings")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const grid = alice.locator(".ed-qr-grid")
    await expect(grid).toBeVisible()

    // Pick an emoji currently OFF; target it by its emoji value so the locator stays stable
    // after the toggle (a positional .first() would re-resolve to a different button).
    const emoji = await grid
      .locator('button[aria-pressed="false"]:not([disabled])')
      .first()
      .getAttribute("phx-value-emoji")
    const btn = grid.locator(`button[phx-value-emoji="${emoji}"]`)
    await btn.click()
    await expect(btn).toHaveAttribute("aria-pressed", "true", { timeout: 6_000 })
    await shot(alice, testInfo, "quick-react")

    // Toggle it back off (cleanup).
    await btn.click()
    await expect(btn).toHaveAttribute("aria-pressed", "false", { timeout: 6_000 })
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("theme switch applies", async ({ alice }, testInfo) => {
    await alice.goto("/settings")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator(".ed-seg__btn", { hasText: "Dark" }).click()
    await expect(alice.locator("html")).toHaveAttribute("data-theme", /dark/i, { timeout: 6_000 })
    await shot(alice, testInfo, "theme-dark")
    await alice.locator(".ed-seg__btn", { hasText: "System" }).click()
    expect(alice.__diag.pageErrors).toEqual([])
  })
})
