// Съёмка всех скриншотов handbook-документации с локального дев-сервера (:4001).
//
// Запуск (после tools/seed_demo.exs, из любого каталога):
//   NODE_PATH=~/node_modules node docs/handbook/tools/shots.js
//
// Селекторы, о которые уже спотыкались (не «упрощать»):
//   • контекстное меню — dispatchEvent("contextmenu", {bubbles: true}) на .ed-bubble,
//     меню = ".ed-menu:visible" (хук вешается на пузырь, событие должно всплыть);
//   • тред — клик по ".ed-thread-footer" (текст «N ответов» кликается только там);
//   • эмодзи-пикер — "[data-emoji-toggle]";
//   • «Новая беседа» — getByRole("button"), голый getByText матчит скрытый дубль.
const { chromium } = require("playwright")
const { execSync } = require("child_process")
const fs = require("fs")
const path = require("path")

const HANDBOOK = path.resolve(__dirname, "..")
const REPO = path.resolve(__dirname, "..", "..", "..")
const demo = JSON.parse(fs.readFileSync(path.join(HANDBOOK, ".demo.json"), "utf8"))
const OUT = path.join(HANDBOOK, "shots")
fs.mkdirSync(OUT, { recursive: true })

const BASE = demo.base_url

async function connected(page) {
  await page.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 15000 }).catch(() => {})
  await page.waitForTimeout(600)
}

async function imagesSettled(page) {
  await page
    .waitForFunction(() => [...document.querySelectorAll("img")].every((i) => i.complete), null, { timeout: 8000 })
    .catch(() => {})
  await page.waitForTimeout(400)
}

async function login(page, username) {
  await page.goto(BASE + "/login")
  await page.locator("#user_username").waitFor({ state: "visible" })
  await page.waitForTimeout(1200) // LoginLive на connect перерисовывает форму и стирает ранний ввод
  await page.fill("#user_username", username)
  await page.fill("#user_password", demo.password)
  await page.evaluate(() => document.querySelector("#user_username").form.requestSubmit())
}

function totpCode() {
  return execSync(
    `cd ${REPO} && mix run --no-start -e 'IO.puts NimbleTOTP.verification_code(Base.decode64!("${demo.totp_secret_b64}"))'`,
    { encoding: "utf8" }
  )
    .trim()
    .split("\n")
    .pop()
}

async function shot(page, name) {
  await page.screenshot({ path: path.join(OUT, name + ".png") })
  console.log("  ✓ " + name)
}

async function step(name, fn) {
  try {
    await fn()
  } catch (e) {
    console.log("  ✗ " + name + ": " + e.message.split("\n")[0])
  }
}

;(async () => {
  const browser = await chromium.launch()
  const desktop = { locale: "ru-RU", viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 }

  // ── Экраны без входа ──────────────────────────────────────────────────────
  {
    const ctx = await browser.newContext(desktop)
    const page = await ctx.newPage()

    await step("01-login", async () => {
      await page.goto(BASE + "/login")
      await connected(page)
      await shot(page, "01-login")
    })

    await step("02-invite", async () => {
      await page.goto(BASE + "/invite/" + demo.invite_token)
      await connected(page)
      await shot(page, "02-invite")
    })

    await ctx.close()
  }

  // ── Анна: основной тур ────────────────────────────────────────────────────
  const annaCtx = await browser.newContext(desktop)
  const page = await annaCtx.newPage()
  await login(page, "anna")
  await page.waitForURL("**/app**", { timeout: 15000 })
  await connected(page)

  // Сайдбар с непрочитанными — СНИМАТЬ ДО открытия чатов (открытие гасит бейджи).
  await step("04-app-home", async () => {
    await imagesSettled(page)
    await shot(page, "04-app-home")
  })

  await step("05-dm", async () => {
    await page.goto(BASE + "/app/c/" + demo.dm_boris_id)
    await connected(page)
    await imagesSettled(page)
    await shot(page, "05-dm")
  })

  await step("06-context-menu", async () => {
    const bubble = page.locator(".ed-bubble", { hasText: "тогда доведу первый" }).first()
    const menu = page.locator(".ed-menu:visible").first()
    for (let i = 0; i < 10; i++) {
      await bubble.scrollIntoViewIfNeeded().catch(() => {})
      await bubble.dispatchEvent("contextmenu", { bubbles: true })
      await page.waitForTimeout(500)
      if (await menu.count()) break
    }
    await page.waitForTimeout(300)
    await shot(page, "06-context-menu")
    await page.keyboard.press("Escape")
    await page.waitForTimeout(400)
  })

  await step("19-lightbox", async () => {
    const img = page.locator("#messages img").first()
    await img.click()
    await page.waitForTimeout(1000)
    await imagesSettled(page)
    await shot(page, "19-lightbox")
    await page.keyboard.press("Escape")
    await page.waitForTimeout(400)
  })

  await step("20-emoji-picker", async () => {
    await page.locator("[data-emoji-toggle]").first().click()
    await page.waitForTimeout(800)
    await shot(page, "20-emoji-picker")
    await page.keyboard.press("Escape")
    await page.waitForTimeout(300)
  })

  await step("07-group", async () => {
    await page.goto(BASE + "/app/c/" + demo.group_id)
    await connected(page)
    await imagesSettled(page)
    await shot(page, "07-group")
  })

  await step("08-search", async () => {
    await page.goto(BASE + "/app")
    await connected(page)
    const search = page
      .locator("input[type='search'], input[placeholder*='оиск'], input[placeholder*='earch']")
      .first()
    await search.click()
    await search.fill("планёрка")
    await page.waitForTimeout(1200)
    await shot(page, "08-search")
  })

  await step("09-room", async () => {
    await page.goto(BASE + "/channels/" + demo.channel_id + "/r/" + demo.general_id)
    await connected(page)
    await imagesSettled(page)
    await shot(page, "09-room")
  })

  await step("10-thread", async () => {
    await page.locator(".ed-thread-footer").first().click()
    await page.waitForTimeout(1500)
    await imagesSettled(page)
    await shot(page, "10-thread")
  })

  await step("11-channel-rooms", async () => {
    await page.goto(BASE + "/channels/" + demo.channel_id)
    await connected(page)
    await shot(page, "11-channel-rooms")
  })

  for (const section of ["profile", "security", "folders", "appearance", "notifications"]) {
    await step("12-settings-" + section, async () => {
      await page.goto(BASE + "/settings/" + section)
      await connected(page)
      await imagesSettled(page)
      await shot(page, "12-settings-" + section)
    })
  }

  await step("21-new-chat", async () => {
    await page.goto(BASE + "/app")
    await connected(page)
    await page.getByRole("button", { name: /Новая беседа/ }).first().click()
    await page.waitForTimeout(900)
    await imagesSettled(page)
    await shot(page, "21-new-chat")
  })

  const annaState = await annaCtx.storageState()
  await annaCtx.close()

  // ── Мобильные кадры (Анна) ────────────────────────────────────────────────
  {
    const ctx = await browser.newContext({
      locale: "ru-RU",
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 3,
      isMobile: true,
      hasTouch: true,
      storageState: annaState,
    })
    const mp = await ctx.newPage()

    await step("17-mobile-chats", async () => {
      await mp.goto(BASE + "/app")
      await connected(mp)
      await imagesSettled(mp)
      await shot(mp, "17-mobile-chats")
    })

    await step("18-mobile-dm", async () => {
      await mp.goto(BASE + "/app/c/" + demo.dm_boris_id)
      await connected(mp)
      await imagesSettled(mp)
      await shot(mp, "18-mobile-dm")
    })

    await ctx.close()
  }

  // ── Ирина: 2FA-челлендж + админ-панель (у админов TOTP обязателен) ────────
  {
    const ctx = await browser.newContext(desktop)
    const ip = await ctx.newPage()

    await step("03-totp + 16-admin", async () => {
      await login(ip, "irina")
      await ip.waitForURL("**/login/totp**", { timeout: 15000 })
      await connected(ip)
      await shot(ip, "03-totp")

      const code = totpCode()
      const codeInput = ip
        .locator("input[name*='code'], input[autocomplete='one-time-code'], input[inputmode='numeric']")
        .first()
      await codeInput.fill(code)
      await ip.evaluate(() => document.querySelector("form")?.requestSubmit())
      await ip.waitForURL("**/app**", { timeout: 15000 })

      await ip.goto(BASE + "/admin")
      await connected(ip)
      await imagesSettled(ip)
      await shot(ip, "16-admin")
    })

    await ctx.close()
  }

  await browser.close()
  console.log("done → " + OUT)
})()
