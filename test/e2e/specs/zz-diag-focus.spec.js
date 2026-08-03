const { test } = require("../helpers/fixtures")

test("what has focus after opening a chat on a phone", async ({ alice, seed }) => {
  const describe = () =>
    alice.evaluate(() => {
      const a = document.activeElement
      if (!a) return "none"
      const ring = [...document.querySelectorAll("*")]
        .filter((n) => n.matches(":focus-visible"))
        .map((n) => `${n.tagName}.${n.className}`)
      return {
        ring,
        tag: a.tagName,
        cls: (a.className || "").toString(),
        label: a.getAttribute("aria-label") || a.textContent?.trim().slice(0, 30),
        focusVisible: a.matches(":focus-visible"),
        outline: getComputedStyle(a).outlineWidth + " " + getComputedStyle(a).outlineColor,
      }
    })

  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  console.log("ON LIST", JSON.stringify(await describe()))

  // Enter a chat the way a finger does.
  await alice.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"] a.ed-convo`).first().tap()
  await alice.waitForTimeout(1200)
  console.log("AFTER TAP INTO CHAT", JSON.stringify(await describe()))

  // And the lightbox, whose <dialog> autofocuses its first control.
  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()
  await tile.tap()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await alice.waitForTimeout(400)
  console.log("IN LIGHTBOX", JSON.stringify(await describe()))
})
