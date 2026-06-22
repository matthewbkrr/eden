// Playwright config for the eden multi-user / multi-device audit.
// Run from the repo root, e.g.:  npx playwright test --config test/e2e/playwright.config.js
// Browsers + the @playwright/test runner resolve from ~/node_modules.
const { defineConfig, devices } = require("@playwright/test")
const fs = require("fs")
const path = require("path")

const seedPath = path.join(__dirname, ".seed.json")
const seed = fs.existsSync(seedPath)
  ? JSON.parse(fs.readFileSync(seedPath, "utf8"))
  : { base_url: "http://localhost:4001" }

module.exports = defineConfig({
  testDir: "./specs",
  outputDir: "./test-results",
  // Realtime, multi-user flows share the one dev DB + PubSub; serialize so state stays
  // legible and a sender/receiver pair isn't racing another test's traffic.
  fullyParallel: false,
  workers: 1,
  retries: 1,
  timeout: 40_000,
  expect: { timeout: 10_000 },
  globalSetup: require.resolve("./global-setup.js"),
  reporter: [
    ["list"],
    ["html", { outputFolder: "./playwright-report", open: "never" }],
    ["json", { outputFile: "./test-results/results.json" }],
  ],
  use: {
    baseURL: seed.base_url || "http://localhost:4001",
    trace: "retain-on-failure",
    video: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 12_000,
  },
  projects: [
    { name: "desktop-firefox", use: { ...devices["Desktop Firefox"], viewport: { width: 1280, height: 880 } } },
    { name: "desktop-chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 880 } } },
    { name: "desktop-webkit", use: { ...devices["Desktop Safari"], viewport: { width: 1280, height: 880 } } },
    // Real mobile engines: iPhone (WebKit/Safari) + Pixel (Chromium/Android). Firefox has
    // no touch/isMobile emulation, so mobile uses WebKit + Chromium (desktop covers FF).
    { name: "mobile-safari", use: { ...devices["iPhone 13"] } },
    { name: "mobile-chrome", use: { ...devices["Pixel 7"] } },
  ],
})
