// GC-курсор кэша сообщений (#509, часть эпика #506).
//
// `MsgCache.put` после каждой записи прогоняет GC по индексу `by_updated`. Курсор был
// открыт как `openCursor()`, а обращение к `cur.value` — обязательная structured-deserialize
// ПОЛНОЙ записи, включая `html` (до 1 МБ). Хранилище держит 25 записей, `put` вызывается
// дважды за навигацию (снимок покидаемого чата и пришедшего) — то есть до 50
// десериализаций и десятки МБ транзитных аллокаций на каждое переключение чата, при том
// что значение не нужно: `updatedAt` — это и есть ключ индекса.
//
// Оракул здесь САМОКАЛИБРУЮЩИЙСЯ: сравнивается время записи при «толстом» и «тонком»
// хранилище с ОДИНАКОВЫМ числом записей. Под багом толстое хранилище кратно медленнее,
// после правки разницы почти нет. Абсолютные миллисекунды зависели бы от машины и
// троттлинга, а отношение — нет.
const { test, expect } = require("@playwright/test");

const IDB_MAX = 25; // = константа в msg_cache.js
const FAT_BYTES = 300 * 1024; // реальная лента ~0.5 МБ (комментарий в модуле); лимит записи 1 МБ
// Меряем ПАКЕТОМ, а не поштучно: Firefox и WebKit огрубляют performance.now() до
// миллисекунды (privacy.reduceTimerPrecision и аналог), поэтому запись в 0.3 мс там
// округляется в 0.00 и отношение выходит NaN. Пакет из BATCH записей набирает десятки
// миллисекунд, и кламп перестаёт значить что-либо.
const BATCH = 40;
// Берём МИНИМУМ пакетов, а не медиану: шум умеет только добавлять время, поэтому минимум —
// это оценка «чистой» стоимости, и порог по отношению становится устойчивее (ревью PR #527
// справедливо указало, что ассерт по стенным часам хрупок). Спека гоняется вручную, не в CI.
const BATCHES = 3;

// Кириллица — 2 байта в UTF-8, а модуль считает бюджет записи через Blob, то есть по
// честным байтам; наполнитель поэтому строится из неё, а не из латиницы.
// Измеряемая запись ВСЕГДА крошечная, меняется только объём уже лежащих записей. Иначе
// оракул смешивает два эффекта: обход GC и стоимость самой записи, которая законно растёт
// с размером строки (первая версия так и мерила и после правки показывала 2× вместо 1×).
// forceSweep=false — горячий путь: перезапись существующего ключа, число записей стабильно
// (ровно кэп), обход не нужен. forceSweep=true — каждая запись берёт НОВЫЙ ключ, поэтому
// число записей выходит за кэп и обход случается принудительно; так меряется стоимость
// самого обхода, когда он всё же идёт.
async function perPutMs(page, { fillerBytes, forceSweep = false }) {
  return page.evaluate(
    async ({ fillerBytes, stored, batch, batches, forceSweep }) => {
      const cache = window.__edMsgCache;
      const filler = "п".repeat(Math.floor(fillerBytes / 2));
      const user = 7;

      await cache.clearAll();
      if (forceSweep) {
        // Наполнители сажаем НАПРЯМУЮ и с метками в будущем. Иначе замер вырождается: обход
        // выселяет самую старую запись, а самые старые — это как раз наполнители, и через
        // пару десятков записей «толстый» стор становится тонким (первая версия этого теста
        // так и показывала 0.9× на всех движках). С будущей меткой наполнители всегда
        // свежайшие, выселяются крошечные, и стор остаётся толстым весь замер.
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

// Прямой доступ к хранилищу — проверяем ФАКТ выселения, а не то, что вернул модуль.
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

test.describe("кэш сообщений: GC при записи", () => {
  test.beforeEach(async ({ page }) => {
    // Логин-страница несёт тот же бандл и выставляет window.__edMsgCache — авторизация,
    // сиды и троттлинг-раннер для этого замера не нужны, стенд получается детерминированным.
    await page.goto("/login");
    await page.waitForFunction(() => !!window.__edMsgCache);
  });

  test("стоимость записи не зависит от объёма хранилища", async ({ page }, testInfo) => {
    const thin = await perPutMs(page, { fillerBytes: 512 });
    const fat = await perPutMs(page, { fillerBytes: FAT_BYTES });
    const ratio = fat / thin;

    const line =
      `крошечная запись при ${IDB_MAX} записях в сторе: тонкий стор ${thin.toFixed(2)} мс, ` +
      `толстый (${FAT_BYTES / 1024} КБ/запись) ${fat.toFixed(2)} мс, отношение ${ratio.toFixed(2)}×`;
    console.log(line);
    testInfo.annotations.push({ type: "измерение", description: line });

    // GC обязан ходить по КЛЮЧАМ. Если он читает значения, толстое хранилище кратно дороже.
    expect(ratio, `GC десериализует записи: ${line}`).toBeLessThan(2);
  });

  test("сам обход, когда он всё же идёт, не читает значения записей", async ({ page }, testInfo) => {
    // Условие выше делает обход редким, из-за чего тип курсора на горячем пути перестал быть
    // наблюдаемым: возврат `openCursor` не ронял ни один тест. Здесь обход вызывается
    // принудительно (каждая запись — новый ключ, число записей выходит за кэп), и тогда
    // чтение значений снова видно. Это важно для Android: его WebView — Chromium, где
    // key-курсор действительно не материализует запись.
    const thin = await perPutMs(page, { fillerBytes: 512, forceSweep: true });
    const fat = await perPutMs(page, { fillerBytes: FAT_BYTES, forceSweep: true });
    const ratio = fat / thin;

    const line =
      `принудительный обход: тонкий стор ${thin.toFixed(2)} мс, ` +
      `толстый ${fat.toFixed(2)} мс, отношение ${ratio.toFixed(2)}×`;
    console.log(line);
    testInfo.annotations.push({ type: "измерение", description: line });

    // WebKit материализует запись и на key-курсоре, поэтому там инвариант недостижим —
    // ради него и сделано условие выше. Проверяем на движках, где он достижим.
    const engine = testInfo.project.name;
    if (engine.includes("webkit") || engine.includes("safari")) {
      testInfo.annotations.push({
        type: "пропуск",
        description: "WebKit читает значения и на key-курсоре — инвариант проверяем на других движках",
      });
      return;
    }
    expect(ratio, `обход десериализует записи: ${line}`).toBeLessThan(2);
  });

  test("записи старше TTL выселяются разовой уборкой на свежем хендле", async ({ page }) => {
    // Уборка по TTL больше НЕ идёт на каждой записи (#509): просроченный снимок наружу всё
    // равно не отдают — TTL проверяется на чтении, — поэтому обход нужен лишь чтобы
    // освободить диск, и делается один раз на хендл БД. Свежий хендл — это новый запуск
    // приложения; здесь его роль играет clearAll, после которого put откроет базу заново.
    await page.evaluate(async () => {
      const cache = window.__edMsgCache;
      await cache.clearAll();

      // Просроченную запись кладём НАПРЯМУЮ, своим соединением: put штампует Date.now(),
      // подделать TTL через публичный API нельзя.
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
          html: "древняя",
          updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000, // TTL = 7 дней
        });
        tx.oncomplete = resolve;
      });
      db.close();

      // Первая запись на свежем хендле — она и прогоняет уборку.
      await cache.put(7, 1, "свежая");
    });

    const ids = (await storedIds(page)).map((r) => r.id).sort();
    expect(ids, "просроченный снимок остался в хранилище").toEqual(["7:1"]);
  });

  test("обычная запись НЕ прогоняет обход — иначе он снова на горячем пути", async ({ page }) => {
    // Отношение из первого теста ловит возврат обхода на каждую запись только на WebKit: на
    // Chromium key-курсор дешёвый, и тест прошёл бы. Поэтому условие проверяем ещё и
    // функционально, детерминированно и на любом движке.
    //
    // Проверяется именно ОТСУТСТВИЕ уборки, и это не поблажка мусору: просроченный снимок
    // наружу не отдают (TTL проверяется на чтении в `peek`/`get`), он лишь занимает место до
    // следующего запуска. Если же он исчезает после рядовой записи — значит обход снова
    // случается на каждой, а это тот самый дефект #509.
    await page.evaluate(async () => {
      const cache = window.__edMsgCache;
      await cache.clearAll();
      await cache.put(7, 1, "свежая"); // первая на свежем хендле — разовая уборка

      const db = await new Promise((resolve) => {
        const req = indexedDB.open("eden-msg-cache", 1);
        req.onsuccess = () => resolve(req.result);
      });
      await new Promise((resolve) => {
        const tx = db.transaction("snapshots", "readwrite");
        tx.objectStore("snapshots").put({
          id: "7:999",
          html: "древняя",
          updatedAt: Date.now() - 8 * 24 * 60 * 60 * 1000,
        });
        tx.oncomplete = resolve;
      });
      db.close();

      // Рядовая запись: хендл уже убран, число записей далеко до кэпа — обхода быть не должно.
      await cache.put(7, 2, "ещё свежая");
    });

    const ids = (await storedIds(page)).map((r) => r.id).sort();
    expect(ids, "обход прогнался на рядовой записи — он вернулся на горячий путь").toEqual([
      "7:1",
      "7:2",
      "7:999",
    ]);
  });

  test("при переполнении остаются самые свежие, а не произвольные", async ({ page }) => {
    const over = IDB_MAX + 5;
    await page.evaluate(
      async ({ over }) => {
        const cache = window.__edMsgCache;
        await cache.clearAll();
        // Разные updatedAt: put штампует Date.now(), поэтому порядок записи = порядок свежести.
        for (let i = 1; i <= over; i++) {
          await cache.put(7, i, `снимок ${i}`);
          await new Promise((r) => setTimeout(r, 2));
        }
      },
      { over },
    );

    const rows = await storedIds(page);
    expect(rows.length, "кэп хранилища не соблюдён").toBe(IDB_MAX);

    // Остаться должны последние IDB_MAX записанных.
    const kept = rows.map((r) => Number(r.id.split(":")[1])).sort((a, b) => a - b);
    const expected = Array.from({ length: IDB_MAX }, (_, i) => over - IDB_MAX + 1 + i);
    expect(kept, "выселены не самые старые").toEqual(expected);
  });
});
