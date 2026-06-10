defmodule Eden.ChannelsTest do
  use Eden.DataCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Channels
  alias Eden.Channels.{Channel, Membership}

  defp scope(user), do: Scope.for_user(user)

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
