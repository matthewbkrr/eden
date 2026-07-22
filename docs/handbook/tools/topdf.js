// Сборка PDF из HTML-источников handbook (после shots.js/postprocess.exs):
//   NODE_PATH=~/node_modules node docs/handbook/tools/topdf.js
// Результат: docs/handbook/dist/*.pdf (гитигнорится; для раздачи копируйте куда нужно).
const { chromium } = require("playwright")
const fs = require("fs")
const path = require("path")

const HANDBOOK = path.resolve(__dirname, "..")
const DIST = path.join(HANDBOOK, "dist")
fs.mkdirSync(DIST, { recursive: true })

const jobs = [
  ["user-guide.html", "ihichat — руководство пользователя.pdf"],
  ["tech-doc.html", "ihichat — техническое описание.pdf"],
]

;(async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  for (const [src, out] of jobs) {
    await page.goto("file://" + path.join(HANDBOOK, src), { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    await page.pdf({
      path: path.join(DIST, out),
      format: "A4",
      printBackground: true,
      margin: { top: "16mm", bottom: "16mm", left: "17mm", right: "17mm" },
      displayHeaderFooter: true,
      headerTemplate: "<span></span>",
      footerTemplate:
        '<div style="width:100%; text-align:center; font-size:8px; color:#8a93a3; font-family:Arial;">' +
        '<span class="pageNumber"></span> / <span class="totalPages"></span></div>',
    })
    console.log("✓ " + out)
  }
  await browser.close()
})()
