# ihichat mobile — Capacitor-оболочка (iOS + Android)

Нативная обёртка над LiveView-приложением (эпик #415, каркас #416). Фронтенд НЕ
бандлится: WebView грузит живой сервер (`server.url`), `www/` держит только
офлайн-заглушку. Поведение WebView (#417), пуш (#418/#419) и медиа/иконки (#420)
уже на месте.

## Предусловия на Mac

| Что | Зачем | Как |
|---|---|---|
| Node 20+ | Capacitor CLI | уже есть |
| **Xcode** (полный, не CommandLineTools) | сборка + iOS Simulator | App Store → Xcode, затем `sudo xcode-select -s /Applications/Xcode.app` и `xcodebuild -runFirstLaunch` |
| iOS Simulator runtime | симулятор iPhone | Xcode → Settings → Components |
| **Android Studio** | сборка + Android Emulator | brew install --cask android-studio; SDK/JDK ставит сама |
| Эмулятор-образ **с Google Play** | FCM-пуш в #419 | Device Manager → образ «Google Play» (не «Google APIs») |

CocoaPods **не нужен** — Capacitor 8 ходит через Swift Package Manager
(`ios/App/CapApp-SPM`).

## Профили сервера (CAP_SERVER)

Выбирается на этапе `cap sync` (см. `capacitor.config.ts`):

| Профиль | URL | Когда |
|---|---|---|
| `prod` (дефолт) | `https://chat.ihi.ru` | по умолчанию, строго HTTPS |
| `ios-dev` | `http://localhost:4001` | iOS Simulator → loopback хоста напрямую |
| `android-dev` | `http://10.0.2.2:4001` | Android Emulator → алиас loopback хоста |

Дев-сервер: `PORT=4001 mix phx.server` из корня репо. Биндинг `127.0.0.1`
(`config/dev.exs`) менять не нужно — `10.0.2.2` эмулятора приводит именно туда.
`check_origin` тоже не трогаем: в dev он выключен, а прод-WebView грузит сам
`chat.ihi.ru`.

Cleartext-HTTP разрешён ТОЛЬКО в дев-профилях и только точечно: Android —
`network_security_config.xml` в **debug source set** (один домен `10.0.2.2`;
release-сборка не несёт исключения вовсе — дефолт платформы, cleartext
запрещён), iOS — `NSAllowsLocalNetworking` (loopback/.local; удалённый HTTP
остаётся запрещён).

## Команды

```bash
npm install                # один раз после clone
npm run sync               # prod-профиль в обе платформы
npm run sync:ios-dev       # дев-профиль → ios
npm run sync:android-dev   # дев-профиль → android
npm run open:ios           # Xcode  → ▶ на симуляторе
npm run open:android       # Android Studio → ▶ на эмуляторе
npm run run:ios-dev        # собрать и запустить на симуляторе (дев)
npm run run:android-dev    # собрать и запустить на эмуляторе (дев)
```

После смены `CAP_SERVER` обязателен повторный `sync` — URL зашивается в нативный
проект. Синк-артефакты (`assets/public/`, `capacitor.config.json` в платформах)
в git не попадают — после clone первый `npm run sync` обязателен.

## Пуш (#419)

Клиентская половина: разрешение → `register()` → токен уходит в
`POST /devices` по cookie-сессии (только на авторизованной странице — маркер
`#notifier`); тап по уведомлению открывает чат из `data`
(`channel_id` есть → комната, иначе `/app/c/:id`). Форграунд-пуши без
OS-баннера (`presentationOptions: []`) — в открытом приложении баннерит
внутренний Web-адаптер.

**Android (FCM), полный цикл бесплатно:**
1. [console.firebase.google.com](https://console.firebase.google.com) → новый
   проект (только ради FCM-транспорта — никакого «Firebase на всё», ADR-0001).
2. Добавить Android-приложение с package `ru.ihi.chat` → скачать
   `google-services.json` → положить в `android/app/` (gradle подхватит сам —
   условный apply уже в шаблоне; файл не секрет, но в git не кладём).
3. Project Settings → Service accounts → Generate new private key (JSON) →
   `base64 -i key.json | tr -d '\n'` → env `EDEN_FCM_SERVICE_ACCOUNT_JSON` для
   сервера (dev: `EDEN_FCM_SERVICE_ACCOUNT_JSON=... PORT=4001 mix phx.server`).
4. Пересобрать приложение; токен появится в `notification_targets`.

**iOS (APNs):** нужен платный Apple Developer Program — у бесплатной команды
нет capability Push Notifications. После покупки: Xcode → Signing &
Capabilities → «+ Capability» → Push Notifications; Keys → выпустить .p8 →
`EDEN_APNS_*` env (для dev-сборки `EDEN_APNS_ENV=sandbox`). До тех пор
доставка на симулятор имитируется:

```bash
xcrun simctl push booted ru.ihi.chat test-push.apns   # подставь conversation_id
```

## Иконка и сплэш (#420)

Источники в `assets/` (кобальт/чёрный бренд-фон + белая метка ihichat, взятая из
`priv/static/images/apple-touch-icon.png`):

- `icon-only.png` (1024×1024) — иконка приложения,
- `splash.png` / `splash-dark.png` (2732×2732) — сплэш (светлая/тёмная).

Пересобрать все размеры под обе платформы:

```bash
npx @capacitor/assets generate --ios --android
```

Медиа: фото из галереи прикрепляется через нативный WebView-`<input type=file>`
(меню «Photo Library / Take Photo / Choose Files») — доходит до LiveView-загрузки
без плагина камеры. На iOS для этого заведены `NSPhotoLibraryUsageDescription` +
`NSCameraUsageDescription` (Info.plist). Основной поток заблокирован в portrait.

## Грабли

- `typescript` запинен на `^5` в devDependencies: TS-загрузчик конфига в
  Capacitor CLI 8 падает на typescript@6 (`Cannot read properties of undefined
  (reading 'CommonJS')`).
- Неизвестный `CAP_SERVER` роняет sync с внятной ошибкой — опечатка в профиле не
  уедет тихо в прод-URL.
