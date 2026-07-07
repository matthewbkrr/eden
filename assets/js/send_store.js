// Durable send queue (TG-attachments, phase E) — persists each in-flight attachment (its File +
// metadata) to IndexedDB so a page reload mid-upload doesn't lose it: on the next mount the hook
// scans this store, rebuilds the optimistic bubble, and re-feeds the unfinished items through the
// sequential feeder. Records are deleted as items complete; a stale queue GCs after 24h.
//
// Every call is wrapped: if IndexedDB is unavailable (Safari private mode, quota, a blocked DB) the
// store goes "broken" and every method no-ops, degrading to today's memory-only behaviour (a reload
// still loses the in-flight upload, but nothing crashes).

const DB_NAME = "eden-send-queue";
const STORE = "items";
const GC_MS = 24 * 60 * 60 * 1000; // records older than 24h are abandoned

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
        os.createIndex("by_user", "userId", { unique: false });
        os.createIndex("by_queue", "queueId", { unique: false });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error("blocked"));
  });
}

function runTx(db, mode, fn) {
  return new Promise((resolve, reject) => {
    let out;
    let tx;
    try {
      tx = db.transaction(STORE, mode);
    } catch (e) {
      reject(e);
      return;
    }
    const os = tx.objectStore(STORE);
    try {
      out = fn(os);
    } catch (e) {
      reject(e);
      return;
    }
    tx.oncomplete = () => resolve(out);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
  });
}

function reqValue(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export const SendStore = {
  _db: null,
  _broken: false,
  _warned: false,

  _fail(where, e) {
    this._broken = true;
    if (!this._warned) {
      this._warned = true;
      console.warn(`[send-store] disabled (${where}); uploads won't survive reload:`, e && e.message);
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

  // Best-effort: ask the browser not to evict our storage (Safari/Firefox honour it after a user
  // gesture). Never blocks or throws.
  async requestPersist() {
    try {
      if (navigator.storage && navigator.storage.persist) await navigator.storage.persist();
    } catch (_e) {
      /* ignore */
    }
  },

  // Persist one item (id = `${queueId}:${order}`). `item.file` is a real File — IndexedDB
  // structured-clones it (name/type/lastModified survive).
  async put(item) {
    const db = await this.db();
    if (!db) return;
    try {
      await runTx(db, "readwrite", (os) => os.put(item));
    } catch (e) {
      this._fail("put", e);
    }
  },

  async patch(id, changes) {
    const db = await this.db();
    if (!db) return;
    try {
      await runTx(db, "readwrite", async (os) => {
        const cur = await reqValue(os.get(id));
        if (cur) os.put({ ...cur, ...changes });
      });
    } catch (e) {
      this._fail("patch", e);
    }
  },

  async remove(id) {
    const db = await this.db();
    if (!db) return;
    try {
      await runTx(db, "readwrite", (os) => os.delete(id));
    } catch (e) {
      this._fail("remove", e);
    }
  },

  async removeQueue(queueId) {
    const db = await this.db();
    if (!db) return;
    try {
      await runTx(db, "readwrite", async (os) => {
        const keys = await reqValue(os.index("by_queue").getAllKeys(queueId));
        (keys || []).forEach((k) => os.delete(k));
      });
    } catch (e) {
      this._fail("removeQueue", e);
    }
  },

  // Every not-yet-sent item for this user, oldest first, GCing anything stale (>24h) on the way.
  // Returns [] on any failure so callers can treat "no durable queue" and "store broken" alike.
  async listUnfinished(userId) {
    const db = await this.db();
    if (!db) return [];
    try {
      const all = await runTx(db, "readwrite", async (os) => {
        const rows = (await reqValue(os.index("by_user").getAll(userId))) || [];
        const cutoff = Date.now() - GC_MS;
        const live = [];
        for (const r of rows) {
          if (!r.createdAt || r.createdAt < cutoff) os.delete(r.id);
          else if (r.status !== "sent") live.push(r);
        }
        return live;
      });
      all.sort((a, b) => a.createdAt - b.createdAt || a.order - b.order);
      return all;
    } catch (e) {
      this._fail("listUnfinished", e);
      return [];
    }
  },
};
