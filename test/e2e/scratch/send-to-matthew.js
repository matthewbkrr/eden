// Throwaway live-notification sender: drives e2e_bob's saved session to message Matthew
// (DM #40) on the running dev server, so the real notification path (PubSub → Matthew's
// open LiveView → desktop notification / chime) fires against Matthew's actual browser.
//
//   node test/e2e/scratch/send-to-matthew.js [count=5] [intervalSec=5]
//
// Sender runs headless; it's only there to POST messages through the live server.
const path = require("path")
const fs = require("fs")
const home = require("os").homedir()
const { firefox } = require(path.join(home, "node_modules/@playwright/test"))

const e2e = path.join(__dirname, "..")
const seed = JSON.parse(fs.readFileSync(path.join(e2e, ".seed.json"), "utf8"))
const baseURL = seed.base_url || "http://localhost:4001"
const storageState = path.join(e2e, ".auth", "bob.json")
const CONV = 40 // Matthew (id 1) ↔ e2e_bob (id 29) 1:1 DM

const count = parseInt(process.argv[2] || "5", 10)
const intervalMs = parseInt(process.argv[3] || "5", 10) * 1000

const LINES = [
  "Привет! Тестируем десктопные уведомления 🔔",
  "Это второе сообщение — видно всплывашку ОС?",
  "Третье. Должно прийти даже когда ты в другом окне.",
  "Четвёртое сообщение подряд (один тег — заменяет прошлое).",
  "Пятое. Кликни по уведомлению — откроется этот чат.",
  "Шестое — проверяем звук системного уведомления.",
  "Седьмое. Аватарка должна быть на уведомлении.",
  "Восьмое сообщение в очереди.",
  "Девятое — почти всё.",
  "Десятое, финальное. Готово ✅",
]

;(async () => {
  const browser = await firefox.launch()
  const ctx = await browser.newContext({ storageState })
  const page = await ctx.newPage()
  await page.goto(`${baseURL}/app/c/${CONV}`)
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15000,
  })
  console.log(`[sender] connected as e2e_bob → DM #${CONV}; sending ${count} every ${intervalMs / 1000}s`)
  for (let i = 0; i < count; i++) {
    const text = `${LINES[i % LINES.length]} (${i + 1}/${count})`
    await page.fill("#composer-body", text)
    await page.locator("#composer").evaluate((f) => f.requestSubmit())
    console.log(`[sender] ${new Date().toLocaleTimeString()}  #${i + 1}/${count}  ${text}`)
    if (i < count - 1) await page.waitForTimeout(intervalMs)
  }
  await page.waitForTimeout(1000)
  await browser.close()
  console.log("[sender] done")
})().catch((e) => {
  console.error("[sender] FAILED:", e.message)
  process.exit(1)
})
