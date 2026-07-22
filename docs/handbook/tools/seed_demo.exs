# Демо-сид для скриншотов handbook-документации (запуск из корня репозитория:
#   mix run docs/handbook/tools/seed_demo.exs
# Требуется дев-сервер/дев-БД. Результат: .demo.json рядом с docs/handbook/).
# Идемпотентный: пользователи find-or-create, диалоги/группа/канал матчатся по названию.
import Ecto.Query

alias Eden.Accounts
alias Eden.Accounts.Scope
alias Eden.Accounts.User
alias Eden.Channels
alias Eden.Channels.Channel
alias Eden.Chat
alias Eden.Chat.Conversation
alias Eden.Chat.Message
alias Eden.Repo

password = "demo-pass-1234"

ensure_user = fn username, display, bio ->
  user =
    case Repo.get_by(User, username: username) do
      nil ->
        {:ok, u} =
          %User{}
          |> User.registration_changeset(
            %{
              username: username,
              display_name: display,
              password: password,
              password_confirmation: password
            },
            hash_password: true
          )
          |> Repo.insert()

        u

      u ->
        u
    end

  if bio && user.bio != bio do
    {:ok, user} = Accounts.update_profile(user, %{bio: bio})
    user
  else
    user
  end
end

anna = ensure_user.("anna", "Анна Смирнова", "Менеджер проектов")
boris = ensure_user.("boris", "Борис Ковалёв", "Дизайнер")
maria = ensure_user.("maria", "Мария Петрова", "Маркетолог")
dmitry = ensure_user.("dmitry", "Дмитрий Соколов", "Руководитель отдела")
irina = ensure_user.("irina", "Ирина Орлова", "Администратор ihichat")

# Ирина — super_admin (для скриншотов админ-панели).
if irina.role != "super_admin" do
  Repo.update!(Ecto.Changeset.change(irina, role: "super_admin"))
end

# Аватары: спокойные градиенты (если у пользователя ещё нет).
avatar_colors = %{
  anna.id => {[64, 98, 187], [140, 170, 235]},
  boris.id => {[52, 120, 110], [120, 190, 175]},
  maria.id => {[150, 90, 60], [220, 170, 130]},
  dmitry.id => {[90, 70, 140], [170, 150, 220]},
  irina.id => {[120, 60, 80], [200, 140, 160]}
}

for user <- [anna, boris, maria, dmitry, irina], is_nil(user.avatar_key) do
  {c1, c2} = avatar_colors[user.id]

  img =
    try do
      base = Image.new!(512, 512, color: c1)
      Image.linear_gradient!(base, start_color: c1 ++ [255], finish_color: c2 ++ [255])
    rescue
      _ -> Image.new!(512, 512, color: c1)
    end

  {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
  path = Path.join(System.tmp_dir!(), "avatar-#{user.username}.png")
  File.write!(path, bytes)
  {:ok, _} = Accounts.set_avatar(user, path)
  File.rm(path)
end

s = fn user -> Scope.for_user(user) end

# Учёт сдвигов времени: message_id → минут назад.
backdate = :ets.new(:backdate, [:set, :public])

say = fn scope, conv_id, body, minutes_ago ->
  {:ok, m} = Chat.create_message(scope, conv_id, %{body: body})
  :ets.insert(backdate, {m.id, minutes_ago})
  m
end

photo = fn scope, conv_id, colors, caption, minutes_ago ->
  sources =
    colors
    |> Enum.with_index()
    |> Enum.map(fn {{c1, c2}, i} ->
      img =
        try do
          base = Image.new!(1200, 900, color: c1)
          Image.linear_gradient!(base, start_color: c1 ++ [255], finish_color: c2 ++ [255])
        rescue
          _ -> Image.new!(1200, 900, color: c1)
        end

      {:ok, bytes} = Image.write(img, :memory, suffix: ".jpg")
      path = Path.join(System.tmp_dir!(), "demo-photo-#{i}-#{System.unique_integer([:positive])}.jpg")
      File.write!(path, bytes)
      %{path: path, filename: "IMG_#{2040 + i}.jpg"}
    end)

  {:ok, [m | _]} = Chat.create_attachments(scope, conv_id, sources, %{body: caption})
  Enum.each(sources, fn %{path: p} -> File.rm(p) end)
  :ets.insert(backdate, {m.id, minutes_ago})
  m
end

fresh = fn conv_id ->
  not Repo.exists?(from(m in Message, where: m.conversation_id == ^conv_id))
end

# ── 1:1 Анна ↔ Борис ─────────────────────────────────────────────────────────
{:ok, dm_boris} = Chat.create_conversation(s.(anna), [boris.id])

if fresh.(dm_boris.id) do
  say.(s.(anna), dm_boris.id, "Борис, привет! Успеешь сегодня прислать обложку для презентации?", 52)
  say.(s.(boris), dm_boris.id, "Привет! Да, уже заканчиваю. Осталось поправить цвета.", 50)
  m_photo =
    photo.(
      s.(boris),
      dm_boris.id,
      [{[58, 90, 170], [150, 180, 235]}, {[40, 60, 120], [110, 140, 200]}],
      "Вот два варианта — какой ближе?",
      24
    )
  m_choice = say.(s.(anna), dm_boris.id, "Первый! Очень спокойный, как раз в стиле бренда 👍", 20)
  say.(s.(boris), dm_boris.id, "Отлично, тогда доведу первый и загружу в общую папку.", 18)
  {:ok, _} = Chat.toggle_reaction(s.(anna), m_photo.id, "❤️")
  {:ok, _} = Chat.toggle_reaction(s.(boris), m_choice.id, "👍")
end

# ── 1:1 Анна ↔ Мария (последнее сообщение от Марии → непрочитанное) ──────────
{:ok, dm_maria} = Chat.create_conversation(s.(anna), [maria.id])

if fresh.(dm_maria.id) do
  say.(s.(anna), dm_maria.id, "Мария, добрый день! Пришлёшь план публикаций на август?", 130)
  say.(s.(maria), dm_maria.id, "Добрый! Конечно, соберу к вечеру.", 125)
  say.(s.(maria), dm_maria.id, "Готово, отправила на согласование. Посмотри, пожалуйста, когда будет минутка 🙂", 41)
end

# ── Группа «Отдел маркетинга» ────────────────────────────────────────────────
group =
  case Repo.one(from(c in Conversation, where: c.is_group and c.title == "Отдел маркетинга", limit: 1)) do
    nil ->
      {:ok, g} =
        Chat.create_conversation(s.(anna), [boris.id, maria.id, dmitry.id],
          group: true,
          title: "Отдел маркетинга"
        )

      g

    g ->
      g
  end

if fresh.(group.id) do
  say.(s.(anna), group.id, "Коллеги, напоминаю: завтра в 11:00 планёрка по запуску сайта.", 95)
  say.(s.(dmitry), group.id, "Буду. Подготовьте, пожалуйста, статусы по своим задачам.", 90)
  m_group = say.(s.(maria), group.id, "Я подготовлю сводку по рекламным кампаниям.", 80)
  say.(s.(boris), group.id, "Принято! Принесу макеты главной страницы.", 33)
  {:ok, _} = Chat.toggle_reaction(s.(dmitry), m_group.id, "👍")
  {:ok, _} = Chat.toggle_reaction(s.(anna), m_group.id, "👍")
end

# ── Канал «Ихи» с комнатами ──────────────────────────────────────────────────
{channel_id, general_id, design_id} =
  case Repo.get_by(Channel, name: "Ихи", creator_id: dmitry.id) do
    nil ->
      {:ok, ch} = Channels.create_channel(s.(dmitry), %{name: "Ихи"})
      {:ok, _} = Channels.add_members(s.(dmitry), ch.id, [anna.id, boris.id, maria.id, irina.id])

      general =
        Repo.one!(from(c in Conversation, where: c.channel_id == ^ch.id and c.is_general, limit: 1))

      {:ok, design} = Channels.create_room(s.(dmitry), ch.id, %{name: "дизайн"})
      {:ok, _} = Channels.add_room_members(s.(dmitry), design.id, [anna.id, boris.id])

      {:ok, fin} = Channels.create_room(s.(dmitry), ch.id, %{name: "финансы"})
      {:ok, _} = Channels.rename_room(s.(dmitry), fin.id, %{visibility: "private"})

      {ch.id, general.id, design.id}

    ch ->
      general =
        Repo.one!(from(c in Conversation, where: c.channel_id == ^ch.id and c.is_general, limit: 1))

      design =
        Repo.one(from(c in Conversation, where: c.channel_id == ^ch.id and c.title == "дизайн", limit: 1))

      {ch.id, general.id, design && design.id}
  end

if fresh.(general_id) do
  say.(s.(dmitry), general_id, "Всем привет! Это общая комната отдела — здесь объявления и общие вопросы.", 300)
  root = say.(s.(dmitry), general_id, "В пятницу в 16:00 общая встреча по итогам месяца. Вопросы к повестке — в ответы к этому сообщению.", 180)
  say.(s.(maria), general_id, "Кстати, новый сайт уже на тестовом сервере, можно смотреть.", 60)

  {:ok, r1} = Chat.create_reply(s.(maria), root.id, %{body: "Добавьте, пожалуйста, пункт про бюджет на рекламу."})
  :ets.insert(backdate, {r1.id, 170})
  {:ok, r2} = Chat.create_reply(s.(boris), root.id, %{body: "И про обновление фирменного стиля."})
  :ets.insert(backdate, {r2.id, 150})
  {:ok, r3} = Chat.create_reply(s.(dmitry), root.id, %{body: "Принял, оба пункта в повестке."})
  :ets.insert(backdate, {r3.id, 140})
end

if design_id && fresh.(design_id) do
  say.(s.(boris), design_id, "Выложил новые макеты в общую папку, посмотрите.", 55)
  m_d = photo.(s.(boris), design_id, [{[70, 70, 90], [160, 160, 190]}], "Главная страница, финальный вариант", 54)
  say.(s.(anna), design_id, "Смотрится отлично. Отправим Дмитрию на согласование.", 36)
  {:ok, _} = Chat.toggle_reaction(s.(anna), m_d.id, "🔥")
end

# ── Папки Анны ───────────────────────────────────────────────────────────────
folders = Chat.list_folders(s.(anna))

work =
  case Enum.find(folders, &(&1.name == "Работа")) do
    nil ->
      {:ok, f} = Chat.create_folder(s.(anna), %{name: "Работа"})
      {:ok, _} = Chat.toggle_conversation_folder(s.(anna), dm_boris.id, f.id)
      {:ok, _} = Chat.toggle_conversation_folder(s.(anna), group.id, f.id)
      f

    f ->
      f
  end

# ── Инвайт для скриншота страницы регистрации ────────────────────────────────
{:ok, _invite, invite_token} = Accounts.create_invite(nil, max_uses: 10)

# ── TOTP для Ирины (админка требует 2FA) ─────────────────────────────────────
irina = Repo.get!(User, irina.id)

totp_secret =
  if User.totp_enrolled?(irina) do
    # Секрет уже сохранён в прошлый запуск — прочитаем из файла.
    case File.read(Path.expand("../.demo.json", __DIR__)) do
      {:ok, json} -> Jason.decode!(json)["totp_secret_b64"]
      _ -> nil
    end
  else
    {secret, _uri} = Accounts.setup_totp(irina)
    code = NimbleTOTP.verification_code(secret)
    {:ok, _, _backup} = Accounts.activate_totp(irina, secret, code)
    Base.encode64(secret)
  end

# ── Сдвиг времени сообщений в прошлое ────────────────────────────────────────
now = DateTime.utc_now() |> DateTime.truncate(:second)

for {id, minutes} <- :ets.tab2list(backdate) do
  ts = DateTime.add(now, -minutes * 60, :second)
  from(m in Message, where: m.id == ^id) |> Repo.update_all(set: [inserted_at: ts])
end

out = %{
  base_url: "http://localhost:4001",
  password: password,
  invite_token: invite_token,
  totp_secret_b64: totp_secret,
  users: %{
    anna: %{username: "anna", id: anna.id},
    boris: %{username: "boris", id: boris.id},
    maria: %{username: "maria", id: maria.id},
    dmitry: %{username: "dmitry", id: dmitry.id},
    irina: %{username: "irina", id: irina.id}
  },
  dm_boris_id: dm_boris.id,
  dm_maria_id: dm_maria.id,
  group_id: group.id,
  channel_id: channel_id,
  general_id: general_id,
  design_id: design_id,
  work_folder_id: work.id
}

out_path = Path.expand("../.demo.json", __DIR__)
File.write!(out_path, Jason.encode!(out, pretty: true) <> "\n")
IO.puts("✓ demo seed written to #{out_path}")
