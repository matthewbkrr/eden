defmodule Eden.ChannelsTest do
  use Eden.DataCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Channels
  alias Eden.Channels.{Channel, Membership}
  alias Eden.Storage

  defp scope(user), do: Scope.for_user(user)

  # Subscribe the caller to a user's in-tab notification stream (the {:notify} topic).
  defp sub(user), do: Phoenix.PubSub.subscribe(Eden.PubSub, Eden.Notifications.Web.topic(user.id))

  # The rail's entry room for a channel (#81), via the public list_channels path.
  defp entry_room(scope, channel_id) do
    scope
    |> Channels.list_channels()
    |> Enum.find(&(&1.id == channel_id))
    |> then(& &1.entry_room_id)
  end

  setup do
    %{
      alice: user_fixture(%{username: "alice", display_name: "Alice"}),
      bob: user_fixture(%{username: "bob", display_name: "Bob"})
    }
  end

  describe "create_channel/2" do
    test "creates the channel with the creator as owner", %{alice: alice} do
      assert {:ok, channel} =
               Channels.create_channel(scope(alice), %{"name" => "Engineering", "about" => "Dev"})

      assert channel.role == "owner"
      assert channel.creator_id == alice.id

      assert [%{id: id, role: "owner"}] = Channels.list_channels(scope(alice))
      assert id == channel.id
    end

    test "trims and validates the name (whitespace-only is blank, not a crash)", %{alice: alice} do
      assert {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "  Ops  "})
      assert channel.name == "Ops"

      assert {:error, %Ecto.Changeset{}} =
               Channels.create_channel(scope(alice), %{"name" => "   "})

      too_long = String.duplicate("x", Channel.max_name() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Channels.create_channel(scope(alice), %{"name" => too_long})
    end

    test "caps how many channels one user can create", %{alice: alice} do
      for n <- 1..Channels.max_channels() do
        {:ok, _} = Channels.create_channel(scope(alice), %{"name" => "C#{n}"})
      end

      assert {:error, :limit} = Channels.create_channel(scope(alice), %{"name" => "One more"})
    end

    test "broadcasts :channels_changed to the creator's sessions", %{alice: alice} do
      Channels.subscribe_user(scope(alice))
      {:ok, _} = Channels.create_channel(scope(alice), %{"name" => "Live"})
      assert_receive :channels_changed
    end
  end

  describe "list/get scoping" do
    test "only members see a channel", %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Private"})

      assert [] == Channels.list_channels(scope(bob))
      assert {:error, :not_found} = Channels.get_channel(scope(bob), channel.id)

      assert {:ok, %{role: "owner"}} = Channels.get_channel(scope(alice), channel.id)
    end

    test "get tolerates garbage ids", %{alice: alice} do
      assert {:error, :not_found} = Channels.get_channel(scope(alice), "abc")
      assert {:error, :not_found} = Channels.get_channel(scope(alice), 999_999)
    end

    test "lists in creation order", %{alice: alice} do
      {:ok, _} = Channels.create_channel(scope(alice), %{"name" => "B"})
      {:ok, _} = Channels.create_channel(scope(alice), %{"name" => "A"})

      assert ["B", "A"] == Enum.map(Channels.list_channels(scope(alice)), & &1.name)
    end
  end

  describe "update_channel/3" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      %{channel: channel}
    end

    test "owner renames and updates about", %{alice: alice, channel: channel} do
      assert {:ok, updated} =
               Channels.update_channel(scope(alice), channel.id, %{
                 "name" => "Team X",
                 "about" => "All of us"
               })

      assert updated.name == "Team X"
      assert updated.about == "All of us"
      assert updated.role == "owner"
    end

    test "admin may update; member may not", %{bob: bob, channel: channel} do
      assert {:error, :forbidden} =
               Channels.update_channel(scope(bob), channel.id, %{"name" => "Hijack"})

      promote(channel.id, bob.id, "admin")
      assert {:ok, _} = Channels.update_channel(scope(bob), channel.id, %{"name" => "Better"})
    end

    test "update validates like create (blank / too-long name)", %{alice: alice, channel: channel} do
      assert {:error, %Ecto.Changeset{}} =
               Channels.update_channel(scope(alice), channel.id, %{"name" => "   "})

      too_long = String.duplicate("x", Channel.max_name() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Channels.update_channel(scope(alice), channel.id, %{"name" => too_long})

      # The saved name is untouched.
      assert {:ok, %{name: "Team"}} = Channels.get_channel(scope(alice), channel.id)
    end

    test "non-member gets :not_found", %{channel: channel} do
      carol = user_fixture(%{username: "carol"})

      assert {:error, :not_found} =
               Channels.update_channel(scope(carol), channel.id, %{"name" => "Nope"})
    end

    test "broadcasts the rename on the channel topic", %{alice: alice, channel: channel} do
      Channels.subscribe_channel(channel.id)
      {:ok, _} = Channels.update_channel(scope(alice), channel.id, %{"name" => "Renamed"})
      assert_receive {:channel_renamed, %Channel{name: "Renamed"}}
    end
  end

  describe "channel avatar (#70)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      %{channel: channel}
    end

    test "owner sets an avatar; the key is stored and the blob readable", %{
      alice: alice,
      channel: channel
    } do
      assert {:ok, %{avatar_key: key, role: "owner"}} =
               Channels.set_channel_avatar(scope(alice), channel.id, real_png())

      assert is_binary(key)
      assert {:ok, _bytes} = Storage.read(key)
    end

    test "admin may set; a plain member may not", %{bob: bob, channel: channel} do
      assert {:error, :forbidden} =
               Channels.set_channel_avatar(scope(bob), channel.id, real_png())

      promote(channel.id, bob.id, "admin")

      assert {:ok, %{avatar_key: key}} =
               Channels.set_channel_avatar(scope(bob), channel.id, real_png())

      assert is_binary(key)
    end

    test "replacing deletes the previous blob", %{alice: alice, channel: channel} do
      {:ok, %{avatar_key: old}} =
        Channels.set_channel_avatar(scope(alice), channel.id, real_png())

      {:ok, %{avatar_key: new}} =
        Channels.set_channel_avatar(scope(alice), channel.id, real_png())

      refute old == new
      assert {:error, _} = Storage.read(old)
      assert {:ok, _} = Storage.read(new)
    end

    test "remove clears the avatar and its blob", %{alice: alice, channel: channel} do
      {:ok, %{avatar_key: key}} =
        Channels.set_channel_avatar(scope(alice), channel.id, real_png())

      assert {:ok, %{avatar_key: nil}} = Channels.remove_channel_avatar(scope(alice), channel.id)
      assert {:error, _} = Storage.read(key)
    end

    test "a non-member can't set", %{channel: channel} do
      carol = user_fixture(%{username: "carol_av"})

      assert {:error, :not_found} =
               Channels.set_channel_avatar(scope(carol), channel.id, real_png())
    end

    test "deleting the channel reclaims its avatar blob", %{alice: alice, channel: channel} do
      {:ok, %{avatar_key: key}} =
        Channels.set_channel_avatar(scope(alice), channel.id, real_png())

      :ok = Channels.delete_channel(scope(alice), channel.id)
      assert {:error, _} = Storage.read(key)
    end
  end

  describe "delete_channel/2" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Doomed"})
      {:ok, _} = insert_member(channel.id, bob.id, "admin")
      %{channel: channel}
    end

    test "owner deletes; memberships cascade", %{alice: alice, channel: channel} do
      assert :ok = Channels.delete_channel(scope(alice), channel.id)
      assert is_nil(Repo.get(Channel, channel.id))
      assert Repo.aggregate(Membership, :count) == 0
    end

    test "admin cannot delete", %{bob: bob, channel: channel} do
      assert {:error, :forbidden} = Channels.delete_channel(scope(bob), channel.id)
    end

    test "every member's rail is pinged; channel topic announces the delete", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      Channels.subscribe_user(scope(bob))
      Channels.subscribe_channel(channel.id)

      :ok = Channels.delete_channel(scope(alice), channel.id)

      assert_receive {:channel_deleted, id}
      assert id == channel.id
      assert_receive :channels_changed
    end
  end

  describe "roles" do
    test "member_role / admin? / owner?", %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Roles"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")

      assert Channels.member_role(scope(alice), channel.id) == "owner"
      assert Channels.owner?(scope(alice), channel.id)
      assert Channels.admin?(scope(alice), channel.id)

      assert Channels.member_role(scope(bob), channel.id) == "member"
      refute Channels.admin?(scope(bob), channel.id)

      promote(channel.id, bob.id, "admin")
      assert Channels.admin?(scope(bob), channel.id)
      refute Channels.owner?(scope(bob), channel.id)

      carol = user_fixture(%{username: "carolr"})
      assert is_nil(Channels.member_role(scope(carol), channel.id))
      refute Channels.admin?(scope(carol), "garbage")
    end
  end

  describe "ensure_member/2 (#41 auto-join, #375/R020)" do
    setup %{alice: alice} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Open"})
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      %{channel: channel, general: general}
    end

    test "a non-member auto-joins and materializes general", %{
      bob: bob,
      channel: channel,
      general: general
    } do
      assert {:ok, joined} = Channels.ensure_member(scope(bob), channel.id)
      assert joined.id == channel.id
      # bob is now a channel member...
      assert Channels.member_role(scope(bob), channel.id) == "member"
      # ...with general materialized — the only room a #41 auto-join lands in.
      assert Eden.Chat.room_member?(general.id, bob.id)
      assert {:ok, [%{name: "general"}]} = Channels.list_rooms(scope(bob), channel.id)
    end

    test "is idempotent — a repeat call adds no membership row", %{bob: bob, channel: channel} do
      assert {:ok, _} = Channels.ensure_member(scope(bob), channel.id)
      count = Repo.aggregate(from(m in Membership, where: m.channel_id == ^channel.id), :count)

      assert {:ok, _} = Channels.ensure_member(scope(bob), channel.id)

      assert count ==
               Repo.aggregate(from(m in Membership, where: m.channel_id == ^channel.id), :count)
    end

    test "leaks no existence — :not_found for a missing or garbage id", %{bob: bob} do
      assert {:error, :not_found} = Channels.ensure_member(scope(bob), 999_999)
      assert {:error, :not_found} = Channels.ensure_member(scope(bob), "garbage")
    end

    test "announces the join only on the FIRST (real) join", %{bob: bob, channel: channel} do
      Channels.subscribe_user(scope(bob))
      Channels.subscribe_channel(channel.id)
      cid = channel.id

      assert {:ok, _} = Channels.ensure_member(scope(bob), channel.id)
      assert_receive :channels_changed
      assert_receive {:members_changed, ^cid}

      # A repeat call is a pure no-op — no membership written, so no broadcast either.
      assert {:ok, _} = Channels.ensure_member(scope(bob), channel.id)
      refute_receive :channels_changed, 100
      refute_receive {:members_changed, _}, 50
    end
  end

  describe "transfer_ownership/3 edge cases (#375/R022)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Transfer"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      %{channel: channel}
    end

    test "refuses transferring to yourself", %{alice: alice, channel: channel} do
      assert {:error, :self} = Channels.transfer_ownership(scope(alice), channel.id, alice.id)
      assert Channels.owner?(scope(alice), channel.id)
    end

    test "refuses a non-member or garbage target", %{alice: alice, channel: channel} do
      carol = user_fixture(%{username: "carolt"})

      assert {:error, :not_found} =
               Channels.transfer_ownership(scope(alice), channel.id, carol.id)

      assert {:error, :not_found} =
               Channels.transfer_ownership(scope(alice), channel.id, "garbage")

      assert Channels.owner?(scope(alice), channel.id)
    end

    test "refuses a non-owner actor", %{alice: alice, bob: bob, channel: channel} do
      assert {:error, :forbidden} = Channels.transfer_ownership(scope(bob), channel.id, alice.id)
      assert Channels.owner?(scope(alice), channel.id)
      refute Channels.owner?(scope(bob), channel.id)
    end

    test "a target who left before the write keeps the channel's owner intact", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      # bob (the intended new owner) leaves before the transfer — role_of finds no row, so the
      # promotion transaction never runs and the channel is NOT left ownerless (the count-check
      # guard's whole point).
      Repo.delete_all(
        from m in Membership, where: m.channel_id == ^channel.id and m.user_id == ^bob.id
      )

      assert {:error, :not_found} = Channels.transfer_ownership(scope(alice), channel.id, bob.id)
      assert Channels.owner?(scope(alice), channel.id)
    end
  end

  describe "owner offboarding / reassign_orphaned_ownerships/1 (#358)" do
    test "hands a solely-owned channel to the senior admin", %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "admin")
      carol = user_fixture(%{username: "carol358a"})
      {:ok, _} = insert_member(channel.id, carol.id, "member")

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      assert Channels.member_role(scope(bob), channel.id) == "owner"
      assert Channels.member_role(scope(alice), channel.id) == "member"
      assert Channels.member_role(scope(carol), channel.id) == "member"
    end

    test "falls back to the oldest member when there's no admin", %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      carol = user_fixture(%{username: "carol358b"})
      {:ok, _} = insert_member(channel.id, carol.id, "member")

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      # Oldest join wins (bob joined before carol); user-id tiebreak keeps it deterministic.
      assert Channels.member_role(scope(bob), channel.id) == "owner"
      assert Channels.member_role(scope(carol), channel.id) == "member"
    end

    test "picks only a usable successor — skips deactivated/deleted members",
         %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      # bob outranks carol (admin vs member) but is deactivated → not a valid owner.
      {:ok, _} = insert_member(channel.id, bob.id, "admin")
      bob |> Ecto.Changeset.change(active: false) |> Repo.update!()
      carol = user_fixture(%{username: "carol358d"})
      {:ok, _} = insert_member(channel.id, carol.id, "member")

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      assert Channels.member_role(scope(carol), channel.id) == "owner"
      assert Channels.member_role(scope(bob), channel.id) == "admin"
    end

    test "deletes an orphaned channel on the deletion path (delete_orphans: true)",
         %{alice: alice, bob: bob} do
      {:ok, solo} = Channels.create_channel(scope(alice), %{"name" => "Solo"})
      {:ok, ghost} = Channels.create_channel(scope(alice), %{"name" => "Ghost"})
      {:ok, _} = insert_member(ghost.id, bob.id, "member")
      bob |> Ecto.Changeset.change(active: false) |> Repo.update!()

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id, delete_orphans: true)

      # Solo: no other members. Ghost: only other member is deactivated → no usable successor.
      assert Repo.get(Channel, solo.id) == nil
      assert Repo.get(Channel, ghost.id) == nil
    end

    test "keeps a solo-owned channel on the deactivation path (delete_orphans off)",
         %{alice: alice} do
      {:ok, solo} = Channels.create_channel(scope(alice), %{"name" => "Solo"})

      # Reversible flow default: no usable successor → leave the channel (reactivation restores
      # it; a solo channel strands no one else). Deletion is only for the irreversible path.
      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      assert Repo.get(Channel, solo.id)
      assert Channels.member_role(scope(alice), solo.id) == "owner"
    end

    test "is idempotent — a second run is a no-op", %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "admin")

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)
      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      assert Channels.member_role(scope(bob), channel.id) == "owner"
      assert Channels.member_role(scope(alice), channel.id) == "member"
    end

    test "the new owner regains full owner rights (delete was blocked before)",
         %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "admin")

      assert :ok = Channels.reassign_orphaned_ownerships(alice.id)

      assert :ok = Channels.delete_channel(scope(bob), channel.id)
      assert Repo.get(Channel, channel.id) == nil
    end

    test "list_members omits anonymized (deleted) members (#358/R004)",
         %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")

      bob
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      {:ok, members} = Channels.list_members(scope(alice), channel.id)
      ids = Enum.map(members, & &1.user.id)
      assert alice.id in ids
      refute bob.id in ids
    end
  end

  describe "rooms" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      # Bob joined after creation — materialize him into existing rooms (the
      # public join flow lands with #30).
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      %{channel: channel}
    end

    test "a channel is born with a general room every member can use", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      assert {:ok, [room]} = Channels.list_rooms(scope(alice), channel.id)
      assert room.name == "general"

      # Materialized memberships start read-up-to-now; unread comparison is
      # strictly-greater at second granularity, so backdate alice's marker.
      backdate_last_read(room.id, alice.id)

      # Bob (materialized) can post into it through the ordinary Chat API.
      assert {:ok, _} = Eden.Chat.create_message(scope(bob), room.id, %{"body" => "hello"})
      assert {:ok, [%{unread_count: 1}]} = Channels.list_rooms(scope(alice), channel.id)
    end

    test "create_room is admin-only and seeds only the creator (#41)", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      assert {:error, :forbidden} =
               Channels.create_room(scope(bob), channel.id, %{"name" => "ops"})

      assert {:ok, room} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      assert room.position == 1

      # Only the creator is materialized; bob (a channel member) is NOT
      # auto-added — he'd join via the room link (open) or be added (private).
      assert {:ok, _} = Eden.Chat.create_message(scope(alice), room.id, %{"body" => "first"})

      assert {:error, :not_found} =
               Eden.Chat.create_message(scope(bob), room.id, %{"body" => "no"})
    end

    test "rename and delete are admin-only; delete reclaims the room", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, room} = Channels.create_room(scope(alice), channel.id, %{"name" => "temp"})

      assert {:error, :forbidden} = Channels.rename_room(scope(bob), room.id, %{"name" => "x"})

      assert {:ok, %{name: "ops2"}} =
               Channels.rename_room(scope(alice), room.id, %{"name" => "ops2"})

      assert {:error, :forbidden} = Channels.delete_room(scope(bob), room.id)
      assert :ok = Channels.delete_room(scope(alice), room.id)
      assert is_nil(Eden.Chat.get_room(room.id))
    end

    test "a non-member can't even see the rooms", %{channel: channel} do
      carol = user_fixture(%{username: "carolrm"})
      assert {:error, :not_found} = Channels.list_rooms(scope(carol), channel.id)
      assert [] == Eden.Chat.list_rooms(scope(carol), channel.id)
    end

    test "rooms stay out of the DM sidebar and search", %{alice: alice, channel: channel} do
      {:ok, [room]} = Channels.list_rooms(scope(alice), channel.id)
      {:ok, _} = Eden.Chat.create_message(scope(alice), room.id, %{"body" => "findme rooms"})

      assert [] == Eden.Chat.list_conversations(scope(alice))
      assert %{messages: [], conversations: []} = Eden.Chat.search(scope(alice), "findme")
    end

    test "per-user delete-chat refuses rooms", %{alice: alice, channel: channel} do
      {:ok, [room]} = Channels.list_rooms(scope(alice), channel.id)
      assert {:error, :not_found} = Eden.Chat.delete_conversation(scope(alice), room.id)
    end

    test "leave_rooms drops the user's room memberships", %{bob: bob, channel: channel} do
      :ok = Eden.Chat.leave_rooms(channel.id, bob.id)
      assert [] == Eden.Chat.list_rooms(scope(bob), channel.id)
    end

    test "reorder_rooms is admin-only and reassigns positions", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      {:ok, [general, _]} = Channels.list_rooms(scope(alice), channel.id)

      assert {:error, :forbidden} =
               Channels.reorder_rooms(scope(bob), channel.id, [ops.id, general.id])

      :ok = Channels.reorder_rooms(scope(alice), channel.id, [ops.id, general.id])
      {:ok, rooms} = Channels.list_rooms(scope(alice), channel.id)
      assert ["ops", "general"] == Enum.map(rooms, & &1.name)
    end

    test "deleting the channel reclaims room attachment blobs (forward-safe)", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, [room]} = Channels.list_rooms(scope(alice), channel.id)

      {:ok, msg} =
        Eden.Chat.create_attachment_message(scope(alice), room.id, %{path: real_png()})

      key = hd(msg.attachments).storage_key

      # A forward into a DM must keep the shared blob alive.
      {:ok, dm} = Eden.Chat.create_conversation(scope(alice), [bob.id])
      {:ok, _} = Eden.Chat.forward_message(scope(alice), msg.id, dm.id)

      :ok = Channels.delete_channel(scope(alice), channel.id)
      assert Eden.Storage.exists?(key)

      # Without the forward the blob would be gone — prove via a fresh channel.
      {:ok, ch2} = Channels.create_channel(scope(alice), %{"name" => "Tmp"})
      {:ok, [room2]} = Channels.list_rooms(scope(alice), ch2.id)

      {:ok, msg2} =
        Eden.Chat.create_attachment_message(scope(alice), room2.id, %{path: real_png()})

      key2 = hd(msg2.attachments).storage_key
      :ok = Channels.delete_channel(scope(alice), ch2.id)
      refute Eden.Storage.exists?(key2)
    end
  end

  describe "last-opened room (#81)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      # alice creates a second room; only the creator is seeded into it (#41).
      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      %{channel: channel, general: general, ops: ops}
    end

    test "entry room defaults to general when nothing is recorded", %{
      alice: alice,
      channel: channel,
      general: general
    } do
      assert entry_room(scope(alice), channel.id) == general.id
    end

    test "recording a room makes it the entry room, per user", %{
      alice: alice,
      bob: bob,
      channel: channel,
      general: general,
      ops: ops
    } do
      assert :ok = Channels.record_last_room(scope(alice), channel.id, ops.id)

      # alice's entry room follows her last room; bob (never opened ops) still general.
      assert entry_room(scope(alice), channel.id) == ops.id
      assert entry_room(scope(bob), channel.id) == general.id
    end

    test "a remembered room the user can't access falls back to general", %{
      bob: bob,
      channel: channel,
      general: general,
      ops: ops
    } do
      # bob is pointed at ops but isn't a member of it (only alice was seeded).
      :ok = Channels.record_last_room(scope(bob), channel.id, ops.id)
      assert entry_room(scope(bob), channel.id) == general.id
    end

    test "a deleted remembered room nilifies and falls back to general", %{
      alice: alice,
      channel: channel,
      general: general,
      ops: ops
    } do
      :ok = Channels.record_last_room(scope(alice), channel.id, ops.id)
      assert :ok = Channels.delete_room(scope(alice), ops.id)
      # FK on_delete: :nilify_all cleared last_room_id → back to general.
      assert entry_room(scope(alice), channel.id) == general.id
    end
  end

  describe "members" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      %{channel: channel, carol: carol, bob: bob}
    end

    test "add_members materializes rooms in the same step; idempotent", %{
      alice: alice,
      bob: bob,
      carol: carol,
      channel: channel
    } do
      assert {:ok, added} = Channels.add_members(scope(alice), channel.id, [bob.id, carol.id])
      assert Enum.sort(added) == Enum.sort([bob.id, carol.id])

      # Materialized: bob can use general right away.
      {:ok, [general]} = Channels.list_rooms(scope(bob), channel.id)
      assert {:ok, _} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "hi"})

      # Re-adding is a no-op.
      assert {:ok, []} = Channels.add_members(scope(alice), channel.id, [bob.id])

      assert {:ok, members} = Channels.list_members(scope(alice), channel.id)
      assert [%{role: "owner"}, %{role: "member"}, %{role: "member"}] = members
    end

    test "member cannot add; added users' rails are pinged", %{
      alice: alice,
      bob: bob,
      carol: carol,
      channel: channel
    } do
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id])
      assert {:error, :forbidden} = Channels.add_members(scope(bob), channel.id, [carol.id])

      Channels.subscribe_user(scope(carol))
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [carol.id])
      assert_receive :channels_changed
    end

    test "removal matrix: owner > admin > member; rooms cleaned; target notified", %{
      alice: alice,
      bob: bob,
      carol: carol,
      channel: channel
    } do
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id, carol.id])
      :ok = Channels.set_member_role(scope(alice), channel.id, bob.id, "admin")

      # Admin can't remove an admin/owner; can remove a member.
      assert {:error, :forbidden} = Channels.remove_member(scope(bob), channel.id, alice.id)
      Channels.subscribe_user(scope(carol))
      assert :ok = Channels.remove_member(scope(bob), channel.id, carol.id)
      assert_receive {:removed_from_channel, _}
      assert [] == Eden.Chat.list_rooms(scope(carol), channel.id)

      # Nobody removes themselves through remove_member.
      assert {:error, :self} = Channels.remove_member(scope(alice), channel.id, alice.id)
    end

    test "leave: members may, the owner must transfer or delete", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id])

      assert {:error, :owner} = Channels.leave_channel(scope(alice), channel.id)

      assert :ok = Channels.leave_channel(scope(bob), channel.id)
      assert [] == Channels.list_channels(scope(bob))
      assert [] == Eden.Chat.list_rooms(scope(bob), channel.id)
    end

    test "role changes are owner-only; ownership transfer unblocks leaving", %{
      alice: alice,
      bob: bob,
      carol: carol,
      channel: channel
    } do
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id, carol.id])

      assert {:error, :forbidden} =
               Channels.set_member_role(scope(bob), channel.id, carol.id, "admin")

      :ok = Channels.set_member_role(scope(alice), channel.id, bob.id, "admin")
      assert Channels.admin?(scope(bob), channel.id)

      # The owner row is untouchable via set_member_role (self-demotion blocked).
      assert {:error, :self} =
               Channels.set_member_role(scope(alice), channel.id, alice.id, "member")

      :ok = Channels.transfer_ownership(scope(alice), channel.id, bob.id)
      assert Channels.owner?(scope(bob), channel.id)
      assert Channels.member_role(scope(alice), channel.id) == "admin"
      assert :ok = Channels.leave_channel(scope(alice), channel.id)
    end
  end

  describe "invite links" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Linked"})
      %{channel: channel, bob: bob}
    end

    test "create returns the raw token once; only the hash is stored", %{
      alice: alice,
      channel: channel
    } do
      assert {:ok, invite, raw} = Channels.create_invite(scope(alice), channel.id)
      assert invite.hashed_token == Eden.Accounts.hash_token(raw)
      refute invite.hashed_token == raw
      assert {:ok, [_]} = Channels.list_invites(scope(alice), channel.id)
    end

    test "revoke_invites_by kills every live invite the user minted (#305 review P2)", %{
      alice: alice,
      channel: channel
    } do
      {:ok, live1, raw1} = Channels.create_invite(scope(alice), channel.id)
      {:ok, _live2, _raw2} = Channels.create_invite(scope(alice), channel.id)

      # An already-revoked one keeps its timestamp (not re-stamped), and the count is the live ones.
      Channels.revoke_invite(scope(alice), live1.id)
      before = Repo.get(Eden.Channels.Invite, live1.id).revoked_at

      assert Channels.revoke_invites_by(alice.id) == 1
      assert Repo.get(Eden.Channels.Invite, live1.id).revoked_at == before
      assert {:ok, []} = Channels.list_invites(scope(alice), channel.id)
      # A revoked token no longer joins.
      assert {:error, :revoked} = Channels.join_by_token(scope(alice), raw1)
    end

    test "joining adds membership + rooms; idempotent; counts uses", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, invite, raw} = Channels.create_invite(scope(alice), channel.id)

      assert {:ok, joined, nil} = Channels.join_by_token(scope(bob), raw)
      assert joined.id == channel.id
      assert joined.role == "member"
      {:ok, [_general]} = Channels.list_rooms(scope(bob), channel.id)

      # Already a member: ok again, but no extra use consumed.
      assert {:ok, _, _} = Channels.join_by_token(scope(bob), raw)
      assert Repo.get(Eden.Channels.Invite, invite.id).used_count == 1
    end

    test "revoked / expired / exhausted / garbage tokens are rejected", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      carol = user_fixture(%{username: "caroli"})

      {:ok, invite, raw} = Channels.create_invite(scope(alice), channel.id)
      :ok = Channels.revoke_invite(scope(alice), invite.id)
      assert {:error, :revoked} = Channels.join_by_token(scope(bob), raw)

      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      {:ok, _, raw2} = Channels.create_invite(scope(alice), channel.id, expires_at: past)
      assert {:error, :expired} = Channels.join_by_token(scope(bob), raw2)

      {:ok, _, raw3} = Channels.create_invite(scope(alice), channel.id, max_uses: 1)
      assert {:ok, _, _} = Channels.join_by_token(scope(bob), raw3)
      assert {:error, :exhausted} = Channels.join_by_token(scope(carol), raw3)

      assert {:error, :invalid} = Channels.join_by_token(scope(bob), "garbage-token")
    end

    test "members can't manage invites", %{alice: alice, bob: bob, channel: channel} do
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id])

      assert {:error, :forbidden} = Channels.create_invite(scope(bob), channel.id)
      assert {:error, :forbidden} = Channels.list_invites(scope(bob), channel.id)

      {:ok, invite, _raw} = Channels.create_invite(scope(alice), channel.id)
      assert {:error, :forbidden} = Channels.revoke_invite(scope(bob), invite.id)
    end
  end

  describe "rail badges + channel mute" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      %{channel: channel, general: general}
    end

    test "list_channels aggregates room unread into the rail badge", %{
      alice: alice,
      bob: bob,
      general: general
    } do
      # alice has no unread yet.
      assert [%{unread_count: 0, muted: false}] = Channels.list_channels(scope(alice))

      backdate_last_read(general.id, alice.id)
      {:ok, _} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "hi"})
      {:ok, _} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "again"})

      assert [%{unread_count: 2}] = Channels.list_channels(scope(alice))
      # The sender sees no unread from their own messages.
      assert [%{unread_count: 0}] = Channels.list_channels(scope(bob))
    end

    test "a directly-muted room drops out of the rail aggregate", %{
      alice: alice,
      bob: bob,
      channel: channel,
      general: general
    } do
      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      # bob joins the ops room (open) to be able to post (#41: no auto-fan-out).
      :ok = Eden.Chat.join_room(ops.id, bob.id)
      backdate_last_read(general.id, alice.id)
      backdate_last_read(ops.id, alice.id)

      {:ok, _} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "g"})
      {:ok, _} = Eden.Chat.create_message(scope(bob), ops.id, %{"body" => "o"})
      assert [%{unread_count: 2}] = Channels.list_channels(scope(alice))

      # Mute the ops room directly — it stops counting toward the rail badge.
      {:ok, :muted} = Eden.Chat.toggle_conversation_mute(scope(alice), ops.id)
      assert [%{unread_count: 1}] = Channels.list_channels(scope(alice))
    end

    test "toggle_channel_mute flips the flag and pings the rail", %{
      alice: alice,
      channel: channel
    } do
      Channels.subscribe_user(scope(alice))

      assert {:ok, true} = Channels.toggle_channel_mute(scope(alice), channel.id)
      assert_receive :channels_changed
      assert [%{muted: true}] = Channels.list_channels(scope(alice))

      assert {:ok, false} = Channels.toggle_channel_mute(scope(alice), channel.id)
      assert [%{muted: false}] = Channels.list_channels(scope(alice))
    end

    test "non-member / garbage channel can't be muted", %{channel: channel} do
      carol = user_fixture(%{username: "carolmute"})
      assert {:error, :not_found} = Channels.toggle_channel_mute(scope(carol), channel.id)
      assert {:error, :not_found} = Channels.toggle_channel_mute(scope(carol), "abc")
    end

    test "channel unread excludes thread replies", %{
      alice: alice,
      bob: bob,
      general: general
    } do
      backdate_last_read(general.id, alice.id)
      {:ok, root} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "root"})
      {:ok, _} = Eden.Chat.create_reply(scope(bob), root.id, %{"body" => "reply"})

      # Only the root counts; the reply lives in the thread.
      assert [%{unread_count: 1}] = Channels.list_channels(scope(alice))
    end
  end

  describe "knock to join a private room (#41)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)

      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      %{channel: channel, priv: priv}
    end

    test "request → admin approve adds the member and flips the message", ctx do
      %{alice: alice, bob: bob, priv: priv} = ctx

      assert {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
      refute Eden.Chat.room_member?(priv.id, bob.id)

      # Deduped: a second request doesn't post another message.
      assert {:ok, :already} = Channels.request_room_join(scope(bob), priv.id)

      # The pending request is visible to admins in the room.
      msg = Eden.Chat.pending_join_request(priv.id, bob.id)
      assert msg && msg.meta["status"] == "pending"
      assert msg.meta["requester_name"] == bob.display_name

      assert :ok = Channels.approve_room_join(scope(alice), msg.id)
      assert Eden.Chat.room_member?(priv.id, bob.id)

      # The request flipped to accepted; no longer pending.
      assert is_nil(Eden.Chat.pending_join_request(priv.id, bob.id))
    end

    test "approving a knock from a since-deleted requester declines it, doesn't add them (#305)",
         ctx do
      %{alice: alice, bob: bob, priv: priv} = ctx
      assert {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
      msg = Eden.Chat.pending_join_request(priv.id, bob.id)

      # Bob is permanently deleted after knocking.
      bob
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Eden.Repo.update!()

      assert :ok = Channels.approve_room_join(scope(alice), msg.id)
      # Not resurrected into the room; the stale knock is settled (declined, no longer pending).
      refute Eden.Chat.room_member?(priv.id, bob.id)
      assert is_nil(Eden.Chat.pending_join_request(priv.id, bob.id))
    end

    test "an open room can't be knocked", %{alice: alice, bob: bob, channel: channel} do
      {:ok, open} = Channels.create_room(scope(alice), channel.id, %{"name" => "lounge"})
      assert {:error, :not_private} = Channels.request_room_join(scope(bob), open.id)
    end

    test "a knock notifies the room's channel owner/admins (#363/R029)", ctx do
      %{alice: alice, bob: bob, priv: priv} = ctx
      # alice is the channel owner → she should hear the knock.
      sub(alice)

      assert {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)

      rid = priv.id
      bid = bob.id

      assert_receive {:notify,
                      %{conversation_id: ^rid, kind: "knock", sender_id: ^bid, preview: ""}}
    end

    test "the requester isn't self-notified and a plain system message rings no one (#363)",
         ctx do
      %{alice: alice, bob: bob, priv: priv} = ctx
      # bob is a plain member (and the requester) → not in the owner/admin recipient set.
      sub(bob)
      assert {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
      refute_receive {:notify, _}

      # A non-knock system message (only create_system_message, no knock path) notifies nobody —
      # the regression barrier for the %User{}-sender payload contract (#363/R108).
      sub(alice)
      {:ok, _} = Eden.Chat.create_system_message(priv.id, %{"action" => "noticeboard"})
      refute_receive {:notify, _}
    end

    test "a non-channel-member can't request; an existing room member can't either", ctx do
      %{bob: bob, priv: priv} = ctx
      carol = user_fixture(%{username: "carolk"})
      assert {:error, :not_found} = Channels.request_room_join(scope(carol), priv.id)

      :ok = Eden.Chat.join_room(priv.id, bob.id)
      assert {:error, :member} = Channels.request_room_join(scope(bob), priv.id)
    end

    test "only an admin approves; a plain member can't", ctx do
      %{alice: alice, bob: bob, channel: channel, priv: priv} = ctx
      carol = user_fixture(%{username: "carolk2"})
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [carol.id])

      {:ok, :requested} = Channels.request_room_join(scope(carol), priv.id)
      msg = Eden.Chat.pending_join_request(priv.id, carol.id)

      assert {:error, :forbidden} = Channels.approve_room_join(scope(bob), msg.id)
      refute Eden.Chat.room_member?(priv.id, carol.id)

      assert :ok = Channels.approve_room_join(scope(alice), msg.id)
      assert Eden.Chat.room_member?(priv.id, carol.id)
    end

    test "approve tolerates a garbage / non-join-request message id", ctx do
      %{alice: alice, priv: priv} = ctx
      assert {:error, :not_found} = Channels.approve_room_join(scope(alice), "garbage")
      assert {:error, :not_found} = Channels.approve_room_join(scope(alice), 999_999)

      # A system message that isn't a join request → :not_found, never a crash.
      {:ok, other} = Eden.Chat.create_system_message(priv.id, %{"action" => "noticeboard"})
      assert {:error, :not_found} = Channels.approve_room_join(scope(alice), other.id)
    end

    test "approving a requester who left the channel re-joins them to the channel too", ctx do
      %{alice: alice, bob: bob, channel: channel, priv: priv} = ctx

      {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
      msg = Eden.Chat.pending_join_request(priv.id, bob.id)

      # bob leaves the channel while his knock is pending.
      :ok = Channels.leave_channel(scope(bob), channel.id)
      assert [] == Channels.list_channels(scope(bob))

      # Approval heals both memberships — never a room without its channel.
      assert :ok = Channels.approve_room_join(scope(alice), msg.id)
      assert Eden.Chat.room_member?(priv.id, bob.id)
      assert Channels.member_role(scope(bob), channel.id) == "member"

      # #261: the channel membership and its general room commit together (one transaction),
      # so a re-join never leaves a channel membership without general.
      {:ok, rooms} = Channels.list_rooms(scope(alice), channel.id)
      general = Enum.find(rooms, & &1.is_general)
      assert Eden.Chat.room_member?(general.id, bob.id)
    end

    test "general can never be flipped to private (#41 invariant)", %{alice: alice} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Inv"})
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      assert general.is_general

      # A crafted rename payload carrying visibility must be rejected...
      assert {:error, %Ecto.Changeset{} = cs} =
               Channels.rename_room(scope(alice), general.id, %{
                 "name" => "general",
                 "visibility" => "private"
               })

      assert "general is always open" in errors_on(cs).visibility

      # ...while a plain rename still works, and non-general rooms may flip.
      assert {:ok, _} = Channels.rename_room(scope(alice), general.id, %{"name" => "townsq"})

      {:ok, other} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})

      assert {:ok, %{visibility: "private"}} =
               Channels.rename_room(scope(alice), other.id, %{
                 "name" => "ops",
                 "visibility" => "private"
               })
    end
  end

  describe "room invites + internal-add (#41 PR-C2)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})

      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      %{channel: channel, priv: priv, bob: bob}
    end

    test "a private-room invite grants channel + room in one redemption", ctx do
      %{alice: alice, bob: bob, channel: channel, priv: priv} = ctx
      assert {:ok, _invite, raw} = Channels.create_room_invite(scope(alice), priv.id)

      # bob isn't even a channel member yet.
      assert [] == Channels.list_channels(scope(bob))

      assert {:ok, joined, room_id} = Channels.join_by_token(scope(bob), raw)
      assert joined.id == channel.id
      assert room_id == priv.id
      assert Eden.Chat.room_member?(priv.id, bob.id)
      # And the channel general too.
      assert {:ok, rooms} = Channels.list_rooms(scope(bob), channel.id)
      assert Enum.any?(rooms, & &1.is_general)
    end

    test "an open room can't get an invite token (its plain link is the invite)", ctx do
      %{alice: alice, channel: channel} = ctx
      {:ok, open} = Channels.create_room(scope(alice), channel.id, %{"name" => "lounge"})
      assert {:error, :not_private} = Channels.create_room_invite(scope(alice), open.id)
    end

    test "only an admin creates a room invite", ctx do
      %{alice: alice, bob: bob, channel: channel, priv: priv} = ctx
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id])
      assert {:error, :forbidden} = Channels.create_room_invite(scope(bob), priv.id)
    end

    test "a room-invite redemption is idempotent (no double use)", ctx do
      %{alice: alice, bob: bob, priv: priv} = ctx
      {:ok, invite, raw} = Channels.create_room_invite(scope(alice), priv.id)

      assert {:ok, _, _} = Channels.join_by_token(scope(bob), raw)
      assert {:ok, _, _} = Channels.join_by_token(scope(bob), raw)
      assert Repo.get(Eden.Channels.Invite, invite.id).used_count == 1
    end

    test "add_room_members (admin) materializes channel + room for non-channel users", ctx do
      %{alice: alice, priv: priv, channel: channel} = ctx
      carol = user_fixture(%{username: "caroladd"})
      refute Eden.Chat.room_member?(priv.id, carol.id)

      assert {:ok, [added]} = Channels.add_room_members(scope(alice), priv.id, [carol.id])
      assert added == carol.id
      assert Eden.Chat.room_member?(priv.id, carol.id)
      # carol is now a channel member (general) too.
      assert {:ok, rooms} = Channels.list_rooms(scope(carol), channel.id)
      assert Enum.any?(rooms, & &1.is_general)

      # Idempotent.
      assert {:ok, []} = Channels.add_room_members(scope(alice), priv.id, [carol.id])
    end

    test "a non-admin can't add room members", ctx do
      %{alice: alice, bob: bob, channel: channel, priv: priv} = ctx
      {:ok, _} = Channels.add_members(scope(alice), channel.id, [bob.id])
      carol = user_fixture(%{username: "caroladd2"})
      assert {:error, :forbidden} = Channels.add_room_members(scope(bob), priv.id, [carol.id])
    end
  end

  describe "room menu actions (#42)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      %{channel: channel, general: general}
    end

    test "general is undeletable; ordinary rooms still delete", ctx do
      %{alice: alice, channel: channel, general: general} = ctx

      assert {:error, :general} = Channels.delete_room(scope(alice), general.id)
      assert {:ok, _} = Channels.list_rooms(scope(alice), channel.id)

      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      assert :ok = Channels.delete_room(scope(alice), ops.id)
    end

    test "favorites float to the top per user and survive renames", ctx do
      %{alice: alice, bob: bob, channel: channel} = ctx
      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})
      {:ok, zoo} = Channels.create_room(scope(alice), channel.id, %{"name" => "zoo"})
      :ok = Eden.Chat.join_room(ops.id, bob.id)
      :ok = Eden.Chat.join_room(zoo.id, bob.id)

      # alice favorites zoo — it floats to her top, bob's order is untouched.
      assert {:ok, :favorited} = Eden.Chat.toggle_room_favorite(scope(alice), zoo.id)
      {:ok, alice_rooms} = Channels.list_rooms(scope(alice), channel.id)
      assert ["zoo", "general", "ops"] == Enum.map(alice_rooms, & &1.name)
      assert [%{favorite: true} | _] = alice_rooms

      {:ok, bob_rooms} = Channels.list_rooms(scope(bob), channel.id)
      assert ["general", "ops", "zoo"] == Enum.map(bob_rooms, & &1.name)

      # Survives a rename; unfavorite restores canonical order.
      {:ok, _} = Channels.rename_room(scope(alice), zoo.id, %{"name" => "zoo2"})
      {:ok, alice_rooms} = Channels.list_rooms(scope(alice), channel.id)
      assert [%{name: "zoo2", favorite: true} | _] = alice_rooms

      assert {:ok, :unfavorited} = Eden.Chat.toggle_room_favorite(scope(alice), zoo.id)
      {:ok, alice_rooms} = Channels.list_rooms(scope(alice), channel.id)
      assert ["general", "ops", "zoo2"] == Enum.map(alice_rooms, & &1.name)
    end

    test "favoriting a room you're not in is :not_found", ctx do
      %{alice: alice, channel: channel} = ctx
      carol = user_fixture(%{username: "carolfav"})

      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      assert {:error, :not_found} = Eden.Chat.toggle_room_favorite(scope(carol), priv.id)
    end

    test "decline flips the request and allows a re-knock", ctx do
      %{alice: alice, bob: bob, channel: channel} = ctx

      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
      msg = Eden.Chat.pending_join_request(priv.id, bob.id)

      # A plain member can't decline.
      assert {:error, :forbidden} = Channels.decline_room_join(scope(bob), msg.id)

      assert :ok = Channels.decline_room_join(scope(alice), msg.id)
      refute Eden.Chat.room_member?(priv.id, bob.id)
      assert is_nil(Eden.Chat.pending_join_request(priv.id, bob.id))

      # Only "pending" blocks a re-request — bob may knock again.
      assert {:ok, :requested} = Channels.request_room_join(scope(bob), priv.id)
    end

    test "list_invites labels room invites with their room", ctx do
      %{alice: alice, channel: channel} = ctx

      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, _, _} = Channels.create_invite(scope(alice), channel.id)
      {:ok, _, _} = Channels.create_room_invite(scope(alice), priv.id)

      {:ok, invites} = Channels.list_invites(scope(alice), channel.id)
      rooms = Enum.map(invites, &(&1.room && &1.room.name))
      assert "secret" in rooms
      assert nil in rooms
    end
  end

  describe "search_rooms/3 (#43)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, other} = Channels.create_channel(scope(alice), %{"name" => "Other"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      {:ok, [other_general]} = Channels.list_rooms(scope(alice), other.id)
      %{channel: channel, other: other, general: general, other_general: other_general}
    end

    test "channel scope finds messages only in that channel's joined rooms", ctx do
      %{alice: alice, bob: bob, channel: channel, general: general, other_general: og} = ctx

      {:ok, _} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle here"})
      {:ok, _} = Eden.Chat.create_message(scope(alice), og.id, %{"body" => "needle elsewhere"})

      # A private room bob is NOT in.
      {:ok, priv} =
        Channels.create_room(scope(alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, _} = Eden.Chat.create_message(scope(alice), priv.id, %{"body" => "needle secret"})

      results = Eden.Chat.search_rooms(scope(bob), {:channel, channel.id}, "needle")
      assert ["needle here"] == Enum.map(results, & &1.body)

      # alice (a member of priv) sees both within the channel — never the other channel.
      results = Eden.Chat.search_rooms(scope(alice), {:channel, channel.id}, "needle")
      assert Enum.sort(Enum.map(results, & &1.body)) == ["needle here", "needle secret"]
    end

    test "room scope is limited to one room; thread replies are excluded (#189)", ctx do
      %{alice: alice, channel: channel, general: general} = ctx
      {:ok, ops} = Channels.create_room(scope(alice), channel.id, %{"name" => "ops"})

      {:ok, root} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "pin base"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), root.id, %{"body" => "pin reply"})
      {:ok, _} = Eden.Chat.create_message(scope(alice), ops.id, %{"body" => "pin other room"})

      # The reply lives in the thread, not the main stream — search_thread/3 covers it now;
      # the room's main-stream search only returns the root (and never the other room).
      results = Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "pin")
      assert ["pin base"] == Enum.map(results, & &1.body)
    end

    test "system messages never surface, even with a matchable body", ctx do
      %{alice: alice, general: general} = ctx

      {:ok, _} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle user"})

      # A system row with a body that WOULD match — proves the kind filter
      # does the work, not the (incidental) empty body of real system messages.
      Repo.insert!(%Eden.Chat.Message{
        conversation_id: general.id,
        kind: "system",
        body: "needle system",
        meta: %{"action" => "join_request"}
      })

      results = Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "needle")
      assert ["needle user"] == Enum.map(results, & &1.body)
    end

    test "tombstoned and hidden messages never match; min length applies", ctx do
      %{alice: alice, bob: bob, general: general} = ctx

      {:ok, gone} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "ghost gone"})
      {:ok, hid} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "ghost hidden"})
      :ok = Eden.Chat.delete_message_for_both(scope(bob), gone.id)
      :ok = Eden.Chat.delete_message_for_me(scope(alice), hid.id)

      assert [] == Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "ghost")
      assert [] == Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "g")
    end

    test "garbage scope ids return nothing (no crash)", ctx do
      %{alice: alice} = ctx
      assert [] == Eden.Chat.search_rooms(scope(alice), {:channel, "abc"}, "needle")
      assert [] == Eden.Chat.search_rooms(scope(alice), {:room, "abc"}, "needle")
    end

    test "LIKE metacharacters match literally", ctx do
      %{alice: alice, general: general} = ctx

      {:ok, _} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "100% done"})
      {:ok, _} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "100 done"})

      results = Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "0% d")
      assert ["100% done"] == Enum.map(results, & &1.body)
    end

    test "room search tolerates a typo too (#56 fuzzy match)", ctx do
      %{alice: alice, general: general} = ctx

      {:ok, _} =
        Eden.Chat.create_message(scope(alice), general.id, %{"body" => "deployment notes"})

      # One-letter typo, not a substring — word-similarity finds it (same body
      # match as DM search, so the trigram upgrade lifts both).
      results = Eden.Chat.search_rooms(scope(alice), {:room, general.id}, "deploymant")
      assert ["deployment notes"] == Enum.map(results, & &1.body)
    end

    test "fuzzy room search never leaks a room you're not in (#56)", ctx do
      # bob is in `general` but NOT in `other_general` (a different channel's room).
      %{alice: alice, bob: bob, other_general: og} = ctx
      {:ok, _} = Eden.Chat.create_message(scope(alice), og.id, %{"body" => "deployment notes"})

      # The typo matches that body, but bob isn't a member of og — scoped out.
      assert [] == Eden.Chat.search_rooms(scope(bob), {:room, og.id}, "deploymant")
    end
  end

  describe "search_thread/3 (#189)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      %{channel: channel, general: general}
    end

    test "returns only this thread's matching replies — not the root, other threads, or the main stream",
         ctx do
      %{alice: alice, general: general} = ctx
      {:ok, root} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle root"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), root.id, %{"body" => "needle reply one"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), root.id, %{"body" => "needle reply two"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), root.id, %{"body" => "unrelated"})

      # A different thread + a main-stream message that ALSO match "needle".
      {:ok, other} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle two"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), other.id, %{"body" => "needle elsewhere"})
      {:ok, _} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle main"})

      results = Eden.Chat.search_thread(scope(alice), root.id, "needle")
      assert Enum.sort(Enum.map(results, & &1.body)) == ["needle reply one", "needle reply two"]
    end

    test "scoped by membership: a non-member of the room gets nothing", ctx do
      %{alice: alice, general: general} = ctx
      carol = user_fixture(%{username: "carol_t189", display_name: "Carol"})
      {:ok, root} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "needle root"})
      {:ok, _} = Eden.Chat.create_reply(scope(alice), root.id, %{"body" => "needle reply"})

      assert [] == Eden.Chat.search_thread(scope(carol), root.id, "needle")
    end

    test "tombstoned/hidden replies never match; min length + garbage root return nothing", ctx do
      %{alice: alice, bob: bob, general: general} = ctx
      {:ok, root} = Eden.Chat.create_message(scope(alice), general.id, %{"body" => "ghost root"})
      {:ok, gone} = Eden.Chat.create_reply(scope(bob), root.id, %{"body" => "ghost gone"})
      {:ok, hid} = Eden.Chat.create_reply(scope(bob), root.id, %{"body" => "ghost hidden"})
      :ok = Eden.Chat.delete_message_for_both(scope(bob), gone.id)
      :ok = Eden.Chat.delete_message_for_me(scope(alice), hid.id)

      assert [] == Eden.Chat.search_thread(scope(alice), root.id, "ghost")
      # Min length (2) applies, and a non-integer root id can't crash the cast.
      assert [] == Eden.Chat.search_thread(scope(alice), root.id, "g")
      assert [] == Eden.Chat.search_thread(scope(alice), "abc", "needle")
    end
  end

  describe "cross-layer (#32)" do
    setup %{alice: alice, bob: bob} do
      {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Team"})
      {:ok, _} = insert_member(channel.id, bob.id, "member")
      :ok = Eden.Chat.join_general(channel.id, bob.id)
      {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
      {:ok, dm} = Eden.Chat.create_conversation(scope(alice), [bob.id])
      %{channel: channel, general: general, dm: dm}
    end

    test "forwarding works both directions between a DM and a room", ctx do
      %{alice: alice, general: general, dm: dm} = ctx

      {:ok, in_dm} = Eden.Chat.create_message(scope(alice), dm.id, %{"body" => "from dm"})
      {:ok, fwd_to_room} = Eden.Chat.forward_message(scope(alice), in_dm.id, general.id)
      assert fwd_to_room.conversation_id == general.id
      # It really landed in the room (a channel conversation), reads back there.
      {:ok, room_msgs} = Eden.Chat.list_messages(scope(alice), general.id)
      assert Enum.any?(room_msgs, &(&1.id == fwd_to_room.id and &1.forwarded_from_id == in_dm.id))

      {:ok, in_room} =
        Eden.Chat.create_message(scope(alice), general.id, %{"body" => "from room"})

      {:ok, fwd_to_dm} = Eden.Chat.forward_message(scope(alice), in_room.id, dm.id)
      assert fwd_to_dm.conversation_id == dm.id
      {:ok, dm_msgs} = Eden.Chat.list_messages(scope(alice), dm.id)
      assert Enum.any?(dm_msgs, &(&1.id == fwd_to_dm.id))
    end

    test "folder badges ignore room unread (rooms can't enter folders)", ctx do
      %{alice: alice, bob: bob, general: general, dm: dm} = ctx

      {:ok, folder} = Eden.Chat.create_folder(scope(alice), %{"name" => "Work"})
      {:ok, :added} = Eden.Chat.toggle_conversation_folder(scope(alice), dm.id, folder.id)

      backdate_last_read(dm.id, alice.id)
      backdate_last_read(general.id, alice.id)
      {:ok, _} = Eden.Chat.create_message(scope(bob), dm.id, %{"body" => "dm unread"})
      {:ok, _} = Eden.Chat.create_message(scope(bob), general.id, %{"body" => "room unread"})

      # The folder reflects only its DM; the room's unread never leaks in.
      assert [%{id: fid, unread_count: 1}] = Eden.Chat.list_folders(scope(alice))
      assert fid == folder.id
    end

    test "a room can't be added to a folder", ctx do
      %{alice: alice, general: general} = ctx
      {:ok, folder} = Eden.Chat.create_folder(scope(alice), %{"name" => "Nope"})

      # Rooms aren't sidebar conversations; the move-to-folder path refuses them.
      assert {:error, :not_found} =
               Eden.Chat.toggle_conversation_folder(scope(alice), general.id, folder.id)
    end
  end

  defp backdate_last_read(conversation_id, user_id) do
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    Repo.update_all(
      from(m in Eden.Chat.Membership,
        where: m.conversation_id == ^conversation_id and m.user_id == ^user_id
      ),
      set: [last_read_at: past]
    )
  end

  # A real, decodable PNG for attachment GC tests.
  defp real_png do
    {:ok, img} = Image.new(600, 400, color: [40, 90, 200])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "ch-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Direct membership plumbing — the public add-member flow lands with #30.
  defp insert_member(channel_id, user_id, role) do
    %Membership{}
    |> Membership.changeset(%{channel_id: channel_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  defp promote(channel_id, user_id, role) do
    Repo.update_all(
      from(m in Membership, where: m.channel_id == ^channel_id and m.user_id == ^user_id),
      set: [role: role]
    )
  end
end
