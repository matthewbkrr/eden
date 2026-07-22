# Постобработка скриншотов handbook (запуск из корня репозитория, ПОСЛЕ tools/shots.js):
#   mix run --no-start docs/handbook/tools/postprocess.exs
#
# Что делает: обрезает экраны входа/приглашения/2FA до формы (убирает пустой фон)
# и админку до верхней части списка. Идемпотентность обеспечена проверкой размера —
# уже обрезанный файл пропускается.
#
# ВАЖНО: после прогона просмотрите shots/16-admin.png и shots/21-new-chat.png —
# в кадр попадают РЕАЛЬНЫЕ пользователи дев-базы (не только демо-персонажи).
# Постороннюю строку можно размыть хелпером blur ниже (пример в комментарии).

shots = Path.expand("../shots", __DIR__)

crop = fn name, x, y, w, h ->
  p = Path.join(shots, name)

  with true <- File.exists?(p),
       img = Image.open!(p),
       {iw, ih, _} <- Image.shape(img),
       # уже обрезан прошлым прогоном — не трогаем
       true <- iw > w or ih > h do
    Image.write!(Image.crop!(img, x, y, w, h), p)
    IO.puts("✓ crop #{name}")
  else
    _ -> IO.puts("· skip #{name}")
  end
end

blur = fn name, x, y, w, h ->
  p = Path.join(shots, name)
  img = Image.open!(p)
  region = Image.crop!(img, x, y, w, h)
  Image.write!(Image.compose!(img, Image.blur!(region, sigma: 20), x: x, y: y), p)
  IO.puts("✓ blur #{name}")
end

# Экраны без входа: вырезаем центральную колонку с формой (оригинал 2880×1800 @2x).
crop.("01-login.png", 960, 560, 960, 780)
crop.("02-invite.png", 960, 400, 960, 1030)
crop.("03-totp.png", 960, 580, 960, 700)

# Админка: оставляем шапку + верх списка (низ — случайные пользователи дев-базы).
crop.("16-admin.png", 0, 0, 2880, 1360)

# Примеры точечного размытия посторонних аккаунтов (координаты прогона 2026-07-22):
# blur.("16-admin.png", 470, 600, 1220, 140)     # первая строка списка участников
# blur.("21-new-chat.png", 1096, 724, 700, 104)  # первая строка пикера «Новая беседа»
_ = blur

IO.puts("done")
