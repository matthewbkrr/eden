// Message-cache GC on the write path (#509, part of epic #506).
//
// `MsgCache.put` ran a full store walk after every write. The cursor was opened with
// `openCursor()`, and touching `cur.value` is a mandatory structured-deserialize of the FULL
// record including the `html` field (up to 1 MB). The store holds 25 records and `put` is called
// twice per navigation — a snapshot of the chat being left and of the one arriving — so switching
// chats cost up to 50 deserializations and tens of MB of transient allocation, for two numbers
// that already lived in the index keys.
//
// The oracle here is SELF-CALIBRATING: it compares write time against a "fat" versus a "thin"
// store holding the SAME number of records. Under the bug the fat store is several times slower;
// once fixed there is no difference. Absolute milliseconds would depend on the machine and on
// throttling — a ratio does not.
const { test, expect } = require("@playwright/test");

const IDB_MAX = 25; // mirrors the constant in msg_cache.js
const FAT_BYTES = 300 * 1024; // a real thread runs ~0.5 MB (see the module); per-record cap is 1 MB

// Measure in BATCHES rather than per-write: Firefox and WebKit coarsen performance.now() to a
// millisecond (privacy.reduceTimerPrecision and its equivalent), so a 0.3 ms write rounds to 0.00
// and the ratio comes out NaN. A batch of BATCH writes adds up to tens of milliseconds, and the
// clamp stops mattering.
const BATCH = 40;
// Take the MINIMUM across batches, not the median: noise can only add time, so the minimum
// estimates the "clean" cost and makes the threshold sturdier (the #527 review rightly called a
// wall-clock assertion fragile). This spec runs by hand, not in CI.
const BATCHES = 3;

// Cyrillic is 2 bytes in UTF-8 and the module budgets a record through Blob, i.e. by honest bytes,
// so the filler is built from it rather than from Latin text.
//
// The measured write is ALWAYS tiny; only the size of the already-stored records varies. Otherwise
// the oracle conflates two effects — the walk, and the legitimate cost of writing a big string
// (the first version measured it that way and reported 2x instead of 1x after the fix).
//
// forceSweep=false is the hot path: overwrite an existing key, the record count stays put (exactly
// the cap), no walk is needed. forceSweep=true makes every write take a NEW key, so the count goes
// past the cap and the walk is forced — that measures the cost of the walk itself when it runs.
async function perPutMs(page, { fillerBytes, forceSweep = false }) {
  return page.evaluate(
    async ({ fillerBytes, stored, batch, batches, forceSweep }) => {
      const cache = window.__edMsgCache;
      const filler = "п".repeat(Math.floor(fillerBytes / 2));
      const user = 7;

      await cache.clearAll();
      if (forceSweep) {
        // Seed the fillers DIRECTLY and with timestamps in the future. Otherwise the measurement
        // degenerates: the walk evicts the oldest record, and the oldest records are the fillers,
        // so within a couple of dozen writes the "fat" store has become thin (the first version of
        // this test reported 0.9x on every engine because of exactly that). With a future stamp the
        // fillers stay the freshest, the tiny records get evicted instead, and the store stays fat
        // for the whole measurement.
        const db = await new Promise((resolve) => {
          const req = indexedDB.open("eden-msg-cache", 1);
          req.onupgradeneeded = () => {
            const os = req.result.createObjectStore("snapshots", { keyPath: "id" });
            os.createIndex("by_updated", "updatedAt", { unique: false });
          };
          req.onsuccess = () => resolve(req.result);
        });
        await new Promise((resolve) => {
          const tx = db.transaction("snapshots", "readwrite");
          const os = tx.objectStore("snapshots");
          for (let i = 1; i <= stored; i++) {
            os.put({ id: `${user}:${i}`, html: filler, updatedAt: Date.now() + 3600_000 + i });
          }
          tx.oncomplete = resolve;
        });
        db.close();
      } else {
        for (let i = 1; i <= stored; i++) await cache.put(user, i, filler);
      }

      const perPut = [];
      let fresh = 1000;
      for (let b = 0; b < batches; b++) {
        const t0 = performance.now();
        for (let i = 0; i < batch; i++) {
          await cache.put(user, forceSweep ? fresh++ : 999, "п");
        }
        perPut.push((performance.now() - t0) / batch);
      }
      return Math.min(...perPut);
    },
    { fillerBytes, stored: IDB_MAX - 1, batch: BATCH, batches: BATCHES, forceSweep },
  );
}

// Read the store directly — assert the FACT of eviction, not what the module claims.
async function storedIds(page) {
  return page.evaluate(async () => {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open("eden-msg-cache", 1);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    const rows = await new Promise((resolve, reject) => {
      const req = db.transaction("snapshots", "readonly").objectStore("snapshots").getAll();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    db.close();
    return rows.map((r) => ({ id: r.id, updatedAt: r.updatedAt }));
  });
}

test.describe("message cache: GC on write", () => {
  test.beforeEach(async ({ page }) => {
    // The login page carries the same bundle and sets window.__edMsgCache, so this measurement
    // needs no auth, no seeded data and no throttling runner — which keeps the harness
    // deterministic.
    await page.goto("/login");
    await page.waitForFunction(() => !!window.__edMsgCache);
  });

  test("write cost is independent of how much the store holds", async ({ page }, testInfo) => {
    const thin = await perPutMs(page, { fillerBytes: 512 });
    const fat = await perPutMs(page, { fillerBytes: FAT_BYTES });
    const ratio = fat / thin;

    const line =
      `tiny write with ${IDB_MAX} records stored: thin store ${thin.toFixed(2)} ms, ` +
      `fat (${FAT_BYTES / 1024} KB/record) ${fat.toFixed(2)} ms, ratio ${ratio.toFixed(2)}x`;
    console.log(line);
    testInfo.annotations.push({ type: "measurement", description: line });

    expect(ratio, `GC deserializes records: ${line}`).toBeLessThan(2);
  });

  test("the walk, when it does run, does not read record values", async ({ page }, testInfo) => {
    // The gate makes the walk rare, which stopped the cursor type from being observable on the hot
    // path: reverting to `openCursor` broke no test. Here the walk is forced (every write takes a
    // new key, so the count goes past the cap) and reading values becomes visible again. This
    // matters for Android, whose WebView is Chromium — where a key cursor genuinely does not
    // materialize the record.
    const thin = await perPutMs(page, { fillerBytes: 512, forceSweep: true });
    const fat = await perPutMs(page, { fillerBytes: FAT_BYTES, forceSweep: true });
    const ratio = fat / thin;

    const line =
      `forced walk: thin store ${thin.toFixed(2)} ms, fat ${fat.toFixed(2)} ms, ` +
      `ratio ${ratio.toFixed(2)}x`;
    console.log(line);
    testInfo.annotations.push({ type: "measurement", description: line });

    // WebKit materializes the record even on a key cursor, so the invariant is unreachable there —
    // which is precisely why the gate above exists. Assert on the engines where it is reachable.
    const engine = testInfo.project.name;
    if (engine.includes("webkit") || engine.includes("safari")) {
      testInfo.annotations.push({
        type: "skipped",
        description: "WebKit reads values even on a key cursor — asserted on the other engines",
      });
      return;
    }
    expect(ratio, `the walk deserializes records: ${line}`).toBeLessThan(2);
  });

  test("records past TTL are evicted by the one-off pass on a fresh handle", async ({ page }) => {
    // The TTL pass no longer runs on every write (#509): an expired snapshot is never handed out
    // anyway — TTL is checked on read — so the walk only exists to reclaim disk, and it runs once
    // per DB handle. A fresh handle means a new app launch; here `clearAll` plays that role, after
    // which `put` reopens the database.
    await page.evaluate(async () => {
      const cache = window.__edMsgCache;
      await cache.clearAll();

      // Seed the expired record DIRECTLY, over its own connection: `put` stamps Date.now(), so TTL
      // cannot be faked through the public API.
      const db = await new Promise((resolve) => {
        const req = indexedDB.open("eden-msg-cache", 1);
        req.onupgradeneeded = () => {
          const os = req.result.createObjectStore("snapshots", { keyPath: "id" });
          os.createIndex("by_updated", "updatedAt", { unique: false });
        };
        req.onsuccess = () => resolve(req.result);
      });
      await new Promise((resolve) => {
        const tx = db.transaction("snapshots", "readwrite");
        tx.objectStore("snapshots").put({
          id: "7:999",
          html: "ancient",
          updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000, // TTL is 7 days
        });
        tx.oncomplete = resolve;
      });
      db.close();

      // The first write on a fresh handle is the one that runs the pass.
      await cache.put(7, 1, "fresh");
    });

    const ids = (await storedIds(page)).map((r) => r.id).sort();
    expect(ids, "the expired snapshot survived in the store").toEqual(["7:1"]);
  });

  test("an ordinary write does NOT run the walk — otherwise it is back on the hot path", async ({
    page,
  }) => {
    // The ratio above catches a walk-per-write regression only on WebKit: on Chromium a key cursor
    // is cheap and the test would pass. So the gate is checked functionally too — deterministically
    // and on every engine.
    //
    // What is asserted is the ABSENCE of housekeeping, and that is not indulging garbage: an
    // expired snapshot is never handed out (TTL is checked on read in `peek`/`get`), it merely
    // occupies space until the next launch. If it disappears after an ordinary write, the walk is
    // running on every one — which is the #509 defect itself.
    await page.evaluate(async () => {
      const cache = window.__edMsgCache;
      await cache.clearAll();
      await cache.put(7, 1, "fresh"); // first on a fresh handle — the one-off pass

      const db = await new Promise((resolve) => {
        const req = indexedDB.open("eden-msg-cache", 1);
        req.onsuccess = () => resolve(req.result);
      });
      await new Promise((resolve) => {
        const tx = db.transaction("snapshots", "readwrite");
        tx.objectStore("snapshots").put({
          id: "7:999",
          html: "ancient",
          updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000,
        });
        tx.oncomplete = resolve;
      });
      db.close();

      // An ordinary write: the handle is already swept and the count is far from the cap, so no
      // walk should happen.
      await cache.put(7, 2, "also fresh");
    });

    const ids = (await storedIds(page)).map((r) => r.id).sort();
    expect(ids, "the walk ran on an ordinary write — it is back on the hot path").toEqual([
      "7:1",
      "7:2",
      "7:999",
    ]);
  });

  test("on overflow the freshest survive, not an arbitrary set", async ({ page }) => {
    const over = IDB_MAX + 5;
    await page.evaluate(
      async ({ over }) => {
        const cache = window.__edMsgCache;
        await cache.clearAll();
        // Distinct updatedAt values: `put` stamps Date.now(), so write order is freshness order.
        for (let i = 1; i <= over; i++) {
          await cache.put(7, i, `snapshot ${i}`);
          await new Promise((r) => setTimeout(r, 2));
        }
      },
      { over },
    );

    const rows = await storedIds(page);
    expect(rows.length, "the store cap was not honoured").toBe(IDB_MAX);

    // What must remain is the last IDB_MAX records written.
    const kept = rows.map((r) => Number(r.id.split(":")[1])).sort((a, b) => a - b);
    const expected = Array.from({ length: IDB_MAX }, (_, i) => over - IDB_MAX + 1 + i);
    expect(kept, "the evicted ones were not the oldest").toEqual(expected);
  });
});
