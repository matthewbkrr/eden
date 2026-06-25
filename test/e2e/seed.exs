# Idempotent seed for the Playwright E2E audit (run: `mix run test/e2e/seed.exs`).
#
# Creates three throwaway users (alice/bob/carol) with a known password and a small
# spread of conversations — a 1:1 DM, a group, and a channel with a second room — so the
# multi-user, multi-device flows have deterministic data to drive. Writes the ids + creds
# to test/e2e/.seed.json (gitignored) for the Playwright fixtures to read.
#
# Safe to re-run: users are found-or-created, the 1:1 reuses, the group/channel are
# matched by title/name before creating.
import Ecto.Query
alias Eden.Accounts.Scope
alias Eden.Accounts.User
alias Eden.Channels
alias Eden.Channels.Channel
alias Eden.Chat
alias Eden.Chat.Conversation
alias Eden.Repo

password = "e2e-pass-1234"

ensure_user = fn username, display ->
  case Repo.get_by(User, username: username) do
    nil ->
      {:ok, u} =
        %User{}
        |> User.registration_changeset(
          %{username: username, display_name: display, password: password},
          hash_password: true
        )
        |> Repo.insert()

      u

    u ->
      u
  end
end

alice = ensure_user.("e2e_alice", "Alice (E2E)")
bob = ensure_user.("e2e_bob", "Bob (E2E)")
carol = ensure_user.("e2e_carol", "Carol (E2E)")

as = Scope.for_user(alice)

# 1:1 DM (find_or_create_direct → idempotent).
{:ok, dm} = Chat.create_conversation(as, [bob.id])

# A seed photo in the DM so the per-dialog media gallery (#136) always has content.
# Idempotent: only added when the DM has no image attachment yet.
has_dm_photo? =
  Repo.exists?(
    from(a in Eden.Chat.Attachment,
      join: m in Eden.Chat.Message,
      on: m.id == a.message_id,
      where: m.conversation_id == ^dm.id and a.kind == "image"
    )
  )

unless has_dm_photo? do
  {:ok, img} = Image.new(800, 600, color: [70, 110, 200])
  {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
  png = Path.join(System.tmp_dir!(), "e2e-seed-photo.png")
  File.write!(png, bytes)
  {:ok, _} = Chat.create_attachments(as, dm.id, [%{path: png, filename: "seed-photo.png"}])
  File.rm(png)
end

# Group (alice + bob + carol) — match by title before creating so re-runs don't pile up.
group =
  case Repo.one(from(c in Conversation, where: c.is_group and c.title == "E2E Group", limit: 1)) do
    nil ->
      {:ok, g} = Chat.create_conversation(as, [bob.id, carol.id], group: true, title: "E2E Group")
      g

    g ->
      g
  end

# Channel (alice = owner; born with a general room) + a second room.
{channel_id, room_id} =
  case Repo.get_by(Channel, name: "E2E Channel", creator_id: alice.id) do
    nil ->
      case Channels.create_channel(as, %{name: "E2E Channel"}) do
        {:ok, ch} ->
          rid =
            case Channels.create_room(Scope.for_user(alice), ch.id, %{name: "dev"}) do
              {:ok, room} -> room.id
              other -> IO.puts("create_room failed: #{inspect(other)}") && nil
            end

          {ch.id, rid}

        other ->
          IO.puts("create_channel failed: #{inspect(other)}")
          {nil, nil}
      end

    ch ->
      rid =
        Repo.one(
          from(c in Conversation,
            where: c.channel_id == ^ch.id and not is_nil(c.title) and c.title == "dev",
            limit: 1
          )
        )

      {ch.id, rid && rid.id}
  end

# The general room (auto-joined by every channel member) — for multi-user room flows.
general_room_id =
  channel_id &&
    Repo.one(
      from(c in Conversation, where: c.channel_id == ^channel_id and c.is_general, limit: 1)
    ).id

out = %{
  base_url: "http://localhost:4001",
  password: password,
  general_room_id: general_room_id,
  users: %{
    alice: %{username: alice.username, id: alice.id, display_name: alice.display_name},
    bob: %{username: bob.username, id: bob.id, display_name: bob.display_name},
    carol: %{username: carol.username, id: carol.id, display_name: carol.display_name}
  },
  dm_id: dm.id,
  group_id: group.id,
  channel_id: channel_id,
  room_id: room_id
}

path = Path.join([File.cwd!(), "test", "e2e", ".seed.json"])
File.mkdir_p!(Path.dirname(path))
File.write!(path, Jason.encode!(out, pretty: true) <> "\n")
IO.puts("✓ seed written to #{path}")
IO.puts(inspect(out, pretty: true))
