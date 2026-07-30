// Message-list cache (instant navigation, phase 2) — snapshots the rendered #messages HTML per
// conversation so re-opening a chat paints its last-seen thread from cache INSTANTLY (even
// offline), while the real stream loads in the background and replaces it. This only ever feeds
// the display-only instant-nav overlay, which the real stream always supersedes — so a slightly
// stale snapshot self-corrects within one round-trip and is never authoritative.
//
// Two layers: a synchronous in-memory LRU (same-session revisits paint with zero await, no
// skeleton flash) backed by IndexedDB (survives reloads / app restarts). Scoped by user id so one
// account never sees another's cached messages on a shared browser. Every IDB call is wrapped: if
// IndexedDB is unavailable (Safari private mode, quota, blocked DB) it degrades to memory-only
// (and, past a reload, to the plain skeleton) without throwing — modelled on ./send_store.

const DB_NAME = "eden-msg-cache";
const STORE = "snapshots";
const TTL_MS = 7 * 24 * 60 * 60 * 1000; // snapshots older than 7d are ignored + GC'd
const MEM_MAX = 30; // in-memory LRU cap (conversations)
const IDB_MAX = 25; // persisted-snapshot cap (newest-by-updatedAt kept) — bounds the DB to ~25 MB
// A rendered 50-message window runs ~0.5 MB (every bubble carries inline heroicon SVGs + menus), so
// the cap has headroom for a heavy thread; anything larger just falls back to the skeleton.
const MAX_BYTES = 1024 * 1024;

const key = (userId, convId) => `${userId}:${convId}`;

function openDB() {
  return new Promise((resolve, reject) => {
    let req;
    try {
      req = indexedDB.open(DB_NAME, 1);
    } catch (e) {
      reject(e);
      return;
    }
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const os = db.createObjectStore(STORE, { keyPath: "id" });
        os.createIndex("by_updated", "updatedAt", { unique: false });
      }
    };
    req.onsuccess = () => {
      const db = req.result;
      // Another tab ran clearAll's deleteDatabase (logout there): close our handle so the
      // delete can proceed. Don't mark the store broken — the next db() just reopens.
      db.onversionchange = () => {
        try {
          db.close();
        } catch (_e) {
          /* already closing */
        }
        if (MsgCache._db === db) MsgCache._db = null;
      };
      resolve(db);
    };
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error("blocked"));
  });
}

// Read one snapshot by key. Resolves with the record (or null) on tx.oncomplete.
function idbGet(db, k) {
  return new Promise((resolve, reject) => {
    let tx;
    try {
      tx = db.transaction(STORE, "readonly");
    } catch (e) {
      reject(e);
      return;
    }
    let val = null;
    tx.objectStore(STORE).get(k).onsuccess = (e) => (val = e.target.result || null);
    tx.oncomplete = () => resolve(val);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
  });
}

// Which DB handle has already had a full eviction pass. The TTL pass is needed once per
// session: it only reclaims disk, because an expired record is never handed out anyway — TTL is
// checked on READ (see `peek`/`get`). The flag rides the HANDLE rather than a clock: a new handle
// means a new app launch (or a `clearAll`), which is exactly when housekeeping belongs.
let sweptHandle = null;

// Put a snapshot, then GC in the SAME transaction (no await between requests — WebKit auto-commits
// an IndexedDB tx across await points): drop anything past TTL, then trim the oldest survivors down
// to IDB_MAX. The cursor walks by_updated oldest-first, so the overflow to delete is at the front.
// Eviction, though, does NOT run after every put (#509) — see the gate below. No request in this
// transaction awaits anything, or WebKit would commit it out from under us, exactly as the line
// above warns.
function idbPut(db, record) {
  return new Promise((resolve, reject) => {
    let tx;
    try {
      tx = db.transaction(STORE, "readwrite");
    } catch (e) {
      reject(e);
      return;
    }
    const os = tx.objectStore(STORE);
    os.put(record);
    // GC IS OFF THE HOT PATH (#509). A full store walk used to run after EVERY put, and `put` is
    // called twice per navigation — a snapshot of the chat being left and of the one arriving.
    // Walking is worth it in exactly two cases: the record count went past the cap (something must
    // be evicted), or this is the first put on a fresh DB handle (the one-off TTL pass). `count()`
    // counts records without reading them, so unlike the walk it does not care how many bytes they
    // hold.
    //
    // In practice a person re-opens the same dozen chats all session, so almost every put
    // overwrites an existing key and the count does not move. The walk now happens when a NEW
    // conversation is cached, not on every snapshot refresh.
    const firstOnHandle = sweptHandle !== db;
    let swept = false;
    const countReq = os.count();
    countReq.onsuccess = () => {
      if (!firstOnHandle && countReq.result <= IDB_MAX) return;
      swept = true;
      sweep(os);
    };
    // The handle is marked swept ONLY after the commit. Marking it up front would let a failed or
    // aborted transaction still count as housekeeping, and the one-off TTL pass would never be
    // retried for the rest of the handle's life (#527 review). On an abort `oncomplete` never
    // fires, the flag stays clear, and the next put tries again.
    tx.oncomplete = () => {
      if (swept) sweptHandle = db;
      resolve();
    };
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
  });
}

// Eviction: anything past TTL, plus whatever overflows the cap. Runs in the SAME transaction as
// the put, so atomicity is unchanged.
//
// `openKeyCursor`, NOT `openCursor`: on a cursor over an index, `key` IS the `updatedAt` and
// `primaryKey` is the id — everything the walk needs already lives in the keys. Touching
// `cur.value` would make the engine structured-deserialize the FULL record including the `html`
// field (up to MAX_BYTES = 1 MB), once per stored record. On Chromium and Firefox that removes the
// walk's dependence on record size entirely; WebKit (i.e. WKWebView, i.e. iOS) materializes the
// record even on a key cursor, so there the win comes from the walk no longer running per put.
function sweep(os) {
  const cutoff = Date.now() - TTL_MS;
  const expired = [];
  const survivors = [];
  os.index("by_updated").openKeyCursor().onsuccess = (e) => {
    const cur = e.target.result;
    if (cur) {
      if (cur.key < cutoff) expired.push(cur.primaryKey);
      else survivors.push(cur.primaryKey);
      cur.continue();
      return;
    }
    // Delete AFTER the walk: `cur.delete()` on a key cursor throws InvalidStateError — the spec
    // only allows deleting through a value cursor. The cursor walks `updatedAt` ascending, so the
    // overflow past the cap is at the front of `survivors`, the oldest ones.
    for (const pk of expired) os.delete(pk);
    for (let i = 0; i < survivors.length - IDB_MAX; i++) os.delete(survivors[i]);
  };
}

export const MsgCache = {
  _db: null,
  _broken: false,
  _warned: false,
  _mem: new Map(), // key -> {html, theme, updatedAt}; Map insertion order backs the LRU

  _fail(where, e) {
    this._broken = true;
    if (!this._warned) {
      this._warned = true;
      console.warn(`[msg-cache] disabled (${where}); chats won't paint from cache:`, e && e.message);
    }
  },

  async db() {
    if (this._broken || typeof indexedDB === "undefined") return null;
    if (this._db) return this._db;
    try {
      this._db = await openDB();
      return this._db;
    } catch (e) {
      this._fail("open", e);
      return null;
    }
  },

  // Synchronous in-memory peek — a same-session revisit paints cache with NO await (no skeleton
  // flash). Returns {html} or null; refreshes LRU recency and honours TTL. (No theme is stored:
  // message colours come from CSS var(--ed-*) resolved against the live [data-theme], so a snapshot
  // taken in light renders correctly in dark and vice-versa.)
  peek(userId, convId) {
    const k = key(userId, convId);
    const rec = this._mem.get(k);
    if (!rec) return null;
    if (rec.updatedAt < Date.now() - TTL_MS) {
      this._mem.delete(k);
      return null;
    }
    this._mem.delete(k);
    this._mem.set(k, rec); // move to most-recent
    return rec;
  },

  // Async get: memory first, then IndexedDB (a cross-reload first hit); populates memory on the way.
  async get(userId, convId) {
    const hit = this.peek(userId, convId);
    if (hit) return hit;
    const db = await this.db();
    if (!db) return null;
    try {
      const rec = await idbGet(db, key(userId, convId));
      if (!rec || rec.updatedAt < Date.now() - TTL_MS) return null;
      this._memSet(key(userId, convId), rec);
      return rec;
    } catch (e) {
      this._fail("get", e);
      return null;
    }
  },

  _memSet(k, rec) {
    this._mem.delete(k);
    this._mem.set(k, rec);
    // Evict least-recently-used beyond the cap (Map iterates in insertion order, oldest first).
    while (this._mem.size > MEM_MAX) this._mem.delete(this._mem.keys().next().value);
  },

  // Cache the current render of a conversation. Skips oversized snapshots (media-heavy rooms) so
  // one huge thread can't dominate the store. Best-effort persistence; never throws.
  // `name` (optional) is the pane header title at snapshot time — the rail's instant
  // room-open (#445) has no sidebar row to read a title from, so the cache carries it.
  async put(userId, convId, html, name) {
    // Blob([html]).size is the real UTF-8 byte length (html.length counts UTF-16 code units, which
    // undercounts Cyrillic ~2×); this keeps the store bound honest for a RU app.
    if (!userId || !convId || typeof html !== "string" || new Blob([html]).size > MAX_BYTES) return;
    const rec = { id: key(userId, convId), html, updatedAt: Date.now() };
    if (typeof name === "string" && name) rec.name = name.slice(0, 200);
    // A nameless refresh (paneTitle missed mid-transition) must not erase a previously
    // captured name — the record is replaced wholesale (#446 review). Memory-first,
    // best-effort: a cross-reload nameless put can still drop it, and the overlay just
    // falls back to the channel name for a round-trip.
    if (!rec.name) {
      const prior = this._mem.get(rec.id);
      if (prior && prior.name) rec.name = prior.name;
    }
    this._memSet(rec.id, { html: rec.html, name: rec.name, updatedAt: rec.updatedAt });
    const db = await this.db();
    if (!db) return;
    try {
      await idbPut(db, rec);
    } catch (e) {
      this._fail("put", e);
    }
  },

  // Wipe every cached snapshot (all users) — a person's messages must not sit at rest in
  // IndexedDB after their session ends. Deliberately does NOT go through db()/_broken: the wipe
  // must work even when the store previously errored (quota etc.), so it closes any handle and
  // deletes the whole database. onblocked (another tab holds a connection) still resolves — that
  // tab's onversionchange closes it and the delete completes; blocked = same user still active
  // there, which is fine.
  async clearAll() {
    this._mem.clear();
    try {
      if (this._db) this._db.close();
    } catch (_e) {
      /* already closing */
    }
    this._db = null;
    this._broken = false; // the wipe resets the store; a fresh session may reopen cleanly
    sweptHandle = null; // the DB is gone; the next handle earns its one-off pass again
    if (typeof indexedDB === "undefined") return;
    await new Promise((resolve) => {
      let req;
      try {
        req = indexedDB.deleteDatabase(DB_NAME);
      } catch (_e) {
        resolve();
        return;
      }
      req.onsuccess = req.onerror = req.onblocked = () => resolve();
    });
  },
};
