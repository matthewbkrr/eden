defmodule Eden.NotificationsTargetsTest do
  # The push half of the seam (#418): device registry + payload rendering.
  # Transport HTTP shapes live in notifications/{apns,fcm}_test.exs; the
  # DB-free delivery fan-out stays in notifications_test.exs.
  use Eden.DataCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Notifications
  alias Eden.Notifications.Target

  defp scope(user), do: Scope.for_user(user)

  describe "upsert_target/3" do
    setup do
      %{user: user_fixture()}
    end

    test "registers a device", %{user: user} do
      assert {:ok, %Target{} = t} = Notifications.upsert_target(scope(user), "fcm", "tok-1234567")
      assert t.user_id == user.id
      assert t.enabled
      assert t.last_seen_at
    end

    test "re-registering is an upsert: same row, touched and re-enabled", %{user: user} do
      {:ok, first} = Notifications.upsert_target(scope(user), "apns", "a1b2c3d4e5")
      Repo.update_all(Target, set: [enabled: false])

      {:ok, again} = Notifications.upsert_target(scope(user), "apns", "a1b2c3d4e5")
      assert again.id == first.id
      assert again.enabled
      assert Repo.aggregate(Target, :count) == 1
    end

    test "the same token may be registered by two users (device handover)", %{user: user} do
      other = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "fcm", "shared-token-1")
      {:ok, _} = Notifications.upsert_target(scope(other), "fcm", "shared-token-1")
      assert Repo.aggregate(Target, :count) == 2
    end

    test "rejects an unknown kind and junk tokens", %{user: user} do
      assert {:error, %Ecto.Changeset{}} =
               Notifications.upsert_target(scope(user), "carrier-pigeon", "tok-1234567")

      assert {:error, %Ecto.Changeset{}} = Notifications.upsert_target(scope(user), "fcm", "x")
      assert Repo.aggregate(Target, :count) == 0
    end
  end

  describe "prune_target/2 · delete_user_targets/1 · targets_for/2" do
    test "prune drops the token for its kind only" do
      user = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "fcm", "dead-token-1")
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "dead-token-1")

      :ok = Notifications.prune_target("fcm", "dead-token-1")

      assert [%Target{kind: "apns"}] = Repo.all(Target)
    end

    test "delete_user_targets removes every device of one user" do
      user = user_fixture()
      other = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "fcm", "tok-aaaaaaa")
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "tok-bbbbbbb")
      {:ok, _} = Notifications.upsert_target(scope(other), "fcm", "tok-ccccccc")

      :ok = Notifications.delete_user_targets(user.id)

      assert [%Target{user_id: uid}] = Repo.all(Target)
      assert uid == other.id
    end

    test "targets_for returns only the user's enabled devices of that kind" do
      user = user_fixture()
      {:ok, t1} = Notifications.upsert_target(scope(user), "fcm", "tok-enabled-1")
      {:ok, t2} = Notifications.upsert_target(scope(user), "fcm", "tok-disabled")
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "tok-otherkind")
      Repo.update_all(from(t in Target, where: t.id == ^t2.id), set: [enabled: false])

      assert [%Target{id: id}] = Notifications.targets_for(user.id, "fcm")
      assert id == t1.id
    end
  end

  describe "render_push/1" do
    # The locale-neutral payload contract from the Eden.Notifications moduledoc.
    defp payload(overrides) do
      Map.merge(
        %{
          conversation_id: 42,
          message_id: 7,
          root_id: nil,
          channel_id: nil,
          kind: "dm",
          conv_title: nil,
          sender_id: 1,
          sender_name: "Алиса",
          avatar_key: nil,
          preview: "привет!",
          media_kind: nil
        },
        overrides
      )
    end

    test "a DM titles with the sender" do
      assert %{title: "Алиса", body: "привет!"} = Notifications.render_push(payload(%{}))
    end

    test "group and room lead with sender — conversation" do
      assert %{title: "Алиса — Экспедиция"} =
               Notifications.render_push(payload(%{kind: "group", conv_title: "Экспедиция"}))

      assert %{title: "Алиса — general"} =
               Notifications.render_push(
                 payload(%{kind: "room", conv_title: "general", channel_id: 3})
               )
    end

    test "a knock names the room and words the request" do
      rendered =
        Notifications.render_push(
          payload(%{kind: "knock", conv_title: "backend", channel_id: 3, preview: ""})
        )

      assert rendered.title == "backend"
      assert rendered.body == "Алиса просится в комнату"
    end

    test "media leads with its marker; captions ride after it (#363/R202)" do
      assert %{body: "📷 Фото"} =
               Notifications.render_push(payload(%{media_kind: "image", preview: ""}))

      assert %{body: "🎥 Видео · закат"} =
               Notifications.render_push(payload(%{media_kind: "video", preview: "закат"}))

      assert %{body: "📄 Файл · отчёт"} =
               Notifications.render_push(payload(%{media_kind: "file", preview: "отчёт"}))
    end

    test "the body trims like the web banner" do
      long = String.duplicate("а", 200)
      %{body: body} = Notifications.render_push(payload(%{preview: long}))
      assert String.length(body) == 140
      assert String.ends_with?(body, "…")
    end

    test "data is string-keyed strings; channel_id only when present (FCM contract)" do
      %{data: dm_data} = Notifications.render_push(payload(%{}))
      assert dm_data == %{"conversation_id" => "42", "message_id" => "7"}

      %{data: room_data} = Notifications.render_push(payload(%{kind: "room", channel_id: 3}))
      assert room_data["channel_id"] == "3"
    end

    test "accepts string-keyed payloads (Oban args arrive as JSON)" do
      string_keyed = payload(%{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
      assert %{title: "Алиса", body: "привет!"} = Notifications.render_push(string_keyed)
    end
  end
end
