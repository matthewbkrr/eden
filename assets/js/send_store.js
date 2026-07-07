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

// Run a read/write transaction whose follow-up requests are issued from the FIRST request's
// onsuccess — never across an `await` (WebKit auto-commits an IndexedDB transaction across await
// points, which would throw on the follow-up put/delete and mark the store broken). Resolves with
// whatever `collect` builds, on tx.oncomplete.
function runReadWrite(db, build) {
  return new Promise((resolve, reject) => {
    let tx;
    try {
      tx = db.transaction(STORE, "readwrite");
    } catch (e) {
      reject(e);
      return;
    }
    const os = tx.objectStore(STORE);
    let result;
    try {
      result = build(os);
    } catch (e) {
      reject(e);
      return;
    }
    tx.oncomplete = () => resolve(result && result.value);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
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

  async remove(id) {
    const db = await this.db();
    if (!db) return;
    try {
      await runTx(db, "readwrite", (os) => os.delete(id));
    } catch (e) {
      this._fail("remove", e);
    }
  },

  // Delete every record of a queue. The deletes are issued from getAllKeys's onsuccess (same tx, no
  // await between) so WebKit can't auto-commit before them.
  async removeQueue(queueId) {
    const db = await this.db();
    if (!db) return;
    try {
      await runReadWrite(db, (os) => {
        os.index("by_queue").getAllKeys(queueId).onsuccess = (e) =>
          (e.target.result || []).forEach((k) => os.delete(k));
      });
    } catch (e) {
      this._fail("removeQueue", e);
    }
  },

  // Every not-yet-sent item for this user, oldest first, GCing anything stale (>24h) on the way.
  // The scan + deletes run inside getAll's onsuccess (same tx, no await mid-transaction), and the
  // result is collected + sorted on tx.oncomplete. Returns [] on any failure so callers treat "no
  // durable queue" and "store broken" alike.
  async listUnfinished(userId) {
    const db = await this.db();
    if (!db) return [];
    try {
      const live = await runReadWrite(db, (os) => {
        const box = { value: [] };
        os.index("by_user").getAll(userId).onsuccess = (e) => {
          const rows = e.target.result || [];
          const cutoff = Date.now() - GC_MS;
          for (const r of rows) {
            if (!r.createdAt || r.createdAt < cutoff) os.delete(r.id);
            else if (r.status !== "sent") box.value.push(r);
          }
        };
        return box;
      });
      (live || []).sort((a, b) => a.createdAt - b.createdAt || a.order - b.order);
      return live || [];
    } catch (e) {
      this._fail("listUnfinished", e);
      return [];
    }
  },
};
