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
    req.onsuccess = () => resolve(req.result);
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

// Put a snapshot, then GC in the SAME transaction (no await between requests — WebKit auto-commits
// an IndexedDB tx across await points): drop anything past TTL, then trim the oldest survivors down
// to IDB_MAX. The cursor walks by_updated oldest-first, so the overflow to delete is at the front.
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
    const cutoff = Date.now() - TTL_MS;
    const survivors = [];
    os.index("by_updated").openCursor().onsuccess = (e) => {
      const cur = e.target.result;
      if (cur) {
        if (cur.value.updatedAt < cutoff) cur.delete();
        else survivors.push(cur.primaryKey);
        cur.continue();
      } else {
        for (let i = 0; i < survivors.length - IDB_MAX; i++) os.delete(survivors[i]);
      }
    };
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
  });
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
  async put(userId, convId, html) {
    if (!userId || !convId || typeof html !== "string" || html.length > MAX_BYTES) return;
    const rec = { id: key(userId, convId), html, updatedAt: Date.now() };
    this._memSet(rec.id, { html: rec.html, updatedAt: rec.updatedAt });
    const db = await this.db();
    if (!db) return;
    try {
      await idbPut(db, rec);
    } catch (e) {
      this._fail("put", e);
    }
  },

  // Best-effort: ask the browser not to evict our storage. Never blocks or throws.
  async requestPersist() {
    try {
      if (navigator.storage && navigator.storage.persist) await navigator.storage.persist();
    } catch (_e) {
      /* ignore */
    }
  },
};
