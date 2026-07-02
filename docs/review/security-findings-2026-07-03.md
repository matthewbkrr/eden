# eden — security findings (Phase 3)

Дата: **2026-07-03** · Метод: автоматические сканеры + четыре ручных аудитора по
зонам (authz/IDOR · XSS/инъекции · сессии/транспорт · файлы/DoS) · read-only,
код не менялся.

## Итог одной строкой

**P0: 0 · P1: 3 (все — DoS в медиа-пайплайне, только для аутентифицированного
инсайдера) · P2: 3 · P3: ~10.** Ядро — авторизация, кастомный markdown, сессии,
инвайты, ffmpeg-shell-out — **чистое и подтверждено сквозным чтением**. Весь
реальный риск сконцентрирован в одном месте: синхронная обработка медиа на
request-пути + щедрые лимиты декодирования = один инсайдер может уронить
single-VPS по памяти/CPU.

## Автоматические сканеры — всё зелёное

| Инструмент | Результат |
|---|---|
| `mix sobelow --exit` (config, gate=low) | **0 находок** (Config.CSP / Config.HTTPS — обоснованные false-positive) |
| `mix deps.audit` | **0 уязвимостей** |
| `mix hex.audit` | **0 retired-пакетов** |
| `mix credo --strict` | **0 issues** (1470 mods/funs) |
| `gitleaks detect` | **0 утечек** за 341 коммит / 5.97 MB |

Коммитнутые `secret_key_base` (dev.exs, test.exs) и `signing_salt` (endpoint.ex) —
**не находки**: dev/test-литералы, прод читает `SECRET_KEY_BASE` из env
(`runtime.exs:48`, raise при отсутствии). Signing salt — несекретный вход KDF,
стандартная практика Phoenix.

---

## P0 — блокеры

**Нет.**

---

## P1 — исправить до роста нагрузки/аудитории

Все три — один класс: **ресурсное истощение через медиа**. Эксплуатируется только
аутентифицированным пользователем (открытой регистрации нет — ADR-0002), то есть
это **инсайдерский DoS**. Но прод — единственный VPS (уже был disk-full-инцидент
2026-06-29), поэтому один crafted-загрузчик, кладущий ноду по OOM, — реальный
availability-риск.

### P1-1 · Декомпресионная бомба в рамках байтового лимита (память)
- **Где:** `lib/eden/chat.ex:75` (`@max_source_pixels 192_000_000`), guard
  `chat.ex:3765`, декод `chat.ex:3746` (`thumbnail_buffer`).
- **Атака:** PNG/WebP ≤ 8 МБ с заголовком, объявляющим ~190M пикселей, проходит
  `guard_dimensions` (192M) и декодируется целиком: 190M × 3–4 B ≈ **576–768 МБ RAM**
  на одну задачу. Очередь `:media` с concurrency 5 → до **~3 ГБ одновременно** →
  OOM-kill ноды.
- **Порядок проверки корректен** (guard читает заголовок ДО декода) — проблема в
  *величине* порога, а не в ordering.
- **Фикс:** снизить cap до ~40–64M px (thumbnail) и ~24–40M (avatar/compress),
  сделать проверку строгой (`<`). CONFIRMED.

### P1-2 · Синхронный ffprobe по видео на процессе LiveView
- **Где:** `chat.ex:2296` (`media_dimensions("video", …)` → `ffprobe_meta`),
  вызывается из `store_attachment_blob` (`chat.ex:2235`) внутри
  `create_album_message`, то есть **синхронно из `handle_event`** (см. комментарий
  #117 на `chat.ex:2291`).
- **Атака:** альбом из 10 видео = 10 последовательных ffprobe на процессе
  отправителя, каждый до 20 с (таймаут есть) → **до ~200 с блокировки** процесса +
  удержание DB-коннекта в окне транзакции. Повторяемо из нескольких сессий →
  давление на пул коннектов и планировщик.
- **Фикс:** перенести чтение размеров видео в асинхронный `:media`-воркер (он всё
  равно потом проходит по этому вложению); «pop-to-size» лечится плейсхолдером, а не
  синхронным ffprobe. CONFIRMED.

### P1-3 · Синхронный полный декод изображений на request-пути (сжатие)
- **Где:** `chat.ex:2205` → `lib/eden/images.ex:55-80` (`compress_photo`), guard
  `images.ex:58/85` (`@max_pixels` 100M).
- **Атака:** каждое не-оригинальное, не-GIF, не-HEIC изображение декодируется libvips
  **синхронно во время отправки**, до 100M px ≈ 300–400 МБ, до 10 на альбом
  последовательно на процессе LiveView → CPU+RAM-спайк на горячем пути (не в
  bounded-очереди).
- **Фикс:** та же линия, что P1-2 — сжатие/декод в `:media`-воркер; на request-пути
  оставить только магико-байтовую классификацию + запись блоба. CONFIRMED.

> Связка: P1-1/2/3 лечатся одной архитектурной правкой — **весь тяжёлый декод и
> shell-out увести с request-пути в bounded `:media`-очередь, ужать пиксельные
> лимиты.** Это и снимает OOM-вектор, и разгружает LiveView-процессы.

---

## P2 — defense-in-depth

### P2-1 · Нет rate-limit на логин (brute-force/стаффинг)
- **Где:** `lib/eden_web/controllers/user_session_controller.ex:7`, роут
  `router.ex:80`. Ни hammer/plug_attack/throttle в дереве нет.
- **Атака:** онлайн-подбор по угадываемым username (`[a-z0-9_]{3,30}`); параллельные
  коннекты нивелируют задержку bcrypt. Нет лок-аута, cap по IP, captcha, лога
  неудачных попыток.
- **Контекст:** приемлемо при ~20 инвайт-юзерах; поднять приоритет при росте/большей
  экспозиции. Заодно — тот же лимитер на `POST /invite/:token` и логин-форму.
  CONFIRMED.

### P2-2 · Нет смены пароля и «выйти на других устройствах»; токены живут 60 дней без ротации
- **Где:** `user_token.ex:15` (60 дней), `accounts.ex:171` (удаляется только
  предъявленный токен), `settings_live.ex` (пароля нет вовсе).
- **Атака:** украденный cookie даёт до 60 дней тихого доступа; жертва не может
  ни сменить пароль, ни отозвать все сессии — только ручная правка БД оператором.
- **Смягчение:** HttpOnly + nonce-CSP затрудняют кражу через XSS; логаут отзывает
  токен серверно и рвёт live-сессию.
- **Фикс:** добавить смену пароля (+ отзыв всех токенов пользователя) и, опционально,
  idle-timeout/ротацию. Синергия с ADR-0002 (reset-ссылки, TOTP админам). CONFIRMED.

### P2-3 · Read-receipt spoofing без проверки членства
- **Где:** `chat.ex:3325` (`mark_read`). `update_all` фильтрует по `user_id`
  (0 строк для не-участника — ничего не пишется), но `broadcast(conversation_id,
  {:read, user.id, read_at})` — **безусловный**. Обработчик
  (`chat_live.ex:2174`) принимает любой `reader_id != self` и двигает `other_read_at`.
- **Атака:** аутентифицированный не-участник перебирает id разговора и шлёт
  `mark_as_read` → подделывает «✓✓ прочитано» в чужой DM (кросс-conversation
  спуф). Данные не раскрываются, не персистится, видно только пока у жертвы открыт
  чат — потому P2, не P1.
- **Фикс:** гейтить broadcast на `member?/2` (или не слать при 0 обновлённых строк).
  CONFIRMED.

---

## P3 — гигиена / робастность

| # | Находка | Где |
|---|---|---|
| P3-1 | Content-Disposition: `"`/`\`/`;` в fallback-filename не экранированы (CRLF невозможен — нестандартные байты → `_`; косметика) | `file_controller.ex:162` |
| P3-2 | Инвайт-эндпоинт без rate-limit (энтропия 256 бит компенсирует; шум в логах) | `router.ex:81` |
| P3-3 | Просроченные session-токены не вычищаются из `users_tokens` (хеши, рост таблицы) | `user_token.ex:33` |
| P3-4 | Secure-cookie неявный, зависит от цепочки Caddy→RewriteOn→scheme (по дизайну #85; в проде выставляется) | `endpoint.ex:7,47` |
| P3-5 | `Plug.RewriteOn` доверяет `X-Forwarded-*` без allowlist (смягчено `expose:` в compose — порт не публикуется) | `endpoint.ex:47` |
| P3-6 | Username-enumeration через инвайт-форму («may be taken»); нужен валидный инвайт+CSRF | `invite_controller.ex:14` |
| P3-7 | Аватары юзеров отдаются по raw id без shared-conversation-check (по дизайну; профиль-bio гейтится `get_shared_user`) | `avatar_controller.ex:13` |
| P3-8 | Предсказуемые имена temp-файлов (`media-src-<unique_integer>` в `/tmp`; риск только при локальном доступе к хосту) | `chat.ex:3981` |
| P3-9 | Temp постер-кадра не в `try/after` — утечёт при raise (bounded) | `chat.ex:4062` |
| P3-10 | Bomb-guard `<=` включает границу (10000×10000 = 100M проходит) | `images.ex:85` |
| P3-11 | Caddy HSTS без `preload` | `deploy/Caddyfile:19` |

---

## Проверено ЧИСТЫМ (покрытие)

**Авторизация / IDOR** — сквозная дисциплина `%Scope{}` + membership-join
подтверждена:
- `file_controller` отдаёт вложения только через `Chat.fetch_attachment(scope,…)`
  с `join Membership` — перебор sequential-id бесполезен.
- Все мутирующие `handle_event` (delete/edit/react/forward/reply, group/channel CRUD,
  роли, инвайты, папки) прокидывают scope; контекст переспрашивает членство/роль
  (`ensure_sender`, `ensure_role`, `ensure_removable`-матрица, self-guard).
- Существование не течёт: не-член → `:not_found`, `:forbidden` только
  подтверждённому члену без роли.
- Кросс-conversation инъекция (`reply_to_id`/`root_id`/forward-target/permalink)
  валидируется (`valid_reply_to_id/3`, `fetch_message(scope)`, permalink грузит
  разговор через `get_conversation(scope,…)`).
- `get_shared_user/2` отдаёт профиль только при общем разговоре.
- Сессионный токен: 32 байта, SHA-256 at rest, `live_socket_id` per-token —
  кросс-юзер переиспользование невозможно.

**XSS / инъекции:**
- `EdenWeb.Markup` (94 строки, прочитан целиком) — **нет пути инъекции**: весь
  пользовательский текст через `Phoenix.HTML.html_escape`, эмитятся только литеральные
  теги из whitelist; `javascript:`/`data:`-схемы недостижимы (линкуется только
  `https?://`); breakout из `href` невозможен (кавычки экранированы). Проверены
  payload'ы `<script>`, `<img onerror>`, `` `</code>``, `http://x"onmouseover=` — все
  инертны.
- SQLi: поиск на Ecto-биндингах (`ilike(^pattern)`, `fragment("? <% ?", ^term, …)`);
  `escape_like/1` корректно экранирует `\ % _`; единственный `Repo.query!`
  забинжен на compile-time-константу. Interpolation user-input в SQL — нет.
- Path traversal: ключи хранилища — `build_key` (random base64url + санитайзенный
  `[a-z0-9]` ext); `Local.path/1` дополнительно отвергает `.`/`..`/`/`-сегменты.
- SSRF: сервер **не фетчит** ни один user-URL (нет превью ссылок / avatar-by-url);
  единственный Req — S3 на env-endpoint с opaque-ключом.
- CSP: `script-src 'self' 'nonce-…'` без `unsafe-inline` для скриптов (реальный
  XSS-барьер); `style-src unsafe-inline` — задокументированное исключение.
- Полная ревизия `raw(`/`{:safe,` в дереве: 3 места, все безопасны (markup,
  search-highlighter через `html_escape`, error_html только с литералами + locale ∈
  `~w(en ru)`).

**Сессии / транспорт:**
- Session-fixation закрыт (`renew_session` до `put_token_in_session`).
- Логаут = серверный отзыв токена + force-disconnect live-сессии; CSRF на всех
  нативных POST (`protect_from_forgery`) + на LiveView-сокете (`check_csrf`);
  `check_origin` в проде дефолт-true против `PHX_HOST` (raise при отсутствии).
- Логин timing-safe (`Bcrypt.no_user_verify`), generic-ошибка; пароль min 8 / max 72
  байта, bcrypt cost 12.
- Инвайты: 32 байта, SHA-256 at rest, погашение атомарно (`Repo.transact` +
  `FOR UPDATE`) — **без TOCTOU**; гонка на последнем использовании упирается в лок и
  видит `:exhausted`.
- `/healthz` до роутера, статический `"ok"`, без DB/версии. Прод: `debug_errors`
  off, статические error-страницы без request-данных, LiveDashboard/dev-routes
  скомпилированы вне прода.

**Файлы / медиа:**
- ffmpeg/ffprobe/heif-convert — **args-list, без shell**, фиксированный бинарь
  (`find_executable`), input — абсолютный app-путь (argument-injection через `-`
  невозможен); таймаут 20 с + brutal_kill.
- Байтовые cap'ы проверяются серверно по реальным байтам после магико-байтовой
  классификации (ложь про content-type не помогает); альбом ≤ 10 enforced.
- zip/pdf/generic — хранятся as-is, ноль серверного парсинга, отдаются
  `nosniff` + `attachment`.
- temp-файлы основных путей чистятся через `try/after`; аватары bomb-guarded так же.

---

## Рекомендованный порядок исправлений

1. **P1-1/2/3 одной правкой:** увести тяжёлый декод/ffprobe/сжатие с request-пути в
   `:media`-воркер + ужать пиксельные лимиты. Снимает единственный реальный
   (OOM/CPU) вектор на single-VPS.
2. **P2-2** смена пароля + отзыв всех сессий — совпадает с ADR-0002 (reset-ссылки,
   TOTP админам): делать в одном заходе.
3. **P2-3** гейт broadcast в `mark_read` (одна строка).
4. **P2-1** rate-limit на логин/инвайт (`plug_attack`/hammer) — до расширения
   аудитории.
5. **P3** — по касанию: экранирование filename, прунинг токенов, `try/after` на
   постере, строгий `<` в guard, HSTS preload.

---

## Методика

Сканеры на текущей ветке. Четыре независимых ручных аудитора (Explore,
read-only) с общим требованием: file:line-доказательство + пометка
CONFIRMED (сквозное чтение) / SUSPECTED на каждую находку. Ключевые P1/P2
перепроверены оркестратором по живому коду (`mark_read`, `media_dimensions`,
`guard_dimensions`). Ни строки кода не изменено. Классификация P0–P3 по рубрике
`CLAUDE.md`. Связанные документы:
`docs/review/architecture-review-2026-07-03.html`, `docs/adr/0002-auth-model.md`.
