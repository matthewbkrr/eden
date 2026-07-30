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

// Какому хендлу БД уже делали полный проход выселения. Проход по TTL нужен один раз за
// сессию: он только освобождает диск, потому что просроченную запись всё равно не отдадут
// наружу — TTL проверяется на ЧТЕНИИ (см. `peek`/`get`). Флаг привязан к хендлу, а не ко
// времени: новый хендл = новый запуск приложения (или `clearAll`), что и есть естественный
// момент для уборки.
let sweptHandle = null;

// Put a snapshot, then GC in the SAME transaction (no await between requests — WebKit auto-commits
// an IndexedDB tx across await points): drop anything past TTL, then trim the oldest survivors down
// to IDB_MAX. The cursor walks by_updated oldest-first, so the overflow to delete is at the front.
// Выселение при этом идёт НЕ после каждой записи (#509) — условие ниже. Ни один запрос в этой
// транзакции не ждёт await, иначе WebKit закоммитит её у нас под руками, как и предупреждает
// строка выше.
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
    // GC УБРАН С ГОРЯЧЕГО ПУТИ (#509). Раньше полный обход хранилища шёл после КАЖДОЙ
    // записи, а `put` вызывается дважды за навигацию — снимок покидаемого чата и
    // пришедшего. Обходить есть смысл ровно в двух случаях: записей стало больше кэпа
    // (надо выселять) или это первая запись на свежем хендле БД (разовая уборка по TTL).
    // `count()` считает записи, не читая их, — в отличие от обхода он не зависит от того,
    // сколько в них байт.
    //
    // Практика такая: за сессию человек переоткрывает один и тот же десяток чатов, то есть
    // почти каждая запись — перезапись существующего ключа, и число записей не меняется.
    // Обход теперь случается при кэшировании НОВОГО чата, а не при каждом обновлении снимка.
    const firstOnHandle = sweptHandle !== db;
    sweptHandle = db;
    const countReq = os.count();
    countReq.onsuccess = () => {
      if (!firstOnHandle && countReq.result <= IDB_MAX) return;
      sweep(os);
    };
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error("aborted"));
  });
}

// Выселение: просроченное по TTL плюс всё, что вылезло за кэп. Идёт в той же транзакции,
// что и запись, поэтому атомарность прежняя.
//
// `openKeyCursor`, НЕ `openCursor`: у курсора по индексу `key` — это уже сам `updatedAt`, а
// `primaryKey` — id, то есть всё нужное лежит в ключах. Обращение к `cur.value` заставило бы
// движок делать structured-deserialize ПОЛНОЙ записи вместе с полем `html` (до MAX_BYTES =
// 1 МБ) — на каждую из IDB_MAX записей. На Chromium и Firefox это снимает зависимость
// стоимости обхода от объёма записей полностью; WebKit (а это WKWebView, то есть iOS)
// материализует записи и на key-курсоре, поэтому там выигрыш даёт именно то, что обход
// перестал случаться на каждой записи.
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
    // Удаляем ПОСЛЕ обхода: `cur.delete()` на key-курсоре бросает InvalidStateError —
    // спека разрешает удаление только курсору со значением. Курсор идёт по возрастанию
    // `updatedAt`, поэтому лишние сверх кэпа — это начало `survivors`, самые старые.
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
    sweptHandle = null; // база удалена — следующий хендл снова заслуживает разовой уборки
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
