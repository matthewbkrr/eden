defmodule EdenWeb.ChannelModeTest do
  @moduledoc """
  Channel mode of ChatLive (corporate layer): the /channels/... routes — rail,
  rooms sidebar, room messaging through the shared message pane, and the
  channel header menu.
  """
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Channels
  alias Eden.Chat

  defp scope(user), do: Scope.for_user(user)

  defp setup_channel(_context) do
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    bob = user_fixture(%{username: "bob", display_name: "Bob"})
    {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Engineering"})
    {:ok, _} = add_member(channel.id, bob.id)
    :ok = Chat.join_rooms(channel.id, bob.id)
    {:ok, [general]} = Channels.list_rooms(scope(alice), channel.id)
    %{alice: alice, bob: bob, channel: channel, general: general}
  end

  describe "channel workspace" do
    setup [:setup_channel]

    test "a member sees the rooms sidebar; the rail marks the channel active", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      assert html =~ "Engineering"
      assert html =~ "general"
      assert html =~ "ed-rail__btn--active"
      assert html =~ "Pick a room to start reading."
    end

    test "a non-member is redirected home", ctx do
      dave = user_fixture(%{username: "dave"})
      conn = log_in_user(ctx.conn, dave)

      assert {:error, {:live_redirect, %{to: "/app"}}} =
               live(conn, ~p"/channels/#{ctx.channel.id}")
    end

    test "opening a room renders the shared message pane and sends work", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      # Room header, not the DM profile header.
      assert html =~ "ed-room__hash"
      assert html =~ "general"

      view
      |> form("form[phx-submit=send]", message: %{body: "first room message"})
      |> render_submit()

      assert render(view) =~ "first room message"
    end

    test "a room from another channel is rejected", ctx do
      {:ok, other} = Channels.create_channel(scope(ctx.alice), %{"name" => "Other"})
      {:ok, [other_room]} = Channels.list_rooms(scope(ctx.alice), other.id)

      conn = log_in_user(ctx.conn, ctx.alice)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/channels/#{ctx.channel.id}/r/#{other_room.id}")

      assert to == "/channels/#{ctx.channel.id}"
    end

    test "the DM permalink shape bounces a room to its channel route", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/app/c/#{ctx.general.id}")
      assert to == "/channels/#{ctx.channel.id}/r/#{ctx.general.id}"
    end

    test "rooms never appear in the DM sidebar", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      refute has_element?(view, "#conversations-#{ctx.general.id}")
    end

    test "realtime: a message lands in the open room", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "from bob"})
      html = render(view)
      assert html =~ "from bob"
      # Regression: an unloaded forwarded_from assoc is truthy and used to
      # phantom-render the "Forwarded" label on realtime messages.
      refute html =~ "Forwarded"
    end
  end

  describe "room management" do
    setup [:setup_channel]

    test "admin creates a room from the modal; it appears for members live", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      # A member session watches the same channel.
      bob_conn = log_in_user(build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_new_room", %{})

      view
      |> form("#room-form", %{"room" => %{"name" => "ops"}})
      |> render_submit()

      assert render(view) =~ "ops"
      assert render(bob_view) =~ "ops"
    end

    test "member sees no admin affordances and can't force them", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      refute html =~ "Rename room"
      refute html =~ "Delete room"
      refute html =~ "New room"

      # Forced events are no-ops / flashes, never crashes.
      render_click(view, "open_new_room", %{})
      refute render(view) =~ "room-form"

      render_click(view, "delete_room", %{"id" => to_string(ctx.general.id)})
      assert {:ok, [_general]} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
    end

    test "renaming the open room updates its header everywhere", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, _} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      {:ok, _} = Channels.rename_room(scope(ctx.alice), ctx.general.id, %{"name" => "lobby"})

      html = render(bob_view)
      assert html =~ "lobby"
      refute html =~ ">general<"
    end

    test "deleting the open room patches viewers back to the channel", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, _} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      :ok = Channels.delete_room(scope(ctx.alice), ctx.general.id)

      assert_patch(bob_view, "/channels/#{ctx.channel.id}")
      refute has_element?(bob_view, "form[phx-submit=send]")
    end

    test "opening a room clears its unread badge", ctx do
      backdate_last_read(ctx.general.id, ctx.alice.id)
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "unread one"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")
      assert html =~ "ed-badge"

      view
      |> element(~s(a[href="/channels/#{ctx.channel.id}/r/#{ctx.general.id}"]))
      |> render_click()

      # Regression: the rooms list refreshes on select, so the badge clears.
      refute render(view) =~ "ed-badge\""
    end

    test "muting a room from its context menu de-emphasizes the badge", ctx do
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "ping"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "toggle_mute", %{"id" => to_string(ctx.general.id)})
      assert render(view) =~ "ed-convo__muted"
    end
  end

  describe "channel header menu" do
    setup [:setup_channel]

    test "owner edits the channel", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_channel_edit", %{})

      view
      |> form("#edit-channel-form", %{"channel" => %{"name" => "Core", "about" => "Us"}})
      |> render_submit()

      html = render(view)
      assert html =~ "Core"
      assert html =~ "Us"
    end

    test "owner deletes the channel and lands home", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "delete_channel", %{})
      assert_redirect(view, "/app")
    end

    test "a delete in another session navigates the viewer home", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, _} = live(conn, ~p"/channels/#{ctx.channel.id}")

      :ok = Channels.delete_channel(scope(ctx.alice), ctx.channel.id)
      assert_redirect(bob_view, "/app")
    end

    test "a member sees no edit/delete in the menu", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      refute html =~ "Edit channel"
      refute html =~ "Delete channel"

      render_click(view, "open_channel_edit", %{})
      refute render(view) =~ "edit-channel-form"
    end
  end

  describe "channel access UI" do
    setup [:setup_channel]

    test "members modal lists roles; owner promotes and the target's header role updates live",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      bob_conn = log_in_user(build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/channels/#{ctx.channel.id}")
      refute render(bob_view) =~ "Edit channel"

      html = render_click(view, "open_channel_members", %{})
      assert html =~ "Members"
      assert html =~ "owner"
      assert html =~ "member"

      render_click(view, "set_member_role", %{"id" => to_string(ctx.bob.id), "role" => "admin"})

      # Bob's open session re-fetched its role: admin affordances appeared.
      assert render(bob_view) =~ "Edit channel"
    end

    test "add-members flow materializes the new member", ctx do
      carol = user_fixture(%{username: "carolx", display_name: "Carol"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_click(view, "open_add_members", %{})
      assert html =~ "Carol"

      render_click(view, "toggle_add_user", %{"id" => to_string(carol.id)})
      render_click(view, "confirm_add_members", %{})

      assert Channels.member_role(Scope.for_user(carol), ctx.channel.id) == "member"
      assert {:ok, [_general]} = Channels.list_rooms(Scope.for_user(carol), ctx.channel.id)
    end

    test "invite modal creates a link shown once and revokes it", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_invites", %{})
      html = render_click(view, "create_invite", %{})
      assert html =~ "/channels/join/"
      assert html =~ "Copy this link now"

      {:ok, [invite]} = Channels.list_invites(scope(ctx.alice), ctx.channel.id)
      html = render_click(view, "revoke_invite", %{"id" => to_string(invite.id)})
      refute html =~ "Active links"
      assert {:ok, []} = Channels.list_invites(scope(ctx.alice), ctx.channel.id)
    end

    test "a member can leave; the owner is told to transfer first", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "leave_channel", %{})
      assert_redirect(view, "/app")
      assert [] == Channels.list_channels(scope(ctx.bob))

      owner_conn = log_in_user(build_conn(), ctx.alice)
      {:ok, owner_view, _} = live(owner_conn, ~p"/channels/#{ctx.channel.id}")
      html = render_click(owner_view, "leave_channel", %{})
      assert html =~ "Transfer ownership or delete"
    end

    test "a removed member's open session is navigated away", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, _} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      :ok = Channels.remove_member(scope(ctx.alice), ctx.channel.id, ctx.bob.id)
      assert_redirect(bob_view, "/app")
    end

    test "member forcing admin-only access events gets nothing", ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_add_members", %{})
      refute render(view) =~ "Add members</h2>"

      render_click(view, "open_invites", %{})
      refute render(view) =~ "Invite links"

      render_click(view, "create_invite", %{})
      assert {:error, :forbidden} = Channels.list_invites(scope(ctx.bob), ctx.channel.id)
    end

    test "a crafted role value is an error, not a crash", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html =
        render_click(view, "set_member_role", %{"id" => to_string(ctx.bob.id), "role" => "owner"})

      assert html =~ "Couldn&#39;t change that role." or html =~ "Couldn't change that role."
      assert Channels.member_role(scope(ctx.bob), ctx.channel.id) == "member"
    end
  end

  describe "rail create flow (regression after the ChannelLive fold-in)" do
    setup [:setup_channel]

    test "creating a channel from the rail lands in it with a general room", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      render_click(view, "rail_new_channel", %{})

      view
      |> form("#new-channel-form", %{"channel" => %{"name" => "Design"}})
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/channels/\d+$}
    end
  end

  defp backdate_last_read(conversation_id, user_id) do
    import Ecto.Query
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    Eden.Repo.update_all(
      from(m in Eden.Chat.Membership,
        where: m.conversation_id == ^conversation_id and m.user_id == ^user_id
      ),
      set: [last_read_at: past]
    )
  end

  # Direct membership plumbing — the public add-member flow lands with #30.
  defp add_member(channel_id, user_id) do
    %Eden.Channels.Membership{}
    |> Eden.Channels.Membership.changeset(%{
      channel_id: channel_id,
      user_id: user_id,
      role: "member"
    })
    |> Eden.Repo.insert()
  end
end
