const path = require("path"); const home = require("os").homedir()
const { firefox } = require(path.join(home, "node_modules/@playwright/test"))
const e2e = path.join(__dirname, "..")
const seed = require(path.join(e2e, ".seed.json"))
async function shot(authKey, out, setAvatar) {
  const b = await firefox.launch()
  const ctx = await b.newContext({ storageState: path.join(e2e, ".auth", authKey + ".json") })
  const p = await ctx.newPage()
  await p.setViewportSize({ width: 1320, height: 900 })
  await p.goto(seed.base_url + "/app/c/" + seed.group_id)
  await p.waitForFunction(() => window.liveSocket?.isConnected())
  await p.locator("[data-profile-trigger]").click()
  await p.waitForSelector(".ed-profile")
  if (setAvatar) {
    await p.locator(".ed-avatar-edit input[type='file']").setInputFiles(path.join(e2e, "fixtures", "sample2.png"))
    await p.waitForSelector(".ed-avatar-edit img", { timeout: 8000 })
  }
  await p.waitForTimeout(300)
  await p.locator(".ed-profile").screenshot({ path: out })
  await b.close()
}
;(async () => {
  await shot("alice", "test/e2e/scratch/panel-avatar.png", true)
  await shot("bob", "test/e2e/scratch/panel-member.png", false)
  console.log("captured both")
})().catch(e => { console.error(e.message); process.exit(1) })
