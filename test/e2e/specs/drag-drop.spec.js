const { test, expect } = require("../helpers/fixtures")

// #207: drag files from the OS into the chat / thread pane → staged into the composer (reuses
// the paste path). The overlay shows only over the pane you're dragging into; the thread and
// main drop zones never both activate (no overlap).
const drag = (page, id, type) =>
  page.evaluate(
    ({ id, type }) => {
      const b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
      const dt = new DataTransfer()
      dt.items.add(new File([bytes], "drop.png", { type: "image/png" }))
      document
        .getElementById(id)
        .dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true }))
    },
    { id, type }
  )

test("dropping a file into the chat stages it; zones don't overlap (#207)", async ({ alice, seed }) => {
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await alice.waitForSelector("#chat-dropzone", { timeout: 15000 })
  await alice.waitForTimeout(500)

  // The overlay is SERVER-rendered (survives morphdom re-renders) — present at mount, not lazily
  // appended by the hook (#207 P1 regression guard).
  await expect(alice.locator("#chat-dropzone > .ed-dropzone__overlay")).toHaveCount(1)

  // 1. Dragging over the main pane shows its overlay.
  await drag(alice, "chat-dropzone", "dragenter")
  await drag(alice, "chat-dropzone", "dragover")
  await alice.waitForTimeout(200)
  await expect(alice.locator("#chat-dropzone.ed-dropzone--over")).toHaveCount(1)
  await drag(alice, "chat-dropzone", "dragleave")
  await alice.waitForTimeout(150)

  // 2. Open a thread (before any drop, so its footer is clickable) → zones must be exclusive.
  await alice.locator(".ed-thread-footer").first().click()
  await alice.waitForSelector("#thread-dropzone", { timeout: 8000 })
  await alice.waitForTimeout(300)
  const overState = () =>
    alice.evaluate(() => ({
      main: !!document.querySelector("#chat-dropzone.ed-dropzone--over"),
      thread: !!document.querySelector("#thread-dropzone.ed-dropzone--over"),
    }))

  await drag(alice, "thread-dropzone", "dragenter")
  await drag(alice, "thread-dropzone", "dragover")
  await alice.waitForTimeout(150)
  expect(await overState()).toEqual({ main: false, thread: true })
  await drag(alice, "thread-dropzone", "dragleave")
  await alice.waitForTimeout(150)

  await drag(alice, "chat-dropzone", "dragenter")
  await drag(alice, "chat-dropzone", "dragover")
  await alice.waitForTimeout(150)
  expect(await overState()).toEqual({ main: true, thread: false })

  // 3. Drop on the main pane → the file stages into the composer.
  await drag(alice, "chat-dropzone", "drop")
  await expect.poll(() => alice.locator(".ed-compose__tile").count(), { timeout: 6000 }).toBeGreaterThan(0)
})
