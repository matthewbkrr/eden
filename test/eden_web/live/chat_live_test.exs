defmodule EdenWeb.ChatLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Chat

  defp setup_conversation(_context) do
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    bob = user_fixture(%{username: "bob", display_name: "Bob"})
    {:ok, conversation} = Chat.create_conversation(Scope.for_user(alice), [bob.id])
    %{alice: alice, bob: bob, conversation: conversation}
  end

  defp real_png_path do
    {:ok, img} = Image.new(900, 600, color: [200, 60, 60])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    write_tmp(bytes)
  end

  defp write_tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "lv-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A noisy JPEG big enough that #122 server compression would downscale it (> @photo_max),
  # so a stored width of 2400 proves the photo was kept uncompressed. Returns raw bytes.
  defp big_jpeg(width, height) do
    {:ok, noise} = Vix.Vips.Operation.gaussnoise(width, height)
    {:ok, u8} = Vix.Vips.Operation.cast(noise, :VIPS_FORMAT_UCHAR)
    {:ok, bytes} = Image.write(u8, :memory, suffix: ".jpg", quality: 90)
    bytes
  end

  test "shows the empty state when nothing is selected", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _view, html} = live(conn, ~p"/app")
    assert html =~ "No conversation selected"
  end

  describe "group role actions in the profile panel (#165)" do
    setup do
      alice = user_fixture(%{username: "grp_alice", display_name: "Alice"})
      bob = user_fixture(%{username: "grp_bob", display_name: "Bob"})
      carol = user_fixture(%{username: "grp_carol", display_name: "Carol"})

      {:ok, group} =
        Chat.create_conversation(Scope.for_user(alice), [bob.id, carol.id],
          group: true,
          title: "Crew"
        )

      %{alice: alice, bob: bob, carol: carol, group: group}
    end

    test "the owner sees role actions and can promote a member to admin", %{
      conn: conn,
      alice: alice,
      bob: bob,
      group: group
    } do
      conn = log_in_user(conn, alice)
      {:ok, view, _} = live(conn, ~p"/app/c/#{group.id}")

      # Opening the panel reveals the per-member action cluster to the owner.
      assert render_click(view, "open_profile", %{}) =~ "group_set_role"

      render_click(view, "group_set_role", %{"id" => to_string(bob.id), "role" => "admin"})
      assert Chat.group_role(Scope.for_user(bob), group.id) == "admin"
    end

    test "the owner can remove a member from the panel", %{
      conn: conn,
      alice: alice,
      carol: carol,
      group: group
    } do
      conn = log_in_user(conn, alice)
      {:ok, view, _} = live(conn, ~p"/app/c/#{group.id}")
      render_click(view, "open_profile", %{})

      render_click(view, "group_remove_member", %{"id" => to_string(carol.id)})
      assert is_nil(Chat.group_role(Scope.for_user(carol), group.id))
    end

    test "a plain member sees no role actions and a crafted event is rejected", %{
      conn: conn,
      bob: bob,
      carol: carol,
      group: group
    } do
      conn = log_in_user(conn, bob)
      {:ok, view, _} = live(conn, ~p"/app/c/#{group.id}")

      # A member's panel offers no action buttons.
      refute render_click(view, "open_profile", %{}) =~ "group_set_role"

      # Even a hand-fired event is refused by the context — carol stays a member.
      render_click(view, "group_set_role", %{"id" => to_string(carol.id), "role" => "admin"})
      assert Chat.group_role(Scope.for_user(carol), group.id) == "member"
    end
  end

  describe "with a conversation" do
    setup [:setup_conversation]

    test "a member sees the title and message history", ctx do
      {:ok, _m} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "hi alice"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ "Bob"
      assert html =~ "hi alice"
    end

    test "a non-member is redirected to /app", ctx do
      dave = user_fixture(%{username: "dave"})
      conn = log_in_user(ctx.conn, dave)

      assert {:error, {:live_redirect, %{to: "/app"}}} =
               live(conn, ~p"/app/c/#{ctx.conversation.id}")
    end

    test "sending a message renders it", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      view
      |> form("form[phx-submit=send]", message: %{body: "hello there"})
      |> render_submit()

      assert render(view) =~ "hello there"
    end

    test "linkifies bare URLs in message text", ctx do
      {:ok, _m} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "see https://example.com/x now"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ ~s(href="https://example.com/x")
      assert html =~ ~s(rel="noopener noreferrer")
      # Surrounding text is preserved.
      assert html =~ "see "
      assert html =~ " now"
    end

    test "renders the markdown subset (#60): headings, bold/italic, code", ctx do
      {:ok, _m} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "## Plan with **bold**, *italic* and `code`"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ ~s(<span class="ed-md-h2">)
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<code>code</code>"
      # The composer offers an emoji picker. It's phx-update="ignore" so the
      # per-keystroke phx-change re-render can't re-assert the popover's static
      # `hidden` and snap it shut between picks — multi-select stays open (#90).
      assert has_element?(view, ~s(#emoji-picker[phx-update="ignore"] [data-emoji-toggle]))
    end

    test "reactions: toggle adds a chip (highlighted as mine), toggle again removes (#67)", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "react me"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # The quick-react row lives in the message context menu (right-click /
      # long-press); the "more" chevron opens the shared full-emoji grid (#72).
      assert has_element?(
               view,
               ~s(#menu-#{msg.id} .ed-menu__react[phx-click="react"][phx-value-emoji="👍"])
             )

      assert has_element?(view, ~s(#menu-#{msg.id} [data-react-expand]))
      # The full grid is one shared popover for the page (not per-message).
      assert has_element?(view, ~s(#reaction-grid [data-emoji]))

      render_hook(view, "react", %{"id" => to_string(msg.id), "emoji" => "👍"})
      # A chip appears under the message, highlighted as mine.
      assert has_element?(view, ~s(.ed-react--mine[phx-value-emoji="👍"]))
      assert render(view) =~ "ed-react__count"
      # The matching menu button reflects the active state too.
      assert has_element?(view, ~s(#menu-#{msg.id} .ed-menu__react--active[phx-value-emoji="👍"]))

      # Toggling the same emoji removes the chip.
      render_hook(view, "react", %{"id" => to_string(msg.id), "emoji" => "👍"})
      refute has_element?(view, ~s(.ed-react[phx-value-emoji="👍"]))
    end

    test "a reaction chip reveals its reactors on hover, 'you' for self, live (#82)", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "react me"})

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      refute has_element?(view, ~s(.ed-react[phx-value-emoji="👍"]))

      # Alice reacts from another session → bob's open view recomputes live on
      # {:reaction_changed}; the chip names her.
      {:ok, _} = Chat.toggle_reaction(Scope.for_user(ctx.alice), msg.id, "👍")
      assert has_element?(view, ~s(.ed-react[phx-value-emoji="👍"][title="Alice"]))

      # Bob reacts too → "Alice and you", and the a11y label matches the title.
      render_hook(view, "react", %{"id" => to_string(msg.id), "emoji" => "👍"})
      assert has_element?(view, ~s(.ed-react--mine[phx-value-emoji="👍"][title="Alice and you"]))

      assert has_element?(
               view,
               ~s(.ed-react[phx-value-emoji="👍"][aria-label="👍: Alice and you"])
             )
    end

    test "quote-reply: tray stages the target, send renders the quote (#71)", ctx do
      {:ok, target} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "the original"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # The menu offers a Reply action.
      assert has_element?(view, "#menu-#{target.id}", "Reply")

      # Staging a reply shows the composer tray with the target's author + snippet.
      render_hook(view, "reply", %{"id" => to_string(target.id)})
      assert has_element?(view, ~s(.ed-reply-bar__name), "Bob")
      assert render(view) =~ "the original"

      # Cancel clears the tray.
      render_hook(view, "cancel_reply", %{})
      refute has_element?(view, ".ed-reply-bar")

      # Re-stage and send → the new message renders a quote of the original.
      render_hook(view, "reply", %{"id" => to_string(target.id)})

      view
      |> form("form[phx-submit=send]",
        message: %{body: "my answer", reply_to_id: to_string(target.id)}
      )
      |> render_submit()

      assert has_element?(view, ".ed-quote__name", "Bob")
      assert render(view) =~ "my answer"
      # Tray cleared after sending.
      refute has_element?(view, ".ed-reply-bar")
    end

    test "a quote whose target was deleted renders 'Message deleted' (#71)", ctx do
      {:ok, target} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "doomed"})

      {:ok, _reply} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "re",
          "reply_to_id" => to_string(target.id)
        })

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), target.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ "Message deleted"
      assert html =~ ~s(class="ed-quote)
    end

    test "switching conversation clears a staged quote-reply (#71)", ctx do
      {:ok, target} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "x"})

      carol = user_fixture(%{username: "carol_sw", display_name: "Carol"})
      {:ok, conv2} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "reply", %{"id" => to_string(target.id)})
      assert has_element?(view, ".ed-reply-bar")

      # Switch conversations → the staged reply (its target is the old chat) drops.
      view |> element(~s(a[href="/app/c/#{conv2.id}"])) |> render_click()
      refute has_element?(view, ".ed-reply-bar")
    end

    test "switching conversations clears the composer input (#89)", ctx do
      carol = user_fixture(%{username: "carol_cz", display_name: "Carol"})
      {:ok, conv2} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Type a draft into the composer → it lives in the @composer form assign.
      render_change(view, "composer_changed", %{"message" => %{"body" => "leaky draft"}})
      assert render(view) =~ "leaky draft"

      # Switch conversations → the composer resets (the draft doesn't leak in).
      view |> element(~s(a[href="/app/c/#{conv2.id}"])) |> render_click()
      refute render(view) =~ "leaky draft"
    end

    test "re-selecting the already-open conversation is a no-op, keeping the draft (#166)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_change(view, "composer_changed", %{"message" => %{"body" => "kept draft"}})
      assert render(view) =~ "kept draft"

      # Clicking the open conversation again (push_patch to the same id) used to re-run
      # the full selection — resetting the stream (scroll jump + date-pill churn) and the
      # composer. The guard makes it a no-op, so the draft survives as proof of the no-reset.
      render_patch(view, ~p"/app/c/#{ctx.conversation.id}")
      assert render(view) =~ "kept draft"
    end

    test "switching conversations also drops staged attachments, not just text (#89)", ctx do
      carol = user_fixture(%{username: "carol_up", display_name: "Carol"})
      {:ok, conv2} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Stage a photo in conversation A → the compose tray appears.
      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")
      assert has_element?(view, "[data-upload-preview]")

      # Switch conversations → the staged tray is dropped, otherwise A's media
      # would ride into B's composer and a send would attach it to the wrong chat.
      view |> element(~s(a[href="/app/c/#{conv2.id}"])) |> render_click()
      refute has_element?(view, "[data-upload-preview]")
    end

    test "a staged video renders a playable <video> preview, not a static icon (#117)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{
            name: "clip.mp4",
            content: "fake-mp4",
            type: "video/mp4",
            last_modified: 1_700_000_000_000
          }
        ])

      html = render_upload(file, "clip.mp4")

      # A real <video> tile (wired to the VideoPreview hook) replaces the old static
      # film-icon span, so the staged clip is playable before sending (#117).
      assert has_element?(view, ~s(video.ed-compose__video[data-name="clip.mp4"]))
      # data-modified must ride the tag — VideoPreview keys by name:size:lastModified,
      # so dropping it would silently break the preview lookup.
      assert html =~ ~s(data-modified="1700000000000")
      # The interactive player carries an accessible name (the filename).
      assert html =~ ~s(aria-label="clip.mp4")
      # A lone clip previews at its natural aspect (#117) — the grid is flagged
      # single, so the tile isn't forced to a centre-cropped square.
      assert has_element?(view, ".ed-compose__grid--single video.ed-compose__video")
    end

    test "a peer coming online updates the sidebar dot live (#10/#94)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      slot = "#conversations-#{ctx.conversation.id}"
      # bob is offline → no online dot on his DM in alice's sidebar.
      refute has_element?(view, "#{slot} .ed-avatar__dot")

      # bob comes online; the presence diff makes alice's (streamed) sidebar
      # re-render the dot live — the bug was that stream items stayed stale. The
      # payload names bob, so the re-stream isn't skipped (he's a sidebar peer).
      EdenWeb.Presence.track_user(self(), ctx.bob.id)

      send(view.pid, %Phoenix.Socket.Broadcast{
        event: "presence_diff",
        topic: EdenWeb.Presence.topic(),
        payload: %{joins: %{to_string(ctx.bob.id) => %{metas: [%{}]}}, leaves: %{}}
      })

      assert has_element?(view, "#{slot} .ed-avatar__dot")
    end

    test "picking a status updates your own rail dot and persists (#102)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # Default "auto" → a plain green self-dot (no away/dnd modifier).
      assert has_element?(view, "#rail-me .ed-avatar__dot")
      refute has_element?(view, "#rail-me .ed-avatar__dot--dnd")

      view |> element(~s(#status-menu button[phx-value-status="dnd"])) |> render_click()

      assert has_element?(view, "#rail-me .ed-avatar__dot--dnd")
      assert Eden.Accounts.get_user!(ctx.alice.id).presence_status == "dnd"
    end

    test "the rail mini-profile carries identity, edit-profile and the statuses (#287)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # Discord-style card: @tag, an Edit-profile deep-link, and the status list.
      assert has_element?(view, "#status-menu", "@#{ctx.alice.username}")
      assert has_element?(view, ~s(#status-menu a[href="/settings/profile"]), "Edit profile")

      for status <- ~w(auto away dnd invisible) do
        assert has_element?(view, ~s(#status-menu button[phx-value-status="#{status}"]))
      end
    end

    test "a status change from another session updates this one live (#102 multi-tab)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      refute has_element?(view, "#rail-me .ed-avatar__dot--away")

      # The per-user presence broadcast (another tab / the Settings page).
      send(view.pid, {:presence_status_changed, "away"})

      assert has_element?(view, "#rail-me .ed-avatar__dot--away")
    end

    test "auto-away: idle shows away to others, activity restores online (#102)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      assert EdenWeb.Presence.statuses()[ctx.alice.id] == "online"

      render_hook(view, "presence_idle", %{})
      assert EdenWeb.Presence.statuses()[ctx.alice.id] == "away"
      # The user's own rail dot reflects auto-away too.
      assert has_element?(view, "#rail-me .ed-avatar__dot--away")

      render_hook(view, "presence_active", %{})
      assert EdenWeb.Presence.statuses()[ctx.alice.id] == "online"
      refute has_element?(view, "#rail-me .ed-avatar__dot--away")
    end

    test "auto-away: a manual status is unaffected by idle (#102)", ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "dnd")
      conn = log_in_user(ctx.conn, alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      assert EdenWeb.Presence.statuses()[alice.id] == "dnd"

      render_hook(view, "presence_idle", %{})
      assert EdenWeb.Presence.statuses()[alice.id] == "dnd"
    end

    test "the DM header shows 'last seen' for an offline peer (#102)", ctx do
      # bob has a recorded last-active time and isn't connected → offline.
      :ok = Eden.Accounts.touch_last_active(ctx.bob.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert render(view) =~ "last seen"
      assert has_element?(view, ~s(time[phx-hook][datetime]))
    end

    test "the last-seen heartbeat keeps touching while online, even when idle (#102)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # Idle but still connected = still "в сети" (last seen tracks last ONLINE, not
      # last active), so the heartbeat must keep updating last_active.
      render_hook(view, "presence_idle", %{})
      Eden.Repo.update_all(Eden.Accounts.User, set: [last_active_at: nil])
      send(view.pid, :touch_active)
      render(view)

      assert %DateTime{} = Eden.Accounts.get_user!(ctx.alice.id).last_active_at
    end

    test "an invisible user's last_active is never touched — no recency leak (#102)", ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "invisible")
      Eden.Repo.update_all(Eden.Accounts.User, set: [last_active_at: nil])

      conn = log_in_user(ctx.conn, alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      # mount must not touch while invisible.
      refute Eden.Accounts.get_user!(alice.id).last_active_at

      # neither the heartbeat nor an idle/active transition.
      send(view.pid, :touch_active)
      render_hook(view, "presence_active", %{})
      render(view)
      refute Eden.Accounts.get_user!(alice.id).last_active_at
    end

    test "a peer's away status colors their sidebar dot live (#102)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      slot = "#conversations-#{ctx.conversation.id}"

      EdenWeb.Presence.track_user(self(), ctx.bob.id, "away")

      send(view.pid, %Phoenix.Socket.Broadcast{
        event: "presence_diff",
        topic: EdenWeb.Presence.topic(),
        payload: %{joins: %{to_string(ctx.bob.id) => %{metas: [%{status: "away"}]}}, leaves: %{}}
      })

      assert has_element?(view, "#{slot} .ed-avatar__dot--away")
    end

    test "a peer's status-only change (online→away) re-streams the sidebar dot (#102)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      slot = "#conversations-#{ctx.conversation.id}"

      EdenWeb.Presence.track_user(self(), ctx.bob.id, "online")

      send(view.pid, %Phoenix.Socket.Broadcast{
        event: "presence_diff",
        topic: EdenWeb.Presence.topic(),
        payload: %{
          joins: %{to_string(ctx.bob.id) => %{metas: [%{status: "online"}]}},
          leaves: %{}
        }
      })

      assert has_element?(view, "#{slot} .ed-avatar__dot")
      refute has_element?(view, "#{slot} .ed-avatar__dot--away")

      # A meta update lands in the diff as a leave + join of the same key, so the
      # same re-stream gate catches a status-only change.
      EdenWeb.Presence.set_status(self(), ctx.bob.id, "away")

      send(view.pid, %Phoenix.Socket.Broadcast{
        event: "presence_diff",
        topic: EdenWeb.Presence.topic(),
        payload: %{
          joins: %{to_string(ctx.bob.id) => %{metas: [%{status: "away"}]}},
          leaves: %{to_string(ctx.bob.id) => %{metas: [%{status: "online"}]}}
        }
      })

      assert has_element?(view, "#{slot} .ed-avatar__dot--away")
    end

    test "a peer typing shows the indicator (not self), survives a stale expiry, clears on send (#11/#94)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      refute has_element?(view, ".ed-typing-row")

      # bob's own typing must never show to bob.
      render_change(view, "composer_changed", %{"message" => %{"body" => "hi"}})
      refute has_element?(view, ".ed-typing-row")

      # alice types → bob sees it live, with her name (strong label assertion).
      Chat.broadcast_typing(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert has_element?(view, ".ed-typing-row__label", "Alice is typing")

      # A superseded TTL timer (stale token) must NOT drop a current typer (P2-1).
      send(view.pid, {:typing_expired, :typing_users, ctx.alice.id, make_ref()})
      assert has_element?(view, ".ed-typing-row__label", "Alice is typing")

      # alice sends → bob's indicator clears at once (clear-on-send), no TTL wait.
      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "go"})

      refute has_element?(view, ".ed-typing-row")
    end

    test "multiple peers typing show a combined label; switching chats clears it (#11/#94)",
         ctx do
      carol = user_fixture(%{username: "carol_ty", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      Chat.broadcast_typing(Scope.for_user(ctx.alice), group.id)
      Chat.broadcast_typing(Scope.for_user(carol), group.id)
      assert has_element?(view, ".ed-typing-row__label", "are typing")

      # Switching conversations clears the typers (via unsubscribe → clear_typing).
      view |> element(~s(a[href="/app/c/#{ctx.conversation.id}"])) |> render_click()
      refute has_element?(view, ".ed-typing-row")
    end

    test "a malformed react payload is ignored, not a crash (#67)", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "x"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Missing "emoji" key (a crafted client) must not crash the LiveView.
      render_hook(view, "react", %{"id" => to_string(msg.id)})
      assert render(view) =~ "x"
      refute has_element?(view, ".ed-react")
    end

    test "a stale-client (or malformed) media_client_id payload never crashes (#95)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A client on cached pre-redesign JS still pushes the id on this event; the
      # server stashes a binary id (deploy-window compat) and ignores any other
      # shape — never a FunctionClauseError that kills the LiveView.
      render_hook(view, "media_client_id", %{"id" => "abc"})
      render_hook(view, "media_client_id", %{"id" => 123})
      render_hook(view, "media_client_id", %{})
      assert has_element?(view, "#composer")
    end

    test "a media send closes the overlay, stamps the album with the pushed client_id, clears (#95)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")
      assert has_element?(view, "[data-upload-preview]")

      # The hook captures the caption at submit and pushes it WITH media_sending{id}:
      # both ride the socket, so neither depends on @composer surviving the upload. The
      # overlay closes at once (normal composer returns) even though the entry is staged.
      render_hook(view, "media_sending", %{"id" => "cid-7", "caption" => "look"})
      refute has_element?(view, "[data-upload-preview]")
      assert has_element?(view, "#composer-body")
      # The attach affordance is NO LONGER gated during a send (#119): picking the next
      # batch is allowed and queues client-side. Serialization is kept on the shared upload
      # config (one batch consumed at a time), not by blocking the button (#95 invariant holds).
      refute has_element?(view, "#composer label.pointer-events-none")

      # Submit: the stashed {id, caption} stamps the album so its optimistic twin swaps
      # out by data-client-id and the caption becomes the album's body.
      render_submit(element(view, "#composer"))

      assert {:ok, [%{body: "look", client_id: "cid-7", attachments: [%{kind: "image"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      refute has_element?(view, "[data-upload-preview]")
    end

    test "Send as file (#122) stores the photo uncompressed and renders a document card", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      scope = Scope.for_user(ctx.alice)

      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "p.jpg", content: big_jpeg(2400, 1600), type: "image/jpeg"}
        ])

      render_upload(file, "p.jpg")
      # The "Send as file" button rides as_file:true on media_sending (the hook reads
      # e.submitter); the server stores the photo as-is and flags it.
      render_hook(view, "media_sending", %{"id" => "cid-asfile", "as_file" => true})
      render_submit(element(view, "#composer"))

      {:ok, msgs} = Chat.list_messages(scope, ctx.conversation.id)
      msg = Enum.find(msgs, &(&1.client_id == "cid-asfile"))
      assert %{attachments: [att]} = msg
      assert att.as_file and att.kind == "image"
      assert att.width == 2400 and att.height == 1600

      # A fresh mount renders the stored message as a downloadable document card with a
      # thumbnail (ed-file--photo), never an inline album tile.
      {:ok, _view2, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert html =~ "ed-file--photo"
      refute html =~ "ed-album__tile"
    end

    test "an extreme-aspect photo (>5:1) auto-renders as a file card, not inline", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      scope = Scope.for_user(ctx.alice)

      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A 1600×150 strip (aspect ~10.6:1, past the 5:1 cap) — sent NORMALLY, no "as file".
      file =
        file_input(view, "#composer", :attachment, [
          %{name: "strip.jpg", content: big_jpeg(1600, 150), type: "image/jpeg"}
        ])

      render_upload(file, "strip.jpg")
      render_hook(view, "media_sending", %{"id" => "cid-strip"})
      render_submit(element(view, "#composer"))

      {:ok, msgs} = Chat.list_messages(scope, ctx.conversation.id)
      msg = Enum.find(msgs, &(&1.client_id == "cid-strip"))
      assert %{attachments: [att]} = msg
      assert att.kind == "image" and att.width == 1600 and att.height == 150
      # The DB row is untouched (as_file stays false) — the strip→file decision is a render
      # concern (a future threshold change reflows old messages, no migration).
      refute att.as_file

      # Yet a fresh mount renders it as a downloadable document card, never an inline tile.
      {:ok, _view2, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert html =~ "ed-file--photo"
      refute html =~ "ed-album__tile"

      # Control: a normal-aspect photo (4:3) stays inline — no file card.
      file2 =
        file_input(view, "#composer", :attachment, [
          %{name: "wide.jpg", content: big_jpeg(800, 600), type: "image/jpeg"}
        ])

      render_upload(file2, "wide.jpg")
      render_hook(view, "media_sending", %{"id" => "cid-normal"})
      render_submit(element(view, "#composer"))

      {:ok, _v3, html2} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      {:ok, msgs2} = Chat.list_messages(scope, ctx.conversation.id)
      normal = Enum.find(msgs2, &(&1.client_id == "cid-normal"))
      assert [%{width: 800, height: 600}] = normal.attachments
      # Both image messages render, but only the strip became a file card (exactly one).
      assert length(String.split(html2, "ed-file--photo")) - 1 == 1
    end

    test "a file send stamps the file message with its own per-ref client_id (#149)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "one.txt", content: "first", type: "text/plain"}
        ])

      html = render_upload(file, "one.txt")

      # The staged file carries its upload ref in the tray; the hook mints a client_id
      # per file keyed by that ref and pushes them on media_sending (#149) — distinct
      # from media's single album id, so each file message swaps its own card. Here the
      # upload finished before media_sending, so the form-submit path sends it (fallback).
      assert [[_, ref]] = Regex.scan(~r/phx-value-ref="([^"]+)"/, html)

      render_hook(view, "media_sending", %{"caption" => "", "files" => %{ref => "file-cid-1"}})
      render_submit(element(view, "#composer"))

      assert {:ok, [%{client_id: "file-cid-1", attachments: [%{kind: "file"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
    end

    test "a file is sent the moment ITS upload finishes, not on the form submit (#149)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "one.txt", content: "first", type: "text/plain"}
        ])

      # Real-usage order: media_sending (the stash) lands BEFORE the upload finishes (the ref
      # is known at stage time), so the progress callback consumes + sends the file the instant
      # it's done — independently of any batch, with NO form submit. A fast doc swaps to its
      # real card without waiting for the slowest.
      [%{"ref" => ref}] = file.entries
      render_hook(view, "media_sending", %{"caption" => "", "files" => %{ref => "file-cid-1"}})

      render_upload(file, "one.txt")

      assert {:ok, [%{client_id: "file-cid-1", attachments: [%{kind: "file"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      # Regression (#149): the progress path — not send_attachment — finished this files-only
      # send, so it must clear sending_media; otherwise the attach button (gated on
      # @sending_media) stays disabled forever. The composer mirrors the flag in data-*.
      assert has_element?(view, ~s(#composer[data-sending-media="false"]))
    end

    test "the tray cancel (before send) keeps an active reply (#137 review)", ctx do
      {:ok, target} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "reply me"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Reply, then stage a file, then change your mind and remove it in the tray (no send).
      render_hook(view, "reply", %{"id" => to_string(target.id)})
      assert has_element?(view, "[data-reply-active]")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "doc.txt", content: "x", type: "text/plain"}
        ])

      [%{"ref" => ref}] = file.entries
      render_upload(file, "doc.txt")
      render_hook(view, "cancel_upload", %{"ref" => ref})

      # The reply must survive a tray cancel (only an in-flight cancel clears it); nothing sent.
      assert has_element?(view, "[data-reply-active]")
      assert has_element?(view, ~s(#composer[data-sending-media="false"]))
    end

    test "a partial-batch cancel leaves the paperclip live once the rest upload (#158)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      keep =
        file_input(view, "#composer", :attachment, [
          %{name: "keep.txt", content: "a", type: "text/plain"}
        ])

      # The cancelled file rides a SEPARATE file_input so aborting it mid-flight tears down
      # only its own client process, not the keeper's — big enough to actually hold at 40%
      # (a tiny file jumps to 100%, gets consumed+sent, and can't be cancelled).
      drop =
        file_input(view, "#composer", :attachment, [
          %{name: "drop.txt", content: String.duplicate("b", 100_000), type: "text/plain"}
        ])

      [keep_ref] = Enum.map(keep.entries, & &1["ref"])
      [drop_ref] = Enum.map(drop.entries, & &1["ref"])

      render_hook(view, "media_sending", %{
        "caption" => "",
        "files" => %{keep_ref => "fcid-1", drop_ref => "fcid-2"}
      })

      # Cancel one file mid-upload. Phoenix keeps it in `entries` as a `cancelled?` ghost
      # (it only drops when the upload channel dies, which for a mid-batch cancel can be
      # never). That ghost used to wedge the composer bar `inert` and swap the file input
      # out after the rest landed — leaving the paperclip dead (#158).
      render_upload(drop, "drop.txt", 40)
      render_hook(view, "cancel_upload", %{"ref" => drop_ref})

      # The keeper finishes via the per-file progress path.
      render_upload(keep, "keep.txt")

      # Only the kept file was sent; the cancelled one was not.
      assert {:ok, [%{attachments: [%{kind: "file"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      # Paperclip is live again: sending_media cleared AND the file input re-renders (the
      # lingering cancelled ghost must not keep it swapped out / the bar inert).
      assert has_element?(view, ~s(#composer[data-sending-media="false"]))
      assert has_element?(view, ~s(#composer input[type="file"]))
    end

    test "a mixed batch with a cancelled file still sends the rest, never wedges (#158)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      keep =
        file_input(view, "#composer", :attachment, [
          %{name: "keep.txt", content: "a", type: "text/plain"}
        ])

      # Separate file_input so the in-flight cancel tears down only its own process.
      drop =
        file_input(view, "#composer", :attachment, [
          %{name: "drop.txt", content: String.duplicate("b", 100_000), type: "text/plain"}
        ])

      [keep_ref] = Enum.map(keep.entries, & &1["ref"])
      [drop_ref] = Enum.map(drop.entries, & &1["ref"])

      # An album id present makes this a BATCH: the files defer to the form submit
      # (send_attachment), not the per-file progress path.
      render_hook(view, "media_sending", %{
        "id" => "album-x",
        "caption" => "",
        "files" => %{keep_ref => "fcid-1", drop_ref => "fcid-2"}
      })

      render_upload(drop, "drop.txt", 40)
      render_hook(view, "cancel_upload", %{"ref" => drop_ref})
      render_upload(keep, "keep.txt")

      # The batch submits with a `cancelled?` ghost still in `entries`: send_attachment must
      # consume only the DONE entry (not consume_uploaded_entries/3, which would raise) and
      # send it — instead of crashing or silently dropping the whole send (data loss) (#158).
      render_submit(element(view, "#composer"))

      assert {:ok, [%{attachments: [%{kind: "file"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      assert has_element?(view, ~s(#composer[data-sending-media="false"]))
      assert has_element?(view, ~s(#composer input[type="file"]))
    end

    test "a files-only caption rides as its own trailing message below the pile (#149)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "one.txt", content: "first", type: "text/plain"}
        ])

      [%{"ref" => ref}] = file.entries

      render_hook(view, "media_sending", %{
        "caption" => "below the pile",
        "files" => %{ref => "file-cid-1"},
        "caption_id" => "cap-cid-1"
      })

      render_upload(file, "one.txt")

      # The last file lands → the caption follows as its OWN message (its own client_id, no
      # attachment), ordered AFTER the file — not attached under the first file.
      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      assert [
               %{client_id: "file-cid-1", body: "", attachments: [%{kind: "file"}]},
               %{client_id: "cap-cid-1", body: "below the pile", attachments: []}
             ] = msgs
    end

    test "a file in a mixed (media+files) send waits for the batch, not progress (#149 review A)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "one.txt", content: "first", type: "text/plain"}
        ])

      [%{"ref" => ref}] = file.entries

      # A media album rides the same send (album id present). The file must NOT be sent the
      # moment it finishes — that would land it ABOVE the album (consumed only on the form
      # submit). So on completion nothing is sent yet; it waits for the batch.
      render_hook(view, "media_sending", %{"id" => "album-x", "files" => %{ref => "file-cid-1"}})
      render_upload(file, "one.txt")

      assert {:ok, []} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
    end

    test "the files-only fallback sends the caption trailing, not on the first file (#149 review C)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "one.txt", content: "first", type: "text/plain"}
        ])

      # Upload finishes BEFORE media_sending → the progress path can't claim it, so the
      # form-submit fallback sends it. The fallback must still place the caption as its own
      # trailing message (not on the file) so the optimistic caption node swaps, not orphans.
      render_upload(file, "one.txt")
      [%{"ref" => ref}] = file.entries

      render_hook(view, "media_sending", %{
        "caption" => "below the pile",
        "files" => %{ref => "file-cid-1"},
        "caption_id" => "cap-cid-1"
      })

      render_submit(element(view, "#composer"))

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      assert [
               %{client_id: "file-cid-1", body: "", attachments: [%{kind: "file"}]},
               %{client_id: "cap-cid-1", body: "below the pile", attachments: []}
             ] = msgs
    end

    test "a media caption survives a chat-input change during the upload (#bug)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")

      # The caption is captured at submit and stashed via media_sending (overlay closes).
      render_hook(view, "media_sending", %{"id" => "cidc", "caption" => "the caption"})

      # While the (slow) upload runs, the user types another message — a composer_changed
      # with no caption key. This must NOT drop the stashed caption (the bug: it used to
      # read @composer[:caption], which this change clobbered, losing the caption).
      view |> form("#composer", %{message: %{body: "typed during upload"}}) |> render_change()

      render_submit(element(view, "#composer"))

      assert {:ok, [%{body: "the caption", attachments: [%{kind: "image"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
    end

    test "an in-flight media send survives a conversation switch, landing in its original chat (#bug)",
         ctx do
      carol = user_fixture(%{username: "carol_pin", display_name: "Carol"})
      {:ok, conv_b} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")
      # Send pressed: the upload is in flight, pinned to conversation A.
      render_hook(view, "media_sending", %{"id" => "cid-pin", "caption" => "pinned"})

      # The user switches to conversation B mid-upload (a live patch — the LiveView,
      # and thus the upload, survives). The in-flight send must NOT be cancelled.
      render_patch(view, ~p"/app/c/#{conv_b.id}")

      # The upload completes; its send lands in the ORIGINAL conversation (A), not B.
      render_submit(element(view, "#composer"))

      assert {:ok, [%{body: "pinned", attachments: [%{kind: "image"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      assert {:ok, []} = Chat.list_messages(Scope.for_user(ctx.alice), conv_b.id)
    end

    test "staged (not-yet-sent) media is dropped on a conversation switch — no leak (#89)", ctx do
      carol = user_fixture(%{username: "carol_drop", display_name: "Carol"})
      {:ok, conv_b} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")
      assert has_element?(view, "[data-upload-preview]")

      # Still staged (no media_sending fired). Switching conversations drops it so it
      # can't ride into the new chat.
      render_patch(view, ~p"/app/c/#{conv_b.id}")
      refute has_element?(view, "[data-upload-preview]")

      assert {:ok, []} = Chat.list_messages(Scope.for_user(ctx.alice), conv_b.id)
    end

    test "the overlay caption is separate from the chat input — no mirroring", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png")
      assert has_element?(view, "#compose-caption")

      # Typing a caption in the overlay must NOT appear in the chat input — they are
      # separate fields (message[caption] vs message[body]).
      view |> form("#composer", %{message: %{caption: "a caption"}}) |> render_change()

      assert render(view) =~ "a caption"
      assert view |> element("#compose-caption") |> render() =~ "a caption"
      refute view |> element("#composer-body") |> render() =~ "a caption"
    end

    test "the stall-watchdog reset aborts the stuck send: entries cancelled + error, no re-show",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png", 20)
      render_hook(view, "media_sending", %{"id" => "cid-stall"})
      refute has_element?(view, "[data-upload-preview]")

      # The upload stalled (no real row, no error); the watchdog asks the server to abort.
      # It does NOT re-show the overlay (its live previews are gone after a switch, and the
      # still-staged entry would be silently dropped by the next switch): the entry is
      # cancelled and a failure flash is surfaced, so nothing lingers and the loss is visible.
      html = render_hook(view, "media_send_reset", %{})
      refute has_element?(view, "[data-upload-preview]")
      assert html =~ "didn&#39;t upload" or html =~ "didn't upload"

      # The abort must also clear sending_media (not just the entries), else the send state
      # wedges: a fresh stage would stay hidden. Prove it by staging again — the overlay,
      # gated on `not @sending_media`, returns.
      file2 =
        file_input(view, "#composer", :attachment, [
          %{name: "b.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file2, "b.png", 20)
      assert has_element?(view, "[data-upload-preview]")
    end

    test "a text send while a media upload is still in progress doesn't crash (P0)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "clip.mp4", content: File.read!(real_png_path()), type: "video/mp4"}
        ])

      # Upload only partway: the entry stays in progress (done? == false), as a slow
      # video does while the user keeps typing.
      render_upload(file, "clip.mp4", 30)
      render_hook(view, "media_sending", %{"id" => "cid-vid"})

      # A text message typed while the video still uploads rides the SendQueue hook's
      # "send" with its own client_id. It must NOT reach consume_uploaded_entries,
      # which raises on the in-progress entry — that crashed the LiveView, abandoning
      # the upload and dropping its optimistic node (the reported bug).
      render_hook(view, "send", %{"message" => %{"body" => "typed while uploading"}})

      # The process survived and the text landed as its own message; the in-progress
      # upload was left untouched (still staged, still uploading).
      assert Process.alive?(view.pid)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.body == "typed while uploading"))

      assert Enum.all?(msgs, &(&1.attachments == [])),
             "the in-progress upload must not be consumed"
    end

    test "a reaction from another user appears live (#67)", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "hi"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      {:ok, _} = Chat.toggle_reaction(Scope.for_user(ctx.bob), msg.id, "🎉")

      # Bob's reaction lands via broadcast; not highlighted as mine for alice.
      assert has_element?(view, ~s(.ed-react[phx-value-emoji="🎉"]))
      refute has_element?(view, ~s(.ed-react--mine[phx-value-emoji="🎉"]))
    end

    test "the menu's quick row reflects the viewer's personal set (#67)", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "hi"})

      # Alice customizes her quick row before opening the chat.
      {:ok, _} = Chat.set_quick_reactions(Scope.for_user(ctx.alice), ["🔥", "👀"])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert has_element?(
               view,
               ~s(#menu-#{msg.id} .ed-menu__reacts .ed-menu__react[phx-value-emoji="🔥"])
             )

      # A default that she dropped is no longer in the quick row (still in the grid).
      refute has_element?(
               view,
               ~s(#menu-#{msg.id} .ed-menu__reacts .ed-menu__react[phx-value-emoji="👍"])
             )
    end

    test "the active highlight follows the selected conversation", ctx do
      carol = user_fixture(%{username: "carol_hl", display_name: "Carol"})
      {:ok, conv2} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert has_element?(view, ~s(a[href="/app/c/#{ctx.conversation.id}"].ed-convo--active))
      refute has_element?(view, ~s(a[href="/app/c/#{conv2.id}"].ed-convo--active))

      view |> element(~s(a[href="/app/c/#{conv2.id}"])) |> render_click()

      assert has_element?(view, ~s(a[href="/app/c/#{conv2.id}"].ed-convo--active))
      refute has_element?(view, ~s(a[href="/app/c/#{ctx.conversation.id}"].ed-convo--active))
    end

    test "receives another member's message in realtime", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      {:ok, _m} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "ping from bob"
        })

      assert render(view) =~ "ping from bob"
    end

    test "a hook send creates the message and a same-client_id resend doesn't duplicate", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      cid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      params = %{"message" => %{"body" => "queued hi", "client_id" => cid}}

      render_hook(view, "send", params)
      assert render(view) =~ "queued hi"

      # My own message row carries data-client-id so the rise-in observer skips
      # it — the optimistic node already animated; the real swap is silent (no
      # "small to large" double-animation jerk).
      assert has_element?(view, ~s([data-client-id="#{cid}"]))

      # A resend after a reconnect carries the same client_id — no duplicate row.
      render_hook(view, "send", params)
      assert Eden.Repo.aggregate(Eden.Chat.Message, :count) == 1
    end

    test "ignores a malformed send payload without crashing", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "send", %{"oops" => true})
      assert render(view) =~ "composer"
    end

    test "renders a photo message as a linked image", ctx do
      {:ok, message} =
        Chat.create_attachment_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          path: real_png_path()
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ ~s(src="/files/#{hd(message.attachments).id}")
      assert html =~ ~s(href="/files/#{hd(message.attachments).id}")
    end

    test "renders a generic file as a download card with its name", ctx do
      path = write_tmp("just plain text, not an image")

      {:ok, message} =
        Chat.create_attachment_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          path: path,
          filename: "notes.txt"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert hd(message.attachments).kind == "file"
      assert html =~ "ed-file"
      assert html =~ "notes.txt"
      assert html =~ ~s(href="/files/#{hd(message.attachments).id}")
    end

    test "renders a video as an in-app player", ctx do
      path = write_tmp(<<0, 0, 0, 0x18>> <> "ftypisom" <> :binary.copy("0", 16))

      {:ok, message} =
        Chat.create_attachment_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          path: path,
          filename: "clip.mp4"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert hd(message.attachments).kind == "video"
      assert html =~ "<video"
      assert html =~ ~s(<source src="/files/#{hd(message.attachments).id}")
      assert html =~ "video/mp4"
    end

    test "swaps the full image for the thumbnail once it is ready", ctx do
      {:ok, message} =
        Chat.create_attachment_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{
          path: real_png_path()
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      refute render(view) =~ "/files/#{hd(message.attachments).id}/thumb"

      # Generating the thumbnail broadcasts on the conversation topic the view
      # is subscribed to, so the image source updates in place.
      :ok = Chat.generate_thumbnail(hd(message.attachments))
      assert render(view) =~ "/files/#{hd(message.attachments).id}/thumb"
    end

    test "renders a multi-photo album as a media grid (#58)", ctx do
      sources = [
        %{path: real_png_path(), filename: "1.png"},
        %{path: real_png_path(), filename: "2.png"},
        %{path: real_png_path(), filename: "3.png"}
      ]

      {:ok, message} =
        Chat.create_album_message(Scope.for_user(ctx.bob), ctx.conversation.id, sources, %{})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ "ed-album"
      # Each photo is a gallery tile pointing at its own file, sharing one gallery.
      for attachment <- message.attachments do
        assert has_element?(
                 view,
                 ~s([data-gallery="album-#{message.id}"][data-full="/files/#{attachment.id}"])
               )
      end

      # The colocated hook name must be REWRITTEN to its full module form — a
      # dynamic phx-hook value would ship ".Lightbox" raw ("unknown hook").
      assert html =~ ~s(phx-hook="EdenWeb.ChatLive.Lightbox")
      refute html =~ ~s(phx-hook=".Lightbox")
    end

    test "a video in an album tiles in the grid with a play badge (#58)", ctx do
      mp4 = <<0, 0, 0, 0x18>> <> "ftypisom" <> :binary.copy("0", 16)

      sources = [
        %{path: real_png_path(), filename: "1.png"},
        %{path: write_tmp(mp4), filename: "clip.mp4"}
      ]

      {:ok, message} =
        Chat.create_album_message(Scope.for_user(ctx.bob), ctx.conversation.id, sources, %{})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Both photo and video are grid tiles (not a stacked <video> player).
      assert html =~ "ed-album"
      assert html =~ "ed-album__play"
      refute html =~ "<video"

      for attachment <- message.attachments do
        assert has_element?(view, ~s(#att-#{attachment.id}))
      end
    end

    test "files send as separate messages, never inside an album (#58)", ctx do
      sources = [
        %{path: write_tmp("plain one"), filename: "a.txt"},
        %{path: write_tmp("plain two"), filename: "b.txt"}
      ]

      {:ok, messages} =
        Chat.create_attachments(Scope.for_user(ctx.bob), ctx.conversation.id, sources, %{})

      # Two files -> two standalone single-attachment messages, no album grid.
      assert length(messages) == 2
      assert Enum.all?(messages, fn m -> length(m.attachments) == 1 end)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      refute html =~ "ed-album"
      assert html =~ "a.txt"
      assert html =~ "b.txt"
    end
  end

  describe "viewing a profile" do
    setup [:setup_conversation]

    test "the 1:1 header opens the conversation profile panel (#136)", ctx do
      {:ok, _bob} =
        Eden.Accounts.update_profile(ctx.bob, %{display_name: "Bob", bio: "Likes tea."})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      html = view |> element(~s(button[phx-click="open_profile"])) |> render_click()

      # The expanded panel (#136): the peer's card + the per-dialog media gallery tabs.
      assert html =~ "@bob"
      assert html =~ "Likes tea."
      assert has_element?(view, ".ed-profile")
      assert has_element?(view, ~s(.ed-gallery-tab[phx-value-tab="image"]))
      refute has_element?(view, ".ed-popover")
    end

    test "the profile panel loads the gallery and switches tabs (#136)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)

      {:ok, _} =
        Chat.create_attachments(Scope.for_user(ctx.alice), ctx.conversation.id, [
          %{path: real_png_path(), filename: "p.png"}
        ])

      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      render_click(view, "open_profile", %{})

      # Default tab = Photo → the image tile shows; no empty state.
      assert has_element?(view, ".ed-gallery-grid .ed-gallery-tile")
      refute has_element?(view, ".ed-gallery-empty")

      # Switch to Files → no files in this chat → the empty state, no photo grid.
      render_click(view, "gallery_tab", %{"tab" => "file"})
      assert has_element?(view, ".ed-gallery-empty")
      refute has_element?(view, ".ed-gallery-grid")

      # A crafted/unknown tab is ignored (no crash).
      render_click(view, "gallery_tab", %{"tab" => "evil"})
      assert has_element?(view, ".ed-profile")
    end

    test "open_profile derives the peer from the open chat, ignoring any sent id (#136 P2-A)",
         ctx do
      other = user_fixture(%{username: "mallory", display_name: "Mallory"})
      {:ok, _shared_elsewhere} = Chat.create_conversation(Scope.for_user(ctx.alice), [other.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A crafted id for someone shared via ANOTHER chat must NOT spoof this chat's card.
      render_click(view, "open_profile", %{"id" => to_string(other.id)})
      html = render(view)
      assert html =~ "@#{ctx.bob.username}"
      refute html =~ "mallory"
    end

    test "the gallery paginates with Load more (#136 P2-B)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)

      for n <- 1..31 do
        {:ok, _} =
          Chat.create_attachments(Scope.for_user(ctx.alice), ctx.conversation.id, [
            %{path: real_png_path(), filename: "p#{n}.png"}
          ])
      end

      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      render_click(view, "open_profile", %{})

      tiles = fn -> render(view) |> then(&length(Regex.scan(~r/ed-gallery-tile/, &1))) end
      assert tiles.() == 30
      assert has_element?(view, ".ed-gallery-more")

      render_click(view, "gallery_more", %{})
      assert tiles.() == 31
      refute has_element?(view, ".ed-gallery-more")
    end

    test "the gallery surfaces new media live (#136 P2-C)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      render_click(view, "open_profile", %{})
      assert has_element?(view, ".ed-gallery-empty")

      # Bob sends a photo → the {:new_message} broadcast reaches alice's open panel.
      {:ok, _} =
        Chat.create_attachments(Scope.for_user(ctx.bob), ctx.conversation.id, [
          %{path: real_png_path(), filename: "live.png"}
        ])

      assert render(view) =~ "ed-gallery-tile"
      refute has_element?(view, ".ed-gallery-empty")
    end

    test "your own card shows Edit profile, not a Message button", ctx do
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      render_click(view, "show_profile", %{"id" => to_string(ctx.alice.id)})
      assert has_element?(view, ".ed-popover")
      assert has_element?(view, ~s(.ed-popover a[href="/settings"]))
      refute has_element?(view, ~s(.ed-popover button[phx-click="message_user"]))
    end

    test "a profile you don't share a conversation with is unavailable", ctx do
      dave = user_fixture(%{username: "dave"})
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      html = render_click(view, "show_profile", %{"id" => to_string(dave.id)})
      assert html =~ "Profile unavailable."
    end

    test "a group header opens the panel with members + gallery, then a member's profile (#136)",
         ctx do
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      panel = view |> element(~s(button[phx-click="open_profile"])) |> render_click()
      assert has_element?(view, ".ed-profile")
      assert panel =~ "Carol"
      assert panel =~ "(you)"
      # The group gallery is wired (per-dialog shared media).
      assert has_element?(view, ~s(.ed-gallery-tab[phx-value-tab="image"]))

      # Tapping a member opens their profile popover over the panel. (#165 split the row
      # into a profile button + a role-action cluster, so the trigger is `__main`.)
      profile =
        view
        |> element(~s(.ed-member-row__main[phx-value-id="#{carol.id}"]))
        |> render_click()

      assert profile =~ "@carol"
      assert has_element?(view, ".ed-popover")
    end

    test "Message from a profile opens a 1:1", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_click(view, "show_profile", %{"id" => to_string(ctx.bob.id)})
      render_click(view, "message_user", %{"id" => to_string(ctx.bob.id)})

      # Alice and Bob already share a 1:1, so it is reused.
      assert_patch(view, ~p"/app/c/#{ctx.conversation.id}")
    end

    test "the profile popover opens from a room message and Message bridges to a DM", ctx do
      {:ok, channel} = Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Org"})

      {:ok, _} =
        %Eden.Channels.Membership{}
        |> Eden.Channels.Membership.changeset(%{
          channel_id: channel.id,
          user_id: ctx.bob.id,
          role: "member"
        })
        |> Eden.Repo.insert()

      :ok = Chat.join_general(channel.id, ctx.bob.id)
      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, _} = Chat.create_message(Scope.for_user(ctx.bob), room.id, %{"body" => "hi from bob"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # Avatar/name are profile triggers in the flat row.
      assert has_element?(view, ~s(.ed-flat__avatar-btn[phx-value-id="#{ctx.bob.id}"]))
      render_click(view, "show_profile", %{"id" => to_string(ctx.bob.id)})
      assert has_element?(view, ".ed-popover")

      # Message bridges out of the channel into a DM (a full navigate, not patch).
      render_click(view, "message_user", %{"id" => to_string(ctx.bob.id)})
      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/app/c/\d+$}
    end

    test "a member's name change updates the open conversation without reload", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert render(view) =~ "Bob"

      # Bob renames himself elsewhere; the broadcast refreshes Alice's open view.
      {:ok, _bob} = Eden.Accounts.update_profile(ctx.bob, %{display_name: "Bobby Tables"})

      assert render(view) =~ "Bobby Tables"
    end
  end

  describe "message actions" do
    setup [:setup_conversation]

    test "renders the action menu; delete-for-everyone only on own messages", ctx do
      {:ok, mine} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "mine"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert html =~ "Copy text"
      assert html =~ "Copy link"
      assert html =~ "Forward"
      assert html =~ "Delete for me"
      assert html =~ "Delete for everyone"
      assert html =~ ~s(/app/c/#{ctx.conversation.id}/m/#{mine.id})
    end

    test "delete for me hides it from this user", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "hush"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert html =~ "hush"

      render_click(view, "delete_for_me", %{"id" => to_string(msg.id)})
      refute has_element?(view, "#messages-#{msg.id}")
    end

    test "delete for both removes the message for everyone in real time", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "regret"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_click(view, "delete_for_both", %{"id" => to_string(msg.id)})
      refute has_element?(view, "#messages-#{msg.id}")
    end

    test "a deleted-for-both message is not shown", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "gone"})

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), msg.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      refute html =~ "gone"
    end

    test "carry-and-drop forward copies the message into the open conversation", ctx do
      carol = user_fixture(%{username: "carolfwd"})
      {:ok, target} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{
          "body" => "share me"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      # Open the DESTINATION, then carry the message from the other conversation.
      {:ok, view, _html} = live(conn, ~p"/app/c/#{target.id}")

      render_click(view, "forward_prompt", %{"id" => to_string(msg.id)})
      assert render(view) =~ "Forwarding"

      # Send drops the carried message into the open conversation.
      render_submit(view, "send", %{"message" => %{"body" => ""}})

      {:ok, [forwarded]} = Chat.list_messages(Scope.for_user(ctx.alice), target.id)
      assert forwarded.body == "share me"
      assert forwarded.forwarded_from_id == msg.id
    end

    test "a permalink opens the conversation", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "anchor"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}/m/#{msg.id}")
      assert html =~ "anchor"
    end
  end

  describe "delete chat" do
    setup [:setup_conversation]

    test "the sidebar offers a delete-chat action", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")
      assert html =~ "Delete chat"
    end

    test "deleting drops the chat from the sidebar and leaves the open thread", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert has_element?(view, "#conversations-#{ctx.conversation.id}")

      render_click(view, "delete_chat", %{"id" => to_string(ctx.conversation.id)})

      refute has_element?(view, "#conversations-#{ctx.conversation.id}")
      assert_patch(view, ~p"/app")
      refute has_element?(view, "#composer")
    end

    test "the chat stays for the other member", ctx do
      :ok = Chat.delete_conversation(Scope.for_user(ctx.alice), ctx.conversation.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      {:ok, _view, html} = live(conn, ~p"/app")
      assert html =~ "Alice"
    end

    test "a new message re-surfaces a deleted 1:1", ctx do
      :ok = Chat.delete_conversation(Scope.for_user(ctx.alice), ctx.conversation.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      refute has_element?(view, "#conversations-#{ctx.conversation.id}")

      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "back"})

      assert has_element?(view, "#conversations-#{ctx.conversation.id}")
    end
  end

  describe "threads" do
    setup [:setup_conversation]

    test "the DM messenger has no thread affordance (#26 — rooms only)", ctx do
      {:ok, root} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "root"})

      # Replies are refused server-side in a DM/group conversation.
      assert {:error, :not_found} =
               Chat.create_reply(Scope.for_user(ctx.bob), root.id, %{"body" => "nope"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      refute html =~ "ed-bubble__thread"
      refute html =~ "ed-thread-footer"
      refute has_element?(view, ~s(button[phx-click="open_thread"]))
      # Opening a thread on a DM root is rejected (no panel).
      render_click(view, "open_thread", %{"id" => to_string(root.id)})
      refute has_element?(view, ".ed-thread")
    end

    test "rooms render the flat Mattermost layout with compact runs and a facepile", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Flat"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      scope = Scope.for_user(ctx.alice)
      {:ok, r1} = Chat.create_message(scope, room.id, %{"body" => "first in run"})
      {:ok, _r2} = Chat.create_message(scope, room.id, %{"body" => "second in run"})
      {:ok, _} = Chat.create_reply(scope, r1.id, %{"body" => "threaded"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # Flat rows, not bubbles; the second message of the run is compact.
      assert html =~ "ed-flat"
      refute html =~ "ed-bubble--me"
      assert has_element?(view, ".ed-flat--compact")

      # Thread footer with facepile on the root.
      assert has_element?(view, ".ed-thread-footer")
      assert has_element?(view, ".ed-facepile")

      view |> element(".ed-thread-footer") |> render_click()
      assert render(view) =~ "threaded"

      # The composer advertises the room layout so the SendQueue hook renders
      # a flat optimistic node, not a DM bubble (regression for the flash bug).
      assert has_element?(view, ~s(#composer[data-layout="flat"]))
    end

    test "a room with no messages renders an empty-state (#154)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Fresh"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # The general room is born empty → the empty-state element is present (CSS `only:block`
      # reveals it while #messages is childless) and there are no message rows.
      assert has_element?(view, "#messages-empty .ed-room-empty__title", "No messages yet")
      refute has_element?(view, "#messages .ed-flat")

      # Posting clears it: a row now exists alongside the (now-hidden) placeholder.
      {:ok, _} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "hello"})
      assert render(view) =~ "hello"
      assert has_element?(view, "#messages .ed-flat")
    end

    test "a peer's read does not un-collapse the sender's compact room run (#155)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Flat"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      :ok = Chat.join_general(channel.id, ctx.bob.id)
      scope = Scope.for_user(ctx.alice)
      {:ok, _r1} = Chat.create_message(scope, room.id, %{"body" => "first in run"})
      {:ok, _r2} = Chat.create_message(scope, room.id, %{"body" => "second in run"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # The run collapses on first render (the second message drops its author header).
      assert has_element?(view, ".ed-flat--compact")

      # Bob reads the room → broadcasts {:read, bob.id, _}. Read receipts are DM-only,
      # so the room view must NOT re-stream the raw list: doing so would drop the
      # virtual `compact` flag and bring every collapsed author header back on the
      # sender's screen (#155).
      :ok = Chat.mark_read(Scope.for_user(ctx.bob), room.id)
      _ = render(view)

      assert has_element?(view, ".ed-flat--compact")
    end

    test "jumping to an in-room search result closes the search panel", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Search"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)

      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "findme needle"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # Open the in-room search and type a query that matches the message.
      view |> element("[phx-click=toggle_room_search]") |> render_click()
      html = view |> form(~s(form[phx-change="room_search"]), %{q: "needle"}) |> render_change()
      assert html =~ "ed-room-search__panel"

      # Clicking a result jumps to /m/ — the panel and bar must close (was: stayed open
      # because the same-room jump short-circuits select_conversation's search reset).
      html = render_patch(view, ~p"/channels/#{channel.id}/r/#{room.id}/m/#{msg.id}")
      refute html =~ "ed-room-search__panel"
    end

    test "room message author avatars carry a presence status dot (#102)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "FlatStatus"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, _m} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "hi room"})

      # alice is away → her LiveView tracks her as away on mount, so her own flat
      # message avatar shows the away ring. The bug: rooms showed no status at all.
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "away")

      conn = log_in_user(ctx.conn, alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      assert has_element?(view, ".ed-flat .ed-avatar__dot--away")
    end

    test "the room presence map is scoped to members, not the global online set (#102)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ScopeCh"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)

      # An online user who is NOT a member of this room.
      outsider = user_fixture(%{username: "outsider_sc", display_name: "Out"})
      {:ok, _ref} = EdenWeb.Presence.track_user(self(), outsider.id, "online")
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "away")

      conn = log_in_user(ctx.conn, alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # data-statuses is HTML-escaped JSON; each id appears as a quoted key
      # (&quot;<id>&quot;), so the surrounding quotes make the match exact.
      html = view |> element("#room-presence") |> render()

      # The member's status is exposed; the outsider's is not (no cross-room leak).
      assert html =~ ~s(&quot;#{alice.id}&quot;)
      refute html =~ ~s(&quot;#{outsider.id}&quot;)
    end

    test "thread replies collapse consecutive same-author runs in the panel (#105)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Threads105"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      scope = Scope.for_user(ctx.alice)
      {:ok, root} = Chat.create_message(scope, room.id, %{"body" => "root"})
      {:ok, _r1} = Chat.create_reply(scope, root.id, %{"body" => "reply one"})
      {:ok, _r2} = Chat.create_reply(scope, root.id, %{"body" => "reply two"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # The second same-author reply is compact (no repeated avatar/name). The bug
      # was that the thread panel never computed compacting, so every reply showed
      # its avatar + name.
      assert has_element?(view, "#thread-replies .ed-flat--compact")
    end

    test "typing in a thread shows only the thread indicator; room typing stays out (#103)",
         ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrTyping"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # A peer typing IN this thread (root_id set) → the thread panel's indicator.
      Chat.broadcast_typing(Scope.for_user(ctx.bob), room.id, root.id)
      assert has_element?(view, ".ed-thread .ed-typing-row__label", ctx.bob.display_name)

      # A peer typing in the ROOM (root_id nil) must NOT leak into the thread indicator.
      carol = user_fixture(%{username: "carol_thr", display_name: "Carol"})
      Chat.broadcast_typing(Scope.for_user(carol), room.id)
      refute has_element?(view, ".ed-thread .ed-typing-row__label", "Carol")
      assert has_element?(view, ".ed-thread .ed-typing-row__label", ctx.bob.display_name)

      # Closing the thread clears its typers — and proves the thread typer never leaked
      # into the ROOM map (else Bob would surface in the room indicator now; Carol, who
      # typed in the room, still does).
      render_click(view, "close_thread", %{})
      refute has_element?(view, ".ed-thread")
      refute has_element?(view, ".ed-typing-row__label", ctx.bob.display_name)
      assert has_element?(view, ".ed-typing-row__label", "Carol")
    end

    test "a thread typer's TTL expiry drops them (token match) (#103)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrTtl"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      Chat.broadcast_typing(Scope.for_user(ctx.bob), room.id, root.id)
      assert has_element?(view, ".ed-thread .ed-typing-row__label", ctx.bob.display_name)

      # A stale-token expiry must NOT drop the current thread typer (#94 race guard).
      send(view.pid, {:typing_expired, :thread_typing_users, ctx.bob.id, make_ref()})
      assert has_element?(view, ".ed-thread .ed-typing-row__label", ctx.bob.display_name)
    end

    test "attach media in a thread reply: stages a tray, sends as an album (#104)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrMedia"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # The thread composer offers an attach control.
      assert has_element?(view, ~s(#reply-composer input[type="file"]))

      # Stage a photo → the thread tray appears.
      file =
        file_input(view, "#reply-composer", :thread_attachment, [
          %{name: "t.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "t.png")
      assert has_element?(view, ".ed-thread-tray")

      # Submit with an empty caption (the album is the content) → it sends as a thread
      # reply with an attachment, and the staging tray clears.
      view |> form("#reply-composer", reply: %{body: ""}) |> render_submit()
      refute has_element?(view, ".ed-thread-tray")
      assert has_element?(view, "#thread-replies img")
    end

    test "a thread reply carries its client_id — enables the failed-! flag (#142 PR-2)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrCid"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # The .ThreadSendQueue hook sends a text reply over the socket with a client_id;
      # it must ride through to the persisted reply (correlates the real row with the
      # optimistic failed node so the riser can swap/dedupe it).
      render_hook(view, "send_reply", %{
        "reply" => %{"body" => "hi thread", "client_id" => "trc-1"}
      })

      assert {:ok, _root, replies} = Chat.list_thread(Scope.for_user(ctx.alice), root.id)
      assert Enum.any?(replies, &(&1.body == "hi thread" and &1.client_id == "trc-1"))
    end

    test "a send_reply while a thread attachment is still uploading doesn't crash (P0)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrRace"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      file =
        file_input(view, "#reply-composer", :thread_attachment, [
          %{name: "t.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      # Stage but leave in progress (done? == false), then a (crafted) send_reply
      # arrives. It must NOT reach consume_uploaded_entries — that raises on the
      # in-progress entry and crashes the LiveView.
      render_upload(file, "t.png", 30)
      render_hook(view, "send_reply", %{"reply" => %{"body" => "early"}})

      assert Process.alive?(view.pid)
      # The reply landed as text; the in-progress upload wasn't consumed.
      assert {:ok, _root, replies} = Chat.list_thread(Scope.for_user(ctx.alice), root.id)
      assert Enum.any?(replies, &(&1.body == "early"))
      assert Enum.all?(replies, &(&1.attachments == []))
    end

    test "a thread reply's ready thumbnail updates the thread, never the main stream (#104)",
         ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThrThumb"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      scope = Scope.for_user(ctx.alice)
      {:ok, root} = Chat.create_message(scope, room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # An album reply lands in the thread (the {:thread_reply} broadcast streams it in).
      {:ok, reply} =
        Chat.create_album_reply(
          scope,
          root.id,
          [%{path: real_png_path(), filename: "t.png"}],
          %{}
        )

      render(view)
      assert has_element?(view, "#thread-#{reply.id}")
      refute has_element?(view, "#messages-#{reply.id}")

      # The async thumbnail finishes and re-broadcasts the message. It MUST update the
      # thread row in place — never leak the reply into the room's main stream (the
      # bug: {:thumbnail_ready} stream_insert'd every message into :messages).
      send(view.pid, {:thumbnail_ready, reply})
      render(view)
      refute has_element?(view, "#messages-#{reply.id}")
      assert has_element?(view, "#thread-#{reply.id}")
    end

    test "paginating older messages keeps the compact run + stitches the seam (#105)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Page105"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      scope = Scope.for_user(ctx.alice)
      # > @page (50) same-author messages, so there's an older page to load.
      msgs =
        Enum.map(1..52, fn i ->
          {:ok, m} = Chat.create_message(scope, room.id, %{"body" => "m#{i}"})
          m
        end)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # The initial page is the newest 50; the oldest two aren't loaded yet.
      refute has_element?(view, "#messages-#{Enum.at(msgs, 0).id}")
      render_click(view, "load_more", %{})

      # The paged-in batch is compacted (the 2nd-oldest continues the run) — the bug
      # was streaming the older page raw, so a whole batch re-showed avatar+name.
      assert has_element?(view, "#messages-#{Enum.at(msgs, 1).id}.ed-flat--compact")
      # And the seam message (the previous on-screen top) now continues the older run.
      assert has_element?(view, "#messages-#{Enum.at(msgs, 2).id}.ed-flat--compact")
    end

    test "the composer advertises the bubble layout in DMs", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert has_element?(view, ~s(#composer[data-layout="bubble"]))
    end

    test "following (#57): footer 'new' badge, Threads list, follow toggle", ctx do
      {:ok, channel} = Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Crt"})
      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      :ok = Chat.join_room(room.id, ctx.bob.id)
      ascope = Scope.for_user(ctx.alice)
      {:ok, root} = Chat.create_message(ascope, room.id, %{"body" => "the root"})
      # bob replies → alice (root author) is auto-followed with one unread.
      {:ok, _} = Chat.create_reply(Scope.for_user(ctx.bob), root.id, %{"body" => "a reply"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # The footer shows the per-thread unread; the toolbar carries the count.
      assert has_element?(view, ".ed-thread-footer__new", "1")
      assert has_element?(view, ".ed-thread-badge", "1")

      # The Threads list lists the followed thread.
      view |> element(~s(button[phx-click="open_threads"])) |> render_click()
      assert has_element?(view, ".ed-thread-row")

      # Opening the thread reads it: bell shows Following, the unread clears.
      view |> element(".ed-thread-row") |> render_click()
      assert has_element?(view, ~s(button[phx-click="toggle_follow_thread"][aria-pressed="true"]))
      assert %{following: true, unread: 0} = Chat.thread_follow_state(ascope, root.id)
      refute has_element?(view, ".ed-thread-footer__new")

      # Unfollow via the bell.
      view |> element(~s(button[phx-click="toggle_follow_thread"])) |> render_click()

      assert has_element?(
               view,
               ~s(button[phx-click="toggle_follow_thread"][aria-pressed="false"])
             )

      assert %{following: false} = Chat.thread_follow_state(ascope, root.id)
    end

    test "following (#57): the badge appears live when another user replies", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Live"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      :ok = Chat.join_room(room.id, ctx.bob.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      # alice opened before any reply — not yet a follower, no badge.
      refute has_element?(view, ".ed-thread-footer__new")

      # bob replies → alice is auto-followed (root author); the badge must appear
      # live (regression: the local map had no key for a mid-session auto-follow).
      {:ok, _} = Chat.create_reply(Scope.for_user(ctx.bob), root.id, %{"body" => "ping"})
      assert has_element?(view, ".ed-thread-footer__new", "1")
      assert has_element?(view, ".ed-thread-badge", "1")
    end
  end

  describe "channel mode (#81)" do
    setup [:setup_conversation]

    test "the rail links a channel to its last-opened room", ctx do
      {:ok, channel} = Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Crt"})

      {:ok, ops} =
        Eden.Channels.create_room(Scope.for_user(ctx.alice), channel.id, %{"name" => "ops"})

      conn = log_in_user(ctx.conn, ctx.alice)
      # Open the ops room — this records it as the channel's last room.
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{ops.id}")

      # The rail's channel button now navigates straight to ops, not the bare
      # channel (which would show the "pick a room" empty state).
      assert has_element?(view, ~s(a.ed-rail__btn[href="/channels/#{channel.id}/r/#{ops.id}"]))

      entry =
        Scope.for_user(ctx.alice)
        |> Eden.Channels.list_channels()
        |> Enum.find(&(&1.id == channel.id))
        |> then(& &1.entry_room_id)

      assert entry == ops.id
    end
  end

  describe "search" do
    setup [:setup_conversation]

    test "shows grouped results with highlight; clear restores the list", ctx do
      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "let's plan the picnic"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "picnic"})
      assert html =~ "Messages"
      assert html =~ ~s(<mark class="ed-mark">picnic</mark>)

      html = render_change(view, "search", %{"q" => "Bob"})
      assert html =~ "Chats"
      assert html =~ ~s(<mark class="ed-mark">Bob</mark>)

      html = render_click(view, "clear_search", %{})
      refute html =~ "ed-search__group"
      assert has_element?(view, "#conversations-#{ctx.conversation.id}")
    end

    test "a message result links to its permalink", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "remember the anchor point"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "anchor"})
      assert html =~ ~s(href="/app/c/#{ctx.conversation.id}/m/#{msg.id}")
    end

    test "shows the no-results state", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "zzznothing"})
      assert html =~ "No results for"
    end

    test "a too-short query shows a hint, not a false no-results", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "a"})
      assert html =~ "Type at least"
      refute html =~ "No results for"
    end

    test "a mid-word highlight stays glued to the rest of the word", ctx do
      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" => "Свет на озере был нереальный"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "озе"})
      # No whitespace may separate the mark from its word ("озе ре" bug).
      assert html =~ ~s(<mark class="ed-mark">озе</mark>ре)
    end

    test "group message results show the sender", ctx do
      carol = user_fixture(%{username: "carolgrp", display_name: "Carol"})

      {:ok, group} =
        Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id], title: "Trip")

      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), group.id, %{"body" => "bonfire tonight"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_change(view, "search", %{"q" => "bonfire"})
      assert html =~ "Bob"
    end
  end

  describe "folders" do
    setup [:setup_conversation]

    test "no folder tabs until the user has a folder", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")
      refute html =~ "All Chats"

      {:ok, _} = Chat.create_folder(Scope.for_user(ctx.alice), %{"name" => "Work"})
      # The tab bar appears for new sessions once a folder exists.
      {:ok, _view2, html2} = live(conn, ~p"/app")
      assert html2 =~ "All Chats"
      assert html2 =~ "Work"
    end

    test "selecting a folder filters the list", ctx do
      scope = Scope.for_user(ctx.alice)
      carol = user_fixture(%{username: "carolfold"})
      {:ok, other} = Chat.create_conversation(scope, [carol.id])
      {:ok, folder} = Chat.create_folder(scope, %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope, ctx.conversation.id, folder.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")
      assert has_element?(view, "#conversations-#{other.id}")

      render_click(view, "select_folder", %{"id" => to_string(folder.id)})
      assert has_element?(view, "#conversations-#{ctx.conversation.id}")
      refute has_element?(view, "#conversations-#{other.id}")

      render_click(view, "select_folder", %{"id" => ""})
      assert has_element?(view, "#conversations-#{other.id}")
    end

    test "an empty folder shows the folder empty state, not the global one", ctx do
      scope = Scope.for_user(ctx.alice)
      {:ok, folder} = Chat.create_folder(scope, %{"name" => "Empty"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html = render_click(view, "select_folder", %{"id" => to_string(folder.id)})
      assert html =~ "No chats in this folder"
    end

    test "the All Chats tab renders at its stored position", ctx do
      scope = Scope.for_user(ctx.alice)
      {:ok, work} = Chat.create_folder(scope, %{"name" => "Work"})
      :ok = Chat.reorder_folders(scope, [to_string(work.id), "all"])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")

      # Work's tab comes before the All Chats tab in the carousel.
      [nav] = Regex.run(~r/<nav [^>]*class="ed-folders".*?<\/nav>/s, html)
      assert [work_at, all_at] = [:binary.match(nav, "Work"), :binary.match(nav, "All Chats")]
      assert elem(work_at, 0) < elem(all_at, 0)
    end

    test "mute toggles from the chat menu and de-emphasizes the badge", ctx do
      scope = Scope.for_user(ctx.alice)

      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "hi"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      menu = view |> element("#convo-menu-#{ctx.conversation.id}") |> render()
      assert menu =~ "Mute"
      refute menu =~ "Unmute"
      refute render(view) =~ "ed-badge--muted"

      render_click(view, "toggle_mute", %{"id" => to_string(ctx.conversation.id)})

      assert view |> element("#convo-menu-#{ctx.conversation.id}") |> render() =~ "Unmute"
      assert render(view) =~ "ed-badge--muted"
      assert [%{muted: true}] = Chat.list_conversations(scope)
    end

    test "folder mute toggles from the tab menu and suppresses its badge", ctx do
      scope = Scope.for_user(ctx.alice)
      {:ok, folder} = Chat.create_folder(scope, %{"name" => "Work"})
      {:ok, :added} = Chat.toggle_conversation_folder(scope, ctx.conversation.id, folder.id)

      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{"body" => "hi"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app")
      assert html =~ "Mute folder"
      assert html =~ "ed-folder-tab__badge"

      render_click(view, "toggle_folder_mute", %{"id" => to_string(folder.id)})
      html = render(view)
      assert html =~ "Unmute folder"
      refute html =~ "ed-folder-tab__badge"
    end

    test "move-to-folder modal toggles membership", ctx do
      scope = Scope.for_user(ctx.alice)
      {:ok, folder} = Chat.create_folder(scope, %{"name" => "Work"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      render_click(view, "move_to_folder_prompt", %{"id" => to_string(ctx.conversation.id)})
      assert render(view) =~ "Move to folder"

      render_click(view, "toggle_folder", %{"folder" => to_string(folder.id)})
      assert [folder.id] == Chat.conversation_folder_ids(scope, ctx.conversation.id)

      render_click(view, "toggle_folder", %{"folder" => to_string(folder.id)})
      assert [] == Chat.conversation_folder_ids(scope, ctx.conversation.id)
    end
  end

  # A complete {:notify} payload (the shape Chat.notify_payload/1 broadcasts), so the
  # web layer's notify_event/1 — which reads sender_id/avatar_key/media_kind — doesn't
  # KeyError on a hand-built stub. Override only the fields a test cares about.
  defp notify_payload(attrs) do
    Map.merge(
      %{
        conversation_id: 0,
        message_id: 1,
        root_id: nil,
        channel_id: nil,
        kind: "dm",
        conv_title: nil,
        sender_id: 0,
        sender_name: "Someone",
        avatar_key: nil,
        preview: "",
        media_kind: nil
      },
      attrs
    )
  end

  describe "notification push (#213)" do
    alias Eden.Accounts.Scope
    alias Eden.Channels

    setup [:setup_conversation]

    test "pushes a 'notify' for another chat; suppresses it for the focused chat", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A notification for a DIFFERENT chat → handed to the client renderers.
      send(view.pid, {:notify, notify_payload(%{conversation_id: 999, preview: "hi"})})
      assert_push_event(view, "notify", %{conversation_id: 999})

      # The OPEN, focused chat → suppressed (you're already looking at it).
      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: ctx.conversation.id, preview: "yo"})}
      )

      render(view)
      refute_push_event(view, "notify", %{})
    end

    test "delivers a room notification — channel-mute is filtered server-side now (#271)", ctx do
      {:ok, ch} = Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Team"})
      {:ok, [room]} = Channels.list_rooms(Scope.for_user(ctx.alice), ch.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # The web layer no longer gates on channel-mute — a muted channel's recipients are
      # already dropped in Chat.notify_recipient_ids, so whatever reaches here delivers.
      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: room.id, channel_id: ch.id, preview: "x"})}
      )

      assert_push_event(view, "notify", %{conversation_id: conv_id})
      assert conv_id == room.id
    end

    test "strips markdown markers from the banner body (#273)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: 42, preview: "**bold** and `code`"})}
      )

      assert_push_event(view, "notify", %{body: body})
      refute body =~ "**"
      refute body =~ "`"
      assert body =~ "bold"
    end

    test "strips before fitting, so a long token can't leave a dangling marker (#279 review)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # A bold span longer than the banner cut: stripping BEFORE the 140-char fit removes
      # both markers, so no dangling "**" survives (the old truncate-then-strip would).
      bold = "**" <> String.duplicate("x", 200) <> "**"
      send(view.pid, {:notify, notify_payload(%{conversation_id: 42, preview: bold})})

      assert_push_event(view, "notify", %{body: body})
      refute body =~ "*"
      assert String.length(body) <= 140
    end
  end

  describe "crash-hardening: events/routing from the wrong context (#259, #260)" do
    test "channel/group handlers no-op in DM mode instead of crashing the process (#259)", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture())
      # /app with nothing selected: @channel and @selected are nil.
      {:ok, view, _html} = live(conn, ~p"/app")

      for event <-
            ~w(open_channel_members open_channel_edit open_new_room open_add_members open_threads) do
        assert render_click(view, event, %{})
      end

      assert render_click(view, "group_remove_member", %{"id" => "1"})
      assert Process.alive?(view.pid)
    end

    test "a {:new_message} for a conversation that isn't open is ignored (#260)", %{conn: conn} do
      alice = user_fixture(%{username: "route_alice"})
      bob = user_fixture(%{username: "route_bob"})
      {:ok, conv_a} = Chat.create_conversation(Scope.for_user(alice), [bob.id])

      conn = log_in_user(conn, alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{conv_a.id}")

      # A bare {:new_message} for a DIFFERENT conversation (id 999_999, not the open one)
      # lands in the mailbox — an in-flight broadcast during a fast A→B switch. A raw struct
      # (not create_message) avoids the sidebar-activity broadcast, isolating the stream path.
      # Without the open?/2 gate this would stream_insert into conv_a's window.
      fake = %Eden.Chat.Message{
        id: 999_999,
        conversation_id: 999_999,
        sender_id: bob.id,
        body: "should-not-leak",
        inserted_at: ~N[2020-01-01 00:00:00],
        compact: false
      }

      send(view.pid, {:new_message, fake})

      refute render(view) =~ "should-not-leak"
    end
  end
end
