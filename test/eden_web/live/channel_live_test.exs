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
    :ok = Chat.join_general(channel.id, bob.id)
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

    test "rail channel link: desktop reopens the entry room, mobile shows the room list (#92)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      slot = "#rail-channel-#{ctx.channel.id}"

      # Desktop link → reopen the channel's remembered room (#81 intact): hidden by
      # default, shown at md+. entry room falls back to general (no last room yet).
      assert has_element?(
               view,
               ~s|#{slot} a[href="/channels/#{ctx.channel.id}/r/#{ctx.general.id}"][class*="hidden"][class*="md:inline-flex"]|
             )

      # Mobile link → bare channel (its room list), hidden at md+ (#92) so tapping a
      # channel on a phone lands on the room choice, not a forced last room.
      assert has_element?(
               view,
               ~s|#{slot} a[href="/channels/#{ctx.channel.id}"][class*="md:hidden"]|
             )
    end

    test "a long channel description wraps instead of overflowing (#63)", ctx do
      long = String.duplicate("флоыврлфыовфлор", 8)
      {:ok, ch} = Channels.create_channel(scope(ctx.alice), %{"name" => "Wide", "about" => long})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ch.id}")

      assert html =~ long
      # The empty-state description column breaks long words (no h-overflow).
      assert has_element?(view, ".max-w-sm.break-words")
    end

    test "a non-member auto-joins the channel (general) — channels are never closed (#41)", ctx do
      dave = user_fixture(%{username: "dave"})
      conn = log_in_user(ctx.conn, dave)

      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")
      # Landed in the channel with general materialized — not bounced home.
      assert html =~ "Engineering"
      assert {:ok, [%{name: "general"}]} = Channels.list_rooms(scope(dave), ctx.channel.id)
    end

    test "a truly missing channel still redirects home", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)

      assert {:error, {:live_redirect, %{to: "/app"}}} =
               live(conn, ~p"/channels/#{2_000_000_000}")
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

  describe "room access (#41 matrix)" do
    setup [:setup_channel]

    test "an open-room link auto-joins a non-member and opens it", ctx do
      {:ok, open} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "lounge"})
      refute Chat.room_member?(open.id, ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{open.id}")

      assert html =~ "lounge"
      assert Chat.room_member?(open.id, ctx.bob.id)
    end

    test "a private-room link shows the knock window; request → admin approve lands the user",
         ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{priv.id}")

      # Knock window, not the room; the private room isn't revealed in the sidebar.
      assert html =~ "This room is private"
      assert has_element?(bob_view, ~s(button[phx-click="request_join"]))
      refute has_element?(bob_view, ~s(a[href="/channels/#{ctx.channel.id}/r/#{priv.id}"]))

      # #91: the knock window lives inside <main>, which is hidden on mobile when no
      # room is selected. A pending knock leaves selected nil, so the guard must keep
      # <main> visible — otherwise the window is invisible on phones.
      refute has_element?(bob_view, "main.hidden")

      # Request → pending state; not yet a member.
      render_click(bob_view, "request_join", %{})
      assert render(bob_view) =~ "Request sent."
      refute Chat.room_member?(priv.id, ctx.bob.id)

      # An admin viewing the room sees the request and approves it.
      :ok = Chat.join_room(priv.id, ctx.alice.id)
      alice_conn = log_in_user(build_conn(), ctx.alice)
      {:ok, alice_view, _} = live(alice_conn, ~p"/channels/#{ctx.channel.id}/r/#{priv.id}")
      assert render(alice_view) =~ "requested to join"

      msg = Chat.pending_join_request(priv.id, ctx.bob.id)
      render_click(alice_view, "approve_join", %{"id" => to_string(msg.id)})

      assert Chat.room_member?(priv.id, ctx.bob.id)
      # bob's open session clears the knock window live (now a member).
      refute render(bob_view) =~ "This room is private"
    end

    test "a member can't approve a join request", ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, :requested} = Channels.request_room_join(scope(ctx.bob), priv.id)
      msg = Chat.pending_join_request(priv.id, ctx.bob.id)

      # carol is a plain member who somehow got into the room; she can't approve.
      carol = user_fixture(%{username: "carolA"})
      {:ok, _} = add_member(ctx.channel.id, carol.id)
      :ok = Chat.join_room(priv.id, carol.id)

      conn = log_in_user(ctx.conn, carol)
      {:ok, view, _} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{priv.id}")
      # No Add button for a non-admin.
      refute has_element?(view, ~s(button[phx-click="approve_join"]))
      render_click(view, "approve_join", %{"id" => to_string(msg.id)})
      refute Chat.room_member?(priv.id, ctx.bob.id)
    end

    test "an existing member just opens the room (no re-join side effects)", ctx do
      {:ok, open} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "lounge"})
      :ok = Chat.join_room(open.id, ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{open.id}")
      assert html =~ "lounge"
    end
  end

  describe "corporate search (#43)" do
    setup [:setup_channel]

    test "channel search groups room-name and message matches; click deep-links", ctx do
      {:ok, lounge} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "lounge"})

      {:ok, _} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "lounge talk"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_change(view, "channel_search", %{"q" => "lounge"})
      # Room-name match links to the room; message match carries the breadcrumb.
      # NB: the highlight splits the matched term out into <mark>, so assert
      # the pieces — the literal "lounge talk" substring never exists in HTML.
      assert has_element?(view, ~s(a[href="/channels/#{ctx.channel.id}/r/#{lounge.id}"]))
      assert html =~ "ed-mark"
      assert html =~ "talk"

      assert has_element?(
               view,
               ~s(a[href^="/channels/#{ctx.channel.id}/r/#{ctx.general.id}/m/"])
             )

      # Clearing restores the rooms list.
      render_click(view, "clear_channel_search", %{})
      assert has_element?(view, "#rooms-list")
    end

    test "a whitespace-only query never hijacks the rooms list", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_change(view, "channel_search", %{"q" => " "})
      assert has_element?(view, "#rooms-list")
      refute html =~ "ed-search__group"
    end

    test "a message-result breadcrumb carries the room's glyph, not a bare #", ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "vault",
          "visibility" => "private"
        })

      {:ok, _} = Chat.create_message(scope(ctx.alice), priv.id, %{"body" => "needle plans"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_change(view, "channel_search", %{"q" => "needle"})

      assert has_element?(
               view,
               ~s(a[href^="/channels/#{ctx.channel.id}/r/#{priv.id}/m/"] .hero-lock-closed-micro)
             )
    end

    test "channel search never sees rooms the user isn't in", ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "warroom",
          "visibility" => "private"
        })

      {:ok, _} = Chat.create_message(scope(ctx.alice), priv.id, %{"body" => "warroom plans"})

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_change(view, "channel_search", %{"q" => "warroom"})
      refute html =~ "warroom plans"
      refute html =~ ">warroom<"
    end

    test "in-room search finds messages and replies; a reply result opens the thread", ctx do
      {:ok, root} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "agenda"})
      {:ok, reply} = Chat.create_reply(scope(ctx.bob), root.id, %{"body" => "agenda follow-up"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      render_click(view, "toggle_room_search", %{})
      html = render_change(view, "room_search", %{"q" => "agenda"})
      # The match is wrapped in <mark>, so assert the unmatched tail.
      assert html =~ "follow-up"
      assert html =~ "ed-room-search__panel"

      # Following the reply permalink opens the thread panel.
      {:ok, view, _html} =
        live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}/m/#{reply.id}")

      assert has_element?(view, ".ed-thread")
    end
  end

  describe "channel avatar (#70)" do
    setup [:setup_channel]

    test "an owner uploads an avatar via the edit modal; the rail shows it", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_channel_edit", %{})
      assert has_element?(view, "#edit-channel input[type=file]")

      {:ok, img} = Image.new(400, 300, color: [200, 80, 40])
      {:ok, bytes} = Image.write(img, :memory, suffix: ".png")

      avatar =
        file_input(view, "#edit-channel-form", :channel_avatar, [
          %{name: "a.png", content: bytes, type: "image/png"}
        ])

      render_upload(avatar, "a.png")
      view |> form("#edit-channel-form", channel: %{name: "Engineering"}) |> render_submit()

      assert {:ok, %{avatar_key: key}} = Channels.get_channel(scope(ctx.alice), ctx.channel.id)
      assert is_binary(key)
      assert has_element?(view, "#rail-channel-#{ctx.channel.id} img.ed-rail__img")
    end
  end

  describe "quote-reply inside a thread (#71)" do
    setup [:setup_channel]

    test "a quote-reply from the thread panel posts INTO the thread, not the room", ctx do
      {:ok, root} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "root"})
      {:ok, reply} = Chat.create_reply(scope(ctx.bob), root.id, %{"body" => "first reply"})

      conn = log_in_user(ctx.conn, ctx.alice)

      {:ok, view, _html} =
        live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}/m/#{reply.id}")

      assert has_element?(view, "#thread-#{reply.id}")

      # Quote-reply the thread reply → the THREAD composer's tray appears.
      render_hook(view, "reply_in_thread", %{"id" => to_string(reply.id)})
      assert has_element?(view, "#reply-composer .ed-reply-bar__name", "Bob")

      # Send via the thread composer carrying the quote.
      view
      |> form("#reply-composer",
        reply: %{body: "quoting in thread", reply_to_id: to_string(reply.id)}
      )
      |> render_submit()

      {:ok, _root, replies} = Chat.list_thread(scope(ctx.alice), root.id)
      new = Enum.find(replies, &(&1.body == "quoting in thread"))

      assert new, "the reply landed in the thread"
      assert new.root_id == root.id, "it's a thread reply, not a room message"
      assert new.reply_to_id == reply.id, "it quotes the target"
      # Rendered in the thread panel, never the main room stream.
      assert has_element?(view, "#thread-#{new.id}")
      refute has_element?(view, "#messages-#{new.id}")
    end

    test "tapping a quote that targets a thread reply opens the thread, not 'unavailable'", ctx do
      {:ok, root} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "root"})
      {:ok, reply} = Chat.create_reply(scope(ctx.bob), root.id, %{"body" => "a reply"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")
      refute has_element?(view, ".ed-thread")

      # focus_original resolves the thread reply's home and opens its thread
      # (the old hard-coded messages-<id> path would flash "unavailable").
      render_hook(view, "focus_original", %{"id" => to_string(reply.id)})
      assert has_element?(view, ".ed-thread")
      assert has_element?(view, "#thread-#{reply.id}")
    end
  end

  describe "reactions in rooms + threads (#67)" do
    setup [:setup_channel]

    test "reacting to a thread reply updates the panel, never the main stream", ctx do
      {:ok, root} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "agenda"})
      {:ok, reply} = Chat.create_reply(scope(ctx.bob), root.id, %{"body" => "follow-up"})

      conn = log_in_user(ctx.conn, ctx.alice)
      # The reply permalink opens the room with the thread panel showing the reply.
      {:ok, view, _html} =
        live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}/m/#{reply.id}")

      assert has_element?(view, "#thread-#{reply.id}")

      # Bob reacts to the reply; it lands via broadcast in the thread panel...
      {:ok, _} = Chat.toggle_reaction(scope(ctx.bob), reply.id, "👍")
      assert has_element?(view, ~s(#thread-#{reply.id} .ed-react[phx-value-emoji="👍"]))
      # ...and must NOT leak into the main message stream (replies live only there).
      refute has_element?(view, "#messages-#{reply.id}")
    end

    test "reacting to a room root message updates the main stream", ctx do
      {:ok, root} = Chat.create_message(scope(ctx.alice), ctx.general.id, %{"body" => "ship it"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")

      {:ok, _} = Chat.toggle_reaction(scope(ctx.bob), root.id, "🎉")
      assert has_element?(view, ~s(#messages-#{root.id} .ed-react[phx-value-emoji="🎉"]))
    end
  end

  describe "room visibility picker" do
    setup [:setup_channel]

    test "the create modal offers Open/Private and creates a private room", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_click(view, "open_new_room", %{})
      assert html =~ "Open"
      assert html =~ "Private"

      view
      |> form("#room-form", %{"room" => %{"name" => "secret", "visibility" => "private"}})
      |> render_submit()

      {:ok, rooms} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
      assert %{visibility: "private"} = Enum.find(rooms, &(&1.name == "secret"))
      # The row shows the lock glyph (general keeps #, open rooms the globe).
      assert render(view) =~ "hero-lock-closed-micro"
    end

    test "room glyphs: general is always #, open rooms get the globe, private the lock", ctx do
      {:ok, _open} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "lounge"})

      {:ok, _priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      assert html =~ "hero-globe-alt-micro"
      assert html =~ "hero-lock-closed-micro"
      # general renders the literal hash, not an icon.
      assert has_element?(view, "#room-#{ctx.general.id} .ed-room__hash span", "#")
      refute has_element?(view, "#room-#{ctx.general.id} .hero-globe-alt-micro")
    end

    test "the rename modal hides the picker for general but offers it elsewhere", ctx do
      {:ok, ops} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "ops"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      # general: no Access fieldset.
      html = render_click(view, "open_room_rename", %{"id" => to_string(ctx.general.id)})
      refute html =~ "Access"
      render_click(view, "close_room_modal", %{})

      # ordinary room: the picker is there, and flipping to private works.
      html = render_click(view, "open_room_rename", %{"id" => to_string(ops.id)})
      assert html =~ "Access"

      view
      |> form("#room-form", %{"room" => %{"name" => "ops", "visibility" => "private"}})
      |> render_submit()

      {:ok, rooms} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
      assert %{visibility: "private"} = Enum.find(rooms, &(&1.name == "ops"))
    end
  end

  describe "room menu (#42)" do
    setup [:setup_channel]

    test "mark-as-read clears the room badge and the rail aggregate", ctx do
      backdate_last_read(ctx.general.id, ctx.alice.id)
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "unread"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")
      assert has_element?(view, "#room-#{ctx.general.id} .ed-badge", "1")

      render_click(view, "mark_as_read", %{"id" => to_string(ctx.general.id)})
      refute has_element?(view, "#room-#{ctx.general.id} .ed-badge")
      refute has_element?(view, ".ed-rail__badge")
    end

    test "favorite floats the room into the Favorites block live", ctx do
      {:ok, ops} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "ops"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")
      refute html =~ "Favorites"

      render_click(view, "toggle_room_favorite", %{"id" => to_string(ops.id)})
      html = render(view)
      # Two group headers appear, Favorites first.
      groups =
        ~r/ed-rooms__group">\s*([^<\s][^<]*?)\s*</
        |> Regex.scan(html)
        |> Enum.map(fn [_, name] -> name end)

      assert groups == ["Favorites", "Rooms"]
    end

    test "the general delete item is hidden and the context refuses anyway", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      # No delete item inside general's menu (admin sees it on other rooms).
      refute has_element?(
               view,
               ~s(#room-menu-#{ctx.general.id} button[phx-click="delete_room"])
             )

      # Forced event still bounces off the context guard.
      render_click(view, "delete_room", %{"id" => to_string(ctx.general.id)})
      assert {:ok, [_general]} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
    end

    test "admin reorders rooms by drag (displayed sequence becomes canonical)", ctx do
      {:ok, ops} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "ops"})
      {:ok, zoo} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "zoo"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      ids = [to_string(zoo.id), to_string(ops.id), to_string(ctx.general.id)]
      render_click(view, "reorder_rooms", %{"ids" => ids})

      {:ok, rooms} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
      assert ["zoo", "ops", "general"] == Enum.map(rooms, & &1.name)
    end

    test "a member can't reorder (event is a no-op)", ctx do
      {:ok, ops} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "ops"})
      :ok = Chat.join_room(ops.id, ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "reorder_rooms", %{
        "ids" => [to_string(ops.id), to_string(ctx.general.id)]
      })

      {:ok, rooms} = Channels.list_rooms(scope(ctx.alice), ctx.channel.id)
      assert ["general", "ops"] == Enum.map(rooms, & &1.name)
    end

    test "room add modal: picker adds a platform user; private rooms offer an invite link",
         ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      carol = user_fixture(%{username: "carolrm2", display_name: "Carol"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      html = render_click(view, "open_room_add", %{"id" => to_string(priv.id)})
      assert html =~ "Add to secret"
      assert html =~ "Carol"
      assert has_element?(view, ~s(button[phx-click="create_room_invite"]))

      # Invite link is shown once.
      html = render_click(view, "create_room_invite", %{})
      assert html =~ "/channels/join/"

      # Picker adds carol: room + channel general (the #41 matrix).
      render_click(view, "toggle_room_add_user", %{"id" => to_string(carol.id)})
      render_click(view, "confirm_room_add", %{})
      assert Chat.room_member?(priv.id, carol.id)
      assert {:ok, _} = Channels.list_rooms(Scope.for_user(carol), ctx.channel.id)
    end

    test "an admin can decline a knock from the system message", ctx do
      {:ok, priv} =
        Channels.create_room(scope(ctx.alice), ctx.channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, :requested} = Channels.request_room_join(scope(ctx.bob), priv.id)
      msg = Chat.pending_join_request(priv.id, ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{priv.id}")
      assert has_element?(view, ~s(button[phx-click="decline_join"]))

      render_click(view, "decline_join", %{"id" => to_string(msg.id)})
      assert render(view) =~ "Declined"
      refute Chat.room_member?(priv.id, ctx.bob.id)
    end
  end

  describe "room management" do
    setup [:setup_channel]

    test "admin creates a room (seeds the creator); others don't see it until they join (#41)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      # Another member's session watches the same channel.
      bob_conn = log_in_user(build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_new_room", %{})

      view
      |> form("#room-form", %{"room" => %{"name" => "ops"}})
      |> render_submit()

      # The creator sees it; bob doesn't — rooms are link-discovered, the
      # sidebar lists only rooms you're in.
      assert render(view) =~ "ops"
      refute render(bob_view) =~ "ops"
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
      # general is undeletable (#42) — use an ordinary room bob is in.
      {:ok, ops} = Channels.create_room(scope(ctx.alice), ctx.channel.id, %{"name" => "ops"})
      :ok = Chat.join_room(ops.id, ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, bob_view, _} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ops.id}")

      :ok = Channels.delete_room(scope(ctx.alice), ops.id)

      assert_patch(bob_view, "/channels/#{ctx.channel.id}")
      refute has_element?(bob_view, "form[phx-submit=send]")
    end

    test "opening a room clears its unread badge", ctx do
      backdate_last_read(ctx.general.id, ctx.alice.id)
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "unread one"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")
      assert html =~ "ed-badge"

      # The room-list link specifically — the rail button now also points at the
      # room (#81 entry room), so disambiguate from it.
      view
      |> element(~s(a.ed-room[href="/channels/#{ctx.channel.id}/r/#{ctx.general.id}"]))
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

  describe "rail badges + channel mute (#32)" do
    setup [:setup_channel]

    test "the rail shows a channel's aggregate unread and clears it on read", ctx do
      backdate_last_read(ctx.general.id, ctx.alice.id)
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "ping"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(view, "#rail-channel-#{ctx.channel.id} .ed-rail__badge", "1")

      # Reading the room clears the badge.
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}/r/#{ctx.general.id}")
      refute has_element?(view, "#rail-channel-#{ctx.channel.id} .ed-rail__badge")
    end

    test "muting a channel from the rail de-emphasizes its badge live", ctx do
      backdate_last_read(ctx.general.id, ctx.alice.id)
      {:ok, _} = Chat.create_message(scope(ctx.bob), ctx.general.id, %{"body" => "ping"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      refute has_element?(view, ".ed-rail__badge--muted")
      render_click(view, "toggle_channel_mute", %{"id" => to_string(ctx.channel.id)})

      assert has_element?(view, "#rail-channel-#{ctx.channel.id} .ed-rail__badge--muted")
      assert [%{muted: true}] = Channels.list_channels(scope(ctx.alice))
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
