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

  # Poll until `fun` is truthy — for Phoenix.Presence's eventual consistency across processes,
  # where a track/untrack from another LiveView isn't instantly visible to a read here (#209 tests).
  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(5) && wait_until(fun, tries - 1)
      true -> flunk("condition never became true")
    end
  end

  # A noisy JPEG big enough that #122 server compression would downscale it (> @photo_max),
  # so a stored width of 2400 proves the photo was kept uncompressed. Returns raw bytes.
  defp big_jpeg(width, height) do
    {:ok, noise} = Vix.Vips.Operation.gaussnoise(width, height)
    {:ok, u8} = Vix.Vips.Operation.cast(noise, :VIPS_FORMAT_UCHAR)
    {:ok, bytes} = Image.write(u8, :memory, suffix: ".jpg", quality: 90)
    bytes
  end

  # Send ONE photo through the sequential engine (#392: the only media-send path now):
  # queue_start → seq_item → upload. The album's client_id == its cid, so the stored message
  # carries `cid`. `as_file` rides queue_start (the "Send as file" choice, #122).
  defp seq_send_one(view, cid, content, name, as_file \\ false) do
    render_hook(view, "queue_start", %{
      "queue_id" => cid,
      "caption" => "",
      "caption_id" => nil,
      "as_file" => as_file,
      "albums" => [%{"cid" => cid, "count" => 1}],
      "file_cids" => []
    })

    render_hook(view, "seq_item", %{
      "queue_id" => cid,
      "client_id" => cid,
      "kind" => "media",
      "album_cid" => cid
    })

    view
    |> file_input("#composer", :attachment_seq, [
      %{name: name, content: content, type: "image/jpeg"}
    ])
    |> render_upload(name)
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

    # ── Telegram-style scoped presence for invisible users (#209) ───────────────────────────
    test "an invisible peer with the 1:1 open shows online to the partner, offline everywhere else",
         ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "invisible")

      # Alice (invisible) opens the 1:1 → she publishes "online" only on the scoped topic. Wait for
      # the track to PROPAGATE before reading it as bob (Phoenix.Presence is eventually consistent
      # across processes — reading conv_statuses too early can miss it under concurrent load).
      alice_conn = log_in_user(ctx.conn, alice)
      {:ok, _alice_view, _} = live(alice_conn, ~p"/app/c/#{ctx.conversation.id}")

      wait_until(fn ->
        Map.has_key?(EdenWeb.Presence.conv_statuses(ctx.conversation.id), alice.id)
      end)

      # Bob opens the SAME 1:1 → his header reads the scoped topic at open and shows her online.
      bob_conn = log_in_user(Phoenix.ConnTest.build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/app/c/#{ctx.conversation.id}")
      assert has_element?(bob_view, "[data-profile-trigger] .ed-avatar__dot")

      # ...but globally offline: the sidebar/profile read the GLOBAL map, which never has her.
      refute Map.has_key?(EdenWeb.Presence.statuses(), alice.id)
      refute has_element?(bob_view, "#conversations-#{ctx.conversation.id} .ed-avatar__dot")
    end

    test "a non-member never sees the invisible user online (#209)", ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "invisible")
      alice_conn = log_in_user(ctx.conn, alice)
      {:ok, _alice_view, _} = live(alice_conn, ~p"/app/c/#{ctx.conversation.id}")

      # carol shares no conversation with alice+bob — the membership gate that guards the message
      # + typing topics also guards the scoped presence, so she can never subscribe or read it.
      carol = user_fixture(%{username: "carol"})
      carol_conn = log_in_user(Phoenix.ConnTest.build_conn(), carol)

      case live(carol_conn, ~p"/app/c/#{ctx.conversation.id}") do
        {:error, {:live_redirect, _}} ->
          :ok

        {:ok, carol_view, _} ->
          refute has_element?(carol_view, "[data-profile-trigger] .ed-avatar__dot")
      end

      refute Map.has_key?(EdenWeb.Presence.statuses(), alice.id)
    end

    test "typing reaches the partner even while invisible (#209)", ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "invisible")
      alice_conn = log_in_user(ctx.conn, alice)
      {:ok, _alice_view, _} = live(alice_conn, ~p"/app/c/#{ctx.conversation.id}")

      bob_conn = log_in_user(Phoenix.ConnTest.build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/app/c/#{ctx.conversation.id}")

      # Typing rides the conversation topic, not presence, so it's unaffected by invisibility.
      Chat.broadcast_typing(Scope.for_user(alice), ctx.conversation.id)
      assert has_element?(bob_view, ".ed-typing-row__label", "Alice is typing")
    end

    test "an invisible peer going idle drops to offline for the partner (#209)", ctx do
      {:ok, alice} = Eden.Accounts.set_presence_status(ctx.alice, "invisible")

      alice_conn = log_in_user(ctx.conn, alice)
      {:ok, alice_view, _} = live(alice_conn, ~p"/app/c/#{ctx.conversation.id}")

      wait_until(fn ->
        Map.has_key?(EdenWeb.Presence.conv_statuses(ctx.conversation.id), alice.id)
      end)

      bob_conn = log_in_user(Phoenix.ConnTest.build_conn(), ctx.bob)
      {:ok, bob_view, _} = live(bob_conn, ~p"/app/c/#{ctx.conversation.id}")
      assert has_element?(bob_view, "[data-profile-trigger] .ed-avatar__dot")

      # Alice backgrounds / idles (#206) → untracks scoped. Wait for the untrack to PROPAGATE, then
      # force bob to recompute — the handler re-reads conv_statuses (now without alice); the payload
      # is ignored, so an empty diff is enough to drive the recompute.
      render_hook(alice_view, "presence_idle", %{})

      wait_until(fn ->
        not Map.has_key?(EdenWeb.Presence.conv_statuses(ctx.conversation.id), alice.id)
      end)

      send(bob_view.pid, %Phoenix.Socket.Broadcast{
        event: "presence_diff",
        topic: EdenWeb.Presence.conv_topic(ctx.conversation.id),
        payload: %{joins: %{}, leaves: %{}}
      })

      refute has_element?(bob_view, "[data-profile-trigger] .ed-avatar__dot")
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

    test "opening a group with another member's text message doesn't crash the render (#P0)",
         ctx do
      carol = user_fixture(%{username: "carol_grp_p0", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      # A NON-media text message from another member: the render branch that raised
      # BadBooleanError on `@message.sender and @grp in [...]` — a %User{} on the left of `and`,
      # which fires for every group message you didn't send. DMs (@group=false) never hit it.
      {:ok, _} = Chat.create_message(Scope.for_user(ctx.bob), group.id, %{"body" => "hi group"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{group.id}")
      assert html =~ "hi group"
      # The sender name rides the first row of a group message.
      assert html =~ ctx.bob.display_name
    end

    test "a solo auto-named group (all others removed) renders without crashing (#355 R001)",
         ctx do
      carol = user_fixture(%{username: "carol_solo355", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      # alice (owner) removes everyone else → no other ACTIVE members, so the auto title is ""
      # (Enum.map_join of []). Before the fix, title == "" → initials("") → String.upcase(nil)
      # crashed the WHOLE sidebar render (every conversation streams there).
      :ok = Chat.remove_group_member(Scope.for_user(ctx.alice), group.id, ctx.bob.id)
      :ok = Chat.remove_group_member(Scope.for_user(ctx.alice), group.id, carol.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      # live/3 raises if the render crashes — this streams the sidebar (conversation_item →
      # title/avatar-initials call-site).
      {:ok, view, html} = live(conn, ~p"/app/c/#{group.id}")
      # A real fallback label instead of a blank name.
      assert html =~ "Group"

      # The SECOND call-site — the group profile panel (conv_profile_panel → initials(title)) —
      # must also render without crashing.
      assert render_click(view, "open_profile", %{}) =~ "Group"
    end

    test "a freshly-created DM opens with a peer-greeting empty-state, not a bare pane (#355 R060)",
         ctx do
      # ctx.conversation is an empty 1:1 alice↔bob.
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert html =~ ~s(id="messages-empty")
      assert html =~ "No messages yet"
      # DM copy greets the peer by name — NOT the room "#..." copy.
      assert html =~ "Say hi to #{ctx.bob.display_name}"
      refute html =~ "Be the first to post in"
    end

    test "a freshly-created group opens with a group empty-state (#355 R060)", ctx do
      carol = user_fixture(%{username: "carol_empty355", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{group.id}")
      assert html =~ ~s(id="messages-empty")
      assert html =~ "Be the first to write in this group."
    end

    test "a room still shows its own empty-state copy (#355 R060 regression)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Empty355"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      assert html =~ ~s(id="messages-empty")
      assert html =~ "Be the first to post in ##{room.name}"
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

    test "attaching a file DURING an upload opens the overlay (not gated on @sending_media)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A send is in flight — the sequential engine's queue_start flips @sending_media true (and
      # cancels the just-sent tray, so nothing is staged → overlay closed).
      render_hook(view, "queue_start", %{
        "queue_id" => "q1",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["f1"]
      })

      refute has_element?(view, "[data-upload-preview]")

      # Attach ANOTHER file mid-upload: it stages and the overlay OPENS. The bug was that the overlay
      # was gated on `not @sending_media`, so a pick during a send stayed hidden — the file "vanished"
      # even though the sequential engine had queued it.
      file =
        file_input(view, "#composer", :attachment, [
          %{name: "b.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "b.png", 30)
      assert has_element?(view, "[data-upload-preview]")

      # ...and a FURTHER file can still be attached: the bar's paperclip drops out while something is
      # staged (only one :attachment input may exist), but the overlay owns the "Add more" input — so
      # attaching never dead-ends during an in-flight send (#330 review).
      assert has_element?(
               view,
               ~s([data-upload-preview] label[aria-label="Add more"] input[type="file"])
             )
    end

    test "Send as file (#122) stores the photo uncompressed and renders a document card", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      scope = Scope.for_user(ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # "Send as file" rides as_file:true on the sequential engine; the server stores as-is + flags it.
      seq_send_one(view, "cid-asfile", big_jpeg(2400, 1600), "p.jpg", true)

      {:ok, msgs} = Chat.list_messages(scope, ctx.conversation.id)
      assert %{attachments: [att]} = Enum.find(msgs, &(&1.client_id == "cid-asfile"))
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

      # A 1600×150 strip (aspect ~10.6:1, past the 5:1 cap) — sent NORMALLY (not "as file").
      seq_send_one(view, "cid-strip", big_jpeg(1600, 150), "strip.jpg")

      {:ok, msgs} = Chat.list_messages(scope, ctx.conversation.id)
      assert %{attachments: [att]} = Enum.find(msgs, &(&1.client_id == "cid-strip"))
      assert att.kind == "image" and att.width == 1600 and att.height == 150
      # The DB row is untouched (as_file stays false) — the strip→file decision is a render
      # concern (a future threshold change reflows old messages, no migration).
      refute att.as_file

      # Yet a fresh mount renders it as a downloadable document card, never an inline tile.
      {:ok, _view2, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      assert html =~ "ed-file--photo"
      refute html =~ "ed-album__tile"

      # Control: a normal-aspect photo (4:3) stays inline — no file card.
      seq_send_one(view, "cid-normal", big_jpeg(800, 600), "wide.jpg")

      {:ok, _v3, html2} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      {:ok, msgs2} = Chat.list_messages(scope, ctx.conversation.id)

      assert [%{width: 800, height: 600}] =
               Enum.find(msgs2, &(&1.client_id == "cid-normal")).attachments

      # Both image messages render, but only the strip became a file card (exactly one).
      assert length(String.split(html2, "ed-file--photo")) - 1 == 1
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

    test "cancel_upload on an already-cancelled ref is a no-op, not a crash (P0)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png", 20)

      # The stall path cancels every wedged entry (media_send_reset). The failed card's own
      # Resend/Delete then re-drive off that stale ref — a redundant cancel_upload used to
      # raise Phoenix.LiveView.Upload's "no such entry" and take the LiveView down. The ref is
      # gone from the config, so a repeat cancel must be a safe no-op.
      render_hook(view, "media_send_reset", %{})
      render_hook(view, "cancel_upload", %{"ref" => "0"})

      assert Process.alive?(view.pid)
    end

    test "a failed-card Resend sends via the dedicated :attachment_retry channel", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # The client stashes the retry metadata (retry_prepare) BEFORE feeding the cloned File, so
      # pending_retry is ready when the auto-upload completes. Then the pristine :attachment_retry
      # config takes the file (auto_upload → handle_retry_progress consumes + sends on done).
      render_hook(view, "retry_prepare", %{
        "client_id" => "retry-cid-1",
        "caption" => "",
        "as_file" => false,
        "media" => true
      })

      file =
        file_input(view, "#composer", :attachment_retry, [
          %{name: "resend.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "resend.png", 100)

      # The retry landed as a real message (streams in via {:new_message}), carrying the fresh
      # client_id so the retrying card swaps out client-side.
      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.client_id == "retry-cid-1" and &1.attachments != []))
    end

    test "a file Resend inherits the send's group_id so the row rejoins its bubble", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      gid = "55555555-5555-5555-5555-555555555555"

      render_hook(view, "retry_prepare", %{
        "client_id" => "retry-grp-1",
        "caption" => "",
        "as_file" => false,
        "media" => false,
        "group_id" => gid
      })

      file =
        file_input(view, "#composer", :attachment_retry, [
          %{name: "r.txt", content: "report gamma", type: "text/plain"}
        ])

      render_upload(file, "r.txt", 100)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      m = Enum.find(msgs, &(&1.client_id == "retry-grp-1"))
      assert m && m.group_id == gid
    end

    test "retry_reset drops the pending retry + entries without crashing", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "retry_prepare", %{
        "client_id" => "retry-cid-2",
        "caption" => "",
        "as_file" => false,
        "media" => false
      })

      file =
        file_input(view, "#composer", :attachment_retry, [
          %{name: "resend.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      # Partway (not done) — a stalled retry whose watchdog fires retry_reset.
      render_upload(file, "resend.png", 30)
      render_hook(view, "retry_reset", %{})

      assert Process.alive?(view.pid)
    end

    test "a second Resend while one is in flight is refused, not merged (#310 review P1)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # First retry: stash metadata + start its upload (still in flight). media: true matches the
      # PNG (the server classifies by magic bytes → image → album path, so the album-level
      # client_id from opts stamps the message).
      render_hook(view, "retry_prepare", %{
        "client_id" => "cid-first",
        "caption" => "",
        "as_file" => false,
        "media" => true
      })

      file =
        file_input(view, "#composer", :attachment_retry, [
          %{name: "first.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      # render_upload advances CUMULATIVELY, so 40 then 60 reaches 100 (40+100 would overflow the
      # test UploadClient). The 40% tick also exercises handle_retry_progress's media_progress push.
      render_upload(file, "first.png", 40)

      # A second Resend arrives while the first is in flight. The single pending_retry slot must
      # NOT be clobbered — else the first file would send under the second's client_id/conversation.
      render_hook(view, "retry_prepare", %{
        "client_id" => "cid-second",
        "caption" => "",
        "as_file" => false,
        "media" => true
      })

      render_upload(file, "first.png", 60)

      # The message landed under the FIRST retry's client_id — the second prepare was refused.
      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.client_id == "cid-first"))
      refute Enum.any?(msgs, &(&1.client_id == "cid-second"))
    end

    # ── Sequential send engine (TG-attachments) ──────────────────────────────────────────────
    test "sequential send: each file lands as its own message under one shared group_id", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "q1",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["f1", "f2"]
      })

      # Item 1: announce, feed one clone, complete.
      render_hook(view, "seq_item", %{
        "queue_id" => "q1",
        "client_id" => "f1",
        "kind" => "file",
        "album_cid" => nil
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "a.txt", content: "hi", type: "text/plain"}
        ])

      render_upload(f1, "a.txt", 100)

      # Item 2: the previous entry was consumed, so the next clone stages cleanly.
      render_hook(view, "seq_item", %{
        "queue_id" => "q1",
        "client_id" => "f2",
        "kind" => "file",
        "album_cid" => nil
      })

      f2 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "b.txt", content: "yo", type: "text/plain"}
        ])

      render_upload(f2, "b.txt", 100)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      m1 = Enum.find(msgs, &(&1.client_id == "f1"))
      m2 = Enum.find(msgs, &(&1.client_id == "f2"))
      assert m1 && m2, "both files should land as their own messages, progressively"
      # ≥2 files → one shared group_id (the merged bubble).
      assert m1.group_id && m1.group_id == m2.group_id
    end

    test "re-streaming during an in-flight send keeps the delivered file group OPEN (nav split)",
         ctx do
      # Switching chats mid-send (and back) re-runs select_conversation, whose static mark_group_pos
      # would CLOSE the last delivered file with :last (time + rounded bottom) — splitting it from
      # the still-uploading #pending tail below. reopen_inflight_tail must keep the tail open.
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, other} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Start a 3-file send but deliver only 2 — f3 stays in-flight (send_queue.files_left > 0).
      render_hook(view, "queue_start", %{
        "queue_id" => "qnav",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["f1", "f2", "f3"]
      })

      for {cid, name, body} <- [{"f1", "a.txt", "hi"}, {"f2", "b.txt", "yo"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "qnav",
          "client_id" => cid,
          "kind" => "file",
          "album_cid" => nil
        })

        view
        |> file_input("#composer", :attachment_seq, [
          %{name: name, content: body, type: "text/plain"}
        ])
        |> render_upload(name, 100)
      end

      # Precondition (via the public context, not process internals): exactly f1+f2 landed — f3 is
      # still to come, so the group's send queue is genuinely in flight.
      {:ok, delivered} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      landed = for m <- delivered, m.client_id in ["f1", "f2", "f3"], do: m.client_id
      assert Enum.sort(landed) == ["f1", "f2"], "only f1+f2 delivered; f3 stays in flight"

      # Navigate away and back — the round-trip forces the full re-stream.
      render_patch(view, ~p"/app/c/#{other.id}")
      html = render_patch(view, ~p"/app/c/#{ctx.conversation.id}")

      # The two delivered files stay ONE open group [:first, :middle]: no closed :last tail (which
      # would show its own time and round its bottom off from the #pending continuation).
      assert html =~ "ed-bubble--grp-first"
      assert html =~ "ed-bubble--grp-mid"
      refute html =~ "ed-bubble--grp-last"
    end

    test "a held group (failed card parked) keeps its tail open; release closes it", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Deliver a full 2-file group → it closes ([:first, :last], time on the last).
      render_hook(view, "queue_start", %{
        "queue_id" => "qh",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["h1", "h2"]
      })

      for {cid, name} <- [{"h1", "a.txt"}, {"h2", "b.txt"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "qh",
          "client_id" => cid,
          "kind" => "file",
          "album_cid" => nil
        })

        view
        |> file_input("#composer", :attachment_seq, [
          %{name: name, content: "x", type: "text/plain"}
        ])
        |> render_upload(name, 100)
      end

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      gid = Enum.find_value(msgs, & &1.group_id)
      assert gid, "a 2-file send shares a group id"
      assert render(view) =~ "ed-bubble--grp-last", "the completed group closes with a :last tail"

      # A failed upload card is parked in #pending for this group → hold: the delivered tail opens
      # so the card fuses flush below it (no closed :last with a time above a dangling card).
      render_hook(view, "group_hold", %{"group_id" => gid})
      held = render(view)
      refute held =~ "ed-bubble--grp-last", "held group keeps its tail open"
      assert held =~ "ed-bubble--grp-mid"

      # The card was resent (and landed) or deleted → release closes the tail again.
      render_hook(view, "group_release", %{"group_id" => gid})
      assert render(view) =~ "ed-bubble--grp-last", "released group closes its tail"
    end

    test "sequential album: photos accumulate into ONE album message", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "q2",
        "caption" => "trip",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [%{"cid" => "alb1", "count" => 2}],
        "file_cids" => []
      })

      for {cid, name} <- [{"p1", "1.png"}, {"p2", "2.png"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "q2",
          "client_id" => cid,
          "kind" => "media",
          "album_cid" => "alb1"
        })

        f =
          file_input(view, "#composer", :attachment_seq, [
            %{name: name, content: File.read!(real_png_path()), type: "image/png"}
          ])

        render_upload(f, name, 100)
      end

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      album = Enum.find(msgs, &(&1.client_id == "alb1"))
      assert album, "the album message should land once all its photos uploaded"
      assert length(album.attachments) == 2
      # The caption rides the album; the album carries no group_id (only files group).
      assert album.body == "trip"
      assert is_nil(album.group_id)
    end

    test "a seq album the server rejects fires media_failed and keeps the caption (#361/R080/R081/R082)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # A photo over @max_image_bytes (8 MiB) passes the :attachment_seq upload (its cap is the
      # larger @max_video_bytes) but create_attachments' per-kind check rejects it as :too_large;
      # a trailing file carries the send's caption.
      render_hook(view, "queue_start", %{
        "queue_id" => "qf",
        "caption" => "trip",
        "caption_id" => "cap1",
        "as_file" => false,
        "albums" => [%{"cid" => "big", "count" => 1}],
        "file_cids" => ["f1"]
      })

      oversized_png =
        <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy("x", 8 * 1024 * 1024 + 1)

      render_hook(view, "seq_item", %{
        "queue_id" => "qf",
        "client_id" => "big",
        "kind" => "media",
        "album_cid" => "big"
      })

      f =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "huge.png", content: oversized_png, type: "image/png"}
        ])

      render_upload(f, "huge.png", 100)

      # R080/R082: the rejected album pushes media_failed for its acid (so the client keeps the
      # optimistic node retriable) instead of silently succeeding / vanishing.
      assert_push_event(view, "media_failed", %{id: "big"})

      # Feed the trailing file — it succeeds.
      render_hook(view, "seq_item", %{
        "queue_id" => "qf",
        "client_id" => "f1",
        "kind" => "file",
        "album_cid" => nil
      })

      ff =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "doc.txt", content: "hi", type: "text/plain"}
        ])

      render_upload(ff, "doc.txt", 100)

      # R081: the failed album did NOT consume the caption, so it survives as the trailing text.
      # Before the fix, caption_used was set even on {:error} and "trip" vanished silently.
      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.body == "trip")), "the caption survived the failed album"
    end

    test "sequential video: the client's width/height reserve the box (#231)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qv",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [%{"cid" => "vid1", "count" => 1}],
        "file_cids" => []
      })

      # seq_item carries the client-measured dims — the plumbing under test (sanitize_dim →
      # seq_pending → put_client_dims → media_dimensions). A fake ftyp clip keeps it ffmpeg-free.
      render_hook(view, "seq_item", %{
        "queue_id" => "qv",
        "client_id" => "v1",
        "kind" => "media",
        "album_cid" => "vid1",
        "width" => 640,
        "height" => 480
      })

      video = <<0, 0, 0, 24>> <> "ftypisom" <> :binary.copy(<<0>>, 16)

      f =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "clip.mp4", content: video, type: "video/mp4"}
        ])

      render_upload(f, "clip.mp4", 100)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      album = Enum.find(msgs, &(&1.client_id == "vid1"))
      assert album, "the video message should land"
      att = hd(album.attachments)
      assert att.kind == "video"
      assert att.width == 640
      assert att.height == 480
    end

    test "cancelling one album photo (phase D) sends the album with the rest", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qp",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [%{"cid" => "alb", "count" => 2}],
        "file_cids" => []
      })

      # Photo 1 uploads and accumulates (album expects 2, has 1 so far — not yet posted).
      render_hook(view, "seq_item", %{
        "queue_id" => "qp",
        "client_id" => "ph1",
        "kind" => "media",
        "album_cid" => "alb"
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "1.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(f1, "1.png", 100)

      # The user cancels the OTHER (still-queued) photo → the album's expected drops to 1, which the
      # one uploaded photo already satisfies, so the album is posted NOW with just that photo.
      render_hook(view, "seq_drop", %{"queue_id" => "qp", "kind" => "media", "album_cid" => "alb"})

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      album = Enum.find(msgs, &(&1.client_id == "alb"))
      assert album, "the album should send with the remaining photo after one was cancelled"
      assert length(album.attachments) == 1

      # The queue finalized (no wedged sending flag).
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.send_queues == []
      refute assigns.sending_media
    end

    test "cancelling the IN-FLIGHT album photo drops just it; the album sends the rest", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qf",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [%{"cid" => "alf", "count" => 2}],
        "file_cids" => []
      })

      # Photo 1 is UPLOADING (partway) when the user cancels it → seq_reset aborts it + decrements
      # the album's expected to 1 (the aborted photo never accumulated).
      render_hook(view, "seq_item", %{
        "queue_id" => "qf",
        "client_id" => "pf1",
        "kind" => "media",
        "album_cid" => "alf"
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "1.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(f1, "1.png", 30)
      render_hook(view, "seq_reset", %{})

      # Photo 2 uploads → the album is posted with just it.
      render_hook(view, "seq_item", %{
        "queue_id" => "qf",
        "client_id" => "pf2",
        "kind" => "media",
        "album_cid" => "alf"
      })

      f2 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "2.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(f2, "2.png", 100)

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      album = Enum.find(msgs, &(&1.client_id == "alf"))
      assert album && length(album.attachments) == 1
    end

    test "cancelling ALL album photos sends no album + finalizes the queue", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qz",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [%{"cid" => "alz", "count" => 2}],
        "file_cids" => []
      })

      # Cancel both still-queued photos → expected 2→1→0 → the album is dropped entirely.
      render_hook(view, "seq_drop", %{"queue_id" => "qz", "kind" => "media", "album_cid" => "alz"})

      render_hook(view, "seq_drop", %{"queue_id" => "qz", "kind" => "media", "album_cid" => "alz"})

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      refute Enum.any?(msgs, &(&1.client_id == "alz"))

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.send_queues == []
      refute assigns.sending_media
    end

    test "a lone file gets no group_id (renders as a normal bubble)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "q3",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["solo"]
      })

      render_hook(view, "seq_item", %{
        "queue_id" => "q3",
        "client_id" => "solo",
        "kind" => "file",
        "album_cid" => nil
      })

      f =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "solo.txt", content: "x", type: "text/plain"}
        ])

      render_upload(f, "solo.txt", 100)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      solo = Enum.find(msgs, &(&1.client_id == "solo"))
      assert solo && is_nil(solo.group_id)
    end

    test "seq_reset skips a stalled item; the batch continues to the next (no crash)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "q4",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["s1", "s2"]
      })

      # Item 1 stalls partway → the watchdog fires seq_reset (abort + free the slot).
      render_hook(view, "seq_item", %{
        "queue_id" => "q4",
        "client_id" => "s1",
        "kind" => "file",
        "album_cid" => nil
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "s1.txt", content: "hi", type: "text/plain"}
        ])

      render_upload(f1, "s1.txt", 30)
      render_hook(view, "seq_reset", %{})
      assert Process.alive?(view.pid)

      # Item 2 still completes — the batch kept going.
      render_hook(view, "seq_item", %{
        "queue_id" => "q4",
        "client_id" => "s2",
        "kind" => "file",
        "album_cid" => nil
      })

      f2 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "s2.txt", content: "yo", type: "text/plain"}
        ])

      render_upload(f2, "s2.txt", 100)

      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.client_id == "s2"))

      # The skipped item (s1) must be accounted for: files_left reaches 0, so the queue finalizes
      # and the in-flight flag clears — else seq_reset would leak files_left and wedge sending_media.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.send_queues == []
      refute assigns.sending_media
    end

    test "seq_drop accounts for a queued file cancelled before it was fed", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "q5",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["d1", "d2"]
      })

      # Send d1 normally.
      render_hook(view, "seq_item", %{
        "queue_id" => "q5",
        "client_id" => "d1",
        "kind" => "file",
        "album_cid" => nil
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "d1.txt", content: "report delta", type: "text/plain"}
        ])

      render_upload(f1, "d1.txt", 100)

      # The user cancels d2 while it's still QUEUED (never fed) → the client drops its count.
      render_hook(view, "seq_drop", %{"queue_id" => "q5", "kind" => "file", "album_cid" => nil})

      # d1 delivered; the queue finalized despite d2 never being sent (no wedged sending_media).
      assert {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      assert Enum.any?(msgs, &(&1.client_id == "d1"))
      refute Enum.any?(msgs, &(&1.client_id == "d2"))

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.send_queues == []
      refute assigns.sending_media
    end

    test "a 3-file group renders as one merged bubble: first/mid/last, sender+meta collapse",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qg",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["g1", "g2", "g3"]
      })

      for {cid, name} <- [{"g1", "g1.txt"}, {"g2", "g2.txt"}, {"g3", "g3.txt"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "qg",
          "client_id" => cid,
          "kind" => "file",
          "album_cid" => nil
        })

        f =
          file_input(view, "#composer", :attachment_seq, [
            %{name: name, content: "report #{cid}", type: "text/plain"}
          ])

        render_upload(f, name, 100)
      end

      html = render(view)
      # The run of three fuses: first / middle / last position classes are all present.
      assert html =~ "ed-bubble--grp-first"
      assert html =~ "ed-bubble--grp-mid"
      assert html =~ "ed-bubble--grp-last"
      # The group_pos map tracks all three; the tail is the last member.
      assigns = :sys.get_state(view.pid).socket.assigns
      positions = assigns.group_pos |> Map.values() |> Enum.sort()
      assert :first in positions and :middle in positions and :last in positions
      assert match?({_sid, _gid, _prev, :last}, assigns.last_group)
    end

    test "an in-flight group keeps landed rows off :last so they fuse with the uploading tail",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qi",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["i1", "i2"]
      })

      # i1 lands while i2 is STILL queued (the send is in flight) → i1 must be :first, not :last, so
      # it fuses with the #pending optimistic tail into one bubble (no detached tail).
      render_hook(view, "seq_item", %{
        "queue_id" => "qi",
        "client_id" => "i1",
        "kind" => "file",
        "album_cid" => nil
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "i1.txt", content: "a", type: "text/plain"}
        ])

      render_upload(f1, "i1.txt", 100)
      render(view)

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      i1 = Enum.find(msgs, &(&1.client_id == "i1"))
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.group_pos[i1.id] == :first

      # i2 lands and drains the queue → i2 is the tail (:last), i1 stays :first — the closed bubble.
      render_hook(view, "seq_item", %{
        "queue_id" => "qi",
        "client_id" => "i2",
        "kind" => "file",
        "album_cid" => nil
      })

      f2 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "i2.txt", content: "b", type: "text/plain"}
        ])

      render_upload(f2, "i2.txt", 100)
      render(view)

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      i2 = Enum.find(msgs, &(&1.client_id == "i2"))
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.group_pos[i1.id] == :first
      assert assigns.group_pos[i2.id] == :last
    end

    test "deleting the last file of a group re-fuses: the new last regains its position", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "queue_start", %{
        "queue_id" => "qd",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["e1", "e2", "e3"]
      })

      for {cid, name} <- [{"e1", "e1.txt"}, {"e2", "e2.txt"}, {"e3", "e3.txt"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "qd",
          "client_id" => cid,
          "kind" => "file",
          "album_cid" => nil
        })

        f =
          file_input(view, "#composer", :attachment_seq, [
            %{name: name, content: "report #{cid}", type: "text/plain"}
          ])

        render_upload(f, name, 100)
      end

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      e2 = Enum.find(msgs, &(&1.client_id == "e2"))
      e3 = Enum.find(msgs, &(&1.client_id == "e3"))

      # Delete the LAST file (e3) for everyone → the group re-fuses: e2 (was :middle) becomes :last.
      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), e3.id)
      render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.group_pos[e2.id] == :last
    end

    test "queue_resume re-opens an interrupted send, skipping items that already landed", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      gid = "88888888-8888-8888-8888-888888888888"

      # rf1 already landed BEFORE the "reload" (its message exists, stamped with the group).
      path = Path.join(System.tmp_dir!(), "rf1-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "already here")
      on_exit(fn -> File.rm(path) end)

      {:ok, _} =
        Chat.create_attachments(
          Scope.for_user(ctx.alice),
          ctx.conversation.id,
          [%{path: path, filename: "rf1.txt", client_id: "rf1"}],
          %{group_id: gid}
        )

      # The client rebuilt the queue from IndexedDB after a reload: both rf1 (sent) + rf2 (not).
      render_hook(view, "queue_resume", %{
        "queue_id" => "qr",
        "group_id" => gid,
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["rf1", "rf2"],
        "client_ids" => ["rf1", "rf2"]
      })

      # The server re-stashed a queue with only rf2 remaining (rf1 already sent) and REUSED the
      # group_id (owned by alice), so the resumed row rejoins the merged bubble.
      assigns = :sys.get_state(view.pid).socket.assigns
      q = List.last(assigns.send_queues)
      assert q.files_left == 1
      assert q.group_id == gid

      # Feed the remaining file → it lands under the same group.
      render_hook(view, "seq_item", %{
        "queue_id" => "qr",
        "client_id" => "rf2",
        "kind" => "file",
        "album_cid" => nil
      })

      f =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "rf2.txt", content: "resumed", type: "text/plain"}
        ])

      render_upload(f, "rf2.txt", 100)

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)
      rf2 = Enum.find(msgs, &(&1.client_id == "rf2"))
      assert rf2 && rf2.group_id == gid
      # No duplicate of rf1 (idempotent): still exactly one message with that client_id.
      assert Enum.count(msgs, &(&1.client_id == "rf1")) == 1
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

    test "your own card carries no action button (no Message, no Edit)", ctx do
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      render_click(view, "show_profile", %{"id" => to_string(ctx.alice.id)})
      assert has_element?(view, ".ed-popover")
      # Editing lives in Settings, not in this quick-access card (#209 follow-up), and you can't
      # message yourself — so the own card is pure identity, no footer action.
      refute has_element?(view, ~s(.ed-popover a[href="/settings"]))
      refute has_element?(view, ~s(.ed-popover button[phx-click="message_user"]))
    end

    test "the profile popover shows the managed corporate identity (#173)", ctx do
      # Managed fields are admin/sync-owned; set them directly for the render test.
      Eden.Repo.update!(
        Ecto.Changeset.change(ctx.bob, %{
          position: "Инженер",
          structure: "Разработка",
          corp_email: "bob@corp.ru"
        })
      )

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      html = render_click(view, "show_profile", %{"id" => to_string(ctx.bob.id)})

      # The full corporate identity rides the card, not just the handle (#173).
      assert html =~ "Инженер"
      assert html =~ "Разработка"
      assert html =~ "bob@corp.ru"
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

  describe "#369 groups / forward / knock UX" do
    setup [:setup_conversation]

    test "a partial forward failure names the count and keeps the successful copy (#369/R083)",
         ctx do
      carol = user_fixture(%{username: "carol_pf"})
      {:ok, target} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      {:ok, m1} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "keep me"})

      {:ok, m2} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "gone"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{target.id}")

      render_hook(view, "forward_rehydrate", %{"ids" => [m1.id, m2.id]})
      # m2 is tombstoned after carry → its forward fails while m1's succeeds (a partial drop).
      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), m2.id)

      html = render_submit(view, "send", %{"message" => %{"body" => ""}})

      {:ok, msgs} = Chat.list_messages(Scope.for_user(ctx.alice), target.id)
      assert Enum.any?(msgs, &(&1.body == "keep me"))
      assert html =~ "1 message"
    end

    test "a total forward failure keeps the carry so it can be retried (#369/R084)", ctx do
      carol = user_fixture(%{username: "carol_ff"})
      {:ok, target} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      {:ok, m1} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "gone"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{target.id}")

      render_hook(view, "forward_rehydrate", %{"ids" => [m1.id]})
      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), m1.id)
      render_submit(view, "send", %{"message" => %{"body" => ""}})

      # Nothing forwarded → the carry survives for a retry (not cleared like a partial/full success).
      assert :sys.get_state(view.pid).socket.assigns.pending_forward != nil
    end

    test "carrying a forward makes the composer read-only so Send only forwards (#369/R053)",
         ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "fwd"})

      carol = user_fixture(%{username: "carol_r53"})
      {:ok, target} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{target.id}")

      render_click(view, "forward_prompt", %{"id" => to_string(msg.id)})
      html = render(view)
      assert has_element?(view, "#composer-body[readonly]")
      assert html =~ "Press Send to forward"
    end

    test "a named group with only one member picked warns instead of a silent DM (#369/R176)",
         ctx do
      carol = user_fixture(%{username: "carol_gn"})
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      html =
        render_submit(view, "start", %{
          "title" => "My Group",
          "member_ids" => [to_string(carol.id)]
        })

      assert html =~ "Pick at least two people"
    end

    test "start with an EMPTY member_ids list warns, never a memberless conversation (#369 review)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      before = length(Chat.list_conversations(Scope.for_user(ctx.alice)))
      # member_ids: [] reaches the first clause but Chat.create_conversation([]) returns
      # {:error, :no_members} → the flash, not a memberless conversation (#401 review false positive).
      html = render_submit(view, "start", %{"title" => "", "member_ids" => []})

      assert html =~ "Pick at least one person"
      assert length(Chat.list_conversations(Scope.for_user(ctx.alice))) == before
    end

    test "a group offers 'Leave group' (irreversible); a DM offers 'Delete chat' (#369/R069)",
         ctx do
      carol = user_fixture(%{username: "carol_lg"})

      {:ok, _group} =
        Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id],
          group: true,
          title: "Trip"
        )

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Leave group"
      assert html =~ "Leave this group?"
      # The DM (bob) still uses the reversible delete copy.
      assert html =~ "Delete chat"
    end

    test "the new-conversation Start submit is disabled by default (#369/R190)", ctx do
      _carol = user_fixture(%{username: "carol_190"})
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      render_click(view, "toggle_new", %{})
      assert has_element?(view, ~s(#new-conv-form button[type="submit"][disabled]))
    end

    test "approving a knock walks the requester into the room with a flash (#369/R076)", ctx do
      {:ok, channel} = Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "K76"})

      {:ok, room} =
        Eden.Channels.create_room(Scope.for_user(ctx.alice), channel.id, %{
          "name" => "secret",
          "visibility" => "private"
        })

      {:ok, _} = Eden.Channels.ensure_member(Scope.for_user(ctx.bob), channel.id)

      conn = log_in_user(ctx.conn, ctx.bob)
      # bob reaches the private room by link → the knock window (no room selected).
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      refute :sys.get_state(view.pid).socket.assigns.selected

      # alice (admin) grants access → {:members_changed} → bob's session auto-enters the room.
      {:ok, _} = Eden.Channels.add_room_members(Scope.for_user(ctx.alice), room.id, [ctx.bob.id])
      html = render(view)

      assert :sys.get_state(view.pid).socket.assigns.selected.id == room.id
      assert html =~ "given access"
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

    test "a reply to a backgrounded tab's open thread isn't auto-read (#370/R055)", ctx do
      {:ok, channel} = Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "T55"})
      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, _} = Eden.Channels.ensure_member(Scope.for_user(ctx.bob), channel.id)
      :ok = Chat.join_room(room.id, ctx.bob.id)

      scope_a = Scope.for_user(ctx.alice)
      {:ok, root} = Chat.create_message(scope_a, room.id, %{"body" => "the root"})
      # bob replies → alice (root author) follows with unread 1.
      {:ok, _} = Chat.create_reply(Scope.for_user(ctx.bob), root.id, %{"body" => "first"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      # Open the thread panel → alice reads it (unread 0).
      view |> element(".ed-thread-footer") |> render_click()
      assert has_element?(view, ".ed-thread")
      assert %{unread: 0} = Chat.thread_follow_state(scope_a, root.id)

      # Background the tab, then a new reply arrives.
      render_hook(view, "tab_hidden", %{})
      {:ok, _} = Chat.create_reply(Scope.for_user(ctx.bob), root.id, %{"body" => "second"})
      render(view)

      # It must NOT be auto-read on the server while the tab is hidden (mirrors #206).
      assert %{unread: 1} = Chat.thread_follow_state(scope_a, root.id)

      # Returning to the tab catches the open thread up.
      render_hook(view, "tab_visible", %{})
      assert %{unread: 0} = Chat.thread_follow_state(scope_a, root.id)
    end

    test "deleting the last reply clears the thread facepile (#370/R177)", ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "F177"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      scope_a = Scope.for_user(ctx.alice)
      {:ok, root} = Chat.create_message(scope_a, room.id, %{"body" => "root"})
      {:ok, reply} = Chat.create_reply(scope_a, root.id, %{"body" => "only reply"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")

      facepile = fn -> :sys.get_state(view.pid).socket.assigns.thread_participants[root.id] end
      refute facepile.() in [nil, []]

      # Delete the only reply → {:thread_updated} → the facepile for this root clears (the old
      # Map.merge left stale avatars behind for a thread that now has zero replies).
      :ok = Chat.delete_message_for_both(scope_a, reply.id)
      render(view)
      assert facepile.() == []
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

    test "attaching a file in a thread opens the SAME compose lightbox as the main composer (#348)",
         ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThreadStage"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      refute has_element?(view, "#reply-composer [data-upload-preview]")

      f =
        file_input(view, "#reply-composer", :thread_attachment, [
          %{name: "pic.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(f, "pic.png", 100)

      # The compose lightbox (grid + scoped caption), NOT the old cramped inline tray.
      assert has_element?(view, "#reply-composer [data-upload-preview]")
      assert has_element?(view, "#reply-composer #thread-compose-caption")
      refute has_element?(view, ".ed-thread-tray")
    end

    test "sequential upload into a thread lands each file as a reply under the root (phase F)",
         ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "ThreadSeq"})

      {:ok, [room]} = Eden.Channels.list_rooms(Scope.for_user(ctx.alice), channel.id)
      {:ok, root} = Chat.create_message(Scope.for_user(ctx.alice), room.id, %{"body" => "root"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      render_click(view, "open_thread", %{"id" => to_string(root.id)})

      # The .ThreadSendQueue hook routes a staged album/file send through the MAIN sequential feeder
      # carrying the root id (phase F). Drive the exact events it emits.
      render_hook(view, "queue_start", %{
        "queue_id" => "tq1",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["tf1", "tf2"],
        "root_id" => root.id
      })

      render_hook(view, "seq_item", %{
        "queue_id" => "tq1",
        "client_id" => "tf1",
        "kind" => "file",
        "album_cid" => nil
      })

      f1 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "a.txt", content: "hi", type: "text/plain"}
        ])

      render_upload(f1, "a.txt", 100)

      render_hook(view, "seq_item", %{
        "queue_id" => "tq1",
        "client_id" => "tf2",
        "kind" => "file",
        "album_cid" => nil
      })

      f2 =
        file_input(view, "#composer", :attachment_seq, [
          %{name: "b.txt", content: "yo", type: "text/plain"}
        ])

      render_upload(f2, "b.txt", 100)

      scope = Scope.for_user(ctx.alice)
      # Both files are thread replies under the root, sharing a group_id.
      assert {:ok, %{reply_count: 2}, [r1, r2]} = Chat.list_thread(scope, root.id)
      assert r1.client_id == "tf1" and r2.client_id == "tf2"
      assert r1.root_id == root.id and r2.root_id == root.id
      assert r1.group_id && r1.group_id == r2.group_id
      # And they stay out of the room's main stream.
      {:ok, msgs} = Chat.list_messages(scope, room.id)
      refute Enum.any?(msgs, &(&1.client_id in ["tf1", "tf2"]))
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

      # Stage a photo → the thread compose lightbox appears.
      file =
        file_input(view, "#reply-composer", :thread_attachment, [
          %{name: "t.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "t.png")
      assert has_element?(view, "#reply-composer [data-upload-preview]")

      # Submit with an empty caption (the album is the content) → it sends as a thread reply
      # with an attachment, and the lightbox clears. (No-JS path: the server send_thread_album
      # consumes the staged entries; with JS the .ThreadSendQueue hook drives threadComposeSend.)
      view |> form("#reply-composer", reply: %{body: ""}) |> render_submit()
      refute has_element?(view, "#reply-composer [data-upload-preview]")
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

    test "a fuzzy (typo) result's snippet anchors at the body's start, not the tail (#379/R070)",
         ctx do
      {:ok, _} =
        Chat.create_message(Scope.for_user(ctx.bob), ctx.conversation.id, %{
          "body" =>
            "Quarterly planning notes for the whole distributed team across regions, " <>
              "covering logistics and budgets, and finally our rendezvous point downtown"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # "rendezous" (dropped v) isn't a literal substring, but trigram word-similarity finds it
      # (#56). The snippet must then anchor at the body's start — the old code split on the absent
      # term, got the whole body back, and ran the window off to a meaningless tail.
      html = render_change(view, "search", %{"q" => "rendezous"})
      assert html =~ "Quarterly planning notes"
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

  describe "#379 stream / selection desync" do
    setup [:setup_conversation]

    defp sel(view), do: :sys.get_state(view.pid).socket.assigns.selection

    test "deleting a selected message drops it from the selection (#379/R056)", ctx do
      {:ok, m1} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "one"})

      {:ok, m2} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "two"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "enter_select", %{"id" => to_string(m1.id)})
      render_hook(view, "toggle_select", %{"id" => to_string(m2.id)})
      assert MapSet.size(sel(view)) == 2

      # m1 is deleted-for-everyone → {:message_deleted} on the open conversation topic.
      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), m1.id)
      render(view)

      assert MapSet.equal?(sel(view), MapSet.new([m2.id]))
    end

    test "deleting the last selected message exits select mode (#379/R056)", ctx do
      {:ok, m1} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "solo"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "enter_select", %{"id" => to_string(m1.id)})
      assert MapSet.size(sel(view)) == 1

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), m1.id)
      render(view)

      assert is_nil(sel(view))
    end

    test "deleting a carried message drops it from the forward plaque (#379/R056)", ctx do
      {:ok, m1} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "carry 1"})

      {:ok, m2} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "carry 2"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_hook(view, "forward_rehydrate", %{"ids" => [m1.id, m2.id]})
      pending = :sys.get_state(view.pid).socket.assigns.pending_forward
      assert Enum.map(pending, & &1.id) == [m1.id, m2.id]

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), m1.id)
      render(view)

      carried = :sys.get_state(view.pid).socket.assigns.pending_forward
      assert Enum.map(carried, & &1.id) == [m2.id]
    end

    test "a merged file bubble survives the peer reading the DM (#379/R058)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Three files in one send → a merged (grouped) file bubble carrying group_pos.
      render_hook(view, "queue_start", %{
        "queue_id" => "qr",
        "caption" => "",
        "caption_id" => nil,
        "as_file" => false,
        "albums" => [],
        "file_cids" => ["r1", "r2", "r3"]
      })

      for {cid, name} <- [{"r1", "r1.txt"}, {"r2", "r2.txt"}, {"r3", "r3.txt"}] do
        render_hook(view, "seq_item", %{
          "queue_id" => "qr",
          "client_id" => cid,
          "kind" => "file",
          "album_cid" => nil
        })

        view
        |> file_input("#composer", :attachment_seq, [
          %{name: name, content: "x", type: "text/plain"}
        ])
        |> render_upload(name, 100)
      end

      html = render(view)
      assert html =~ "ed-bubble--grp-first"
      assert html =~ "ed-bubble--grp-last"

      # Bob reads the DM → {:read} re-streams the raw list; group_pos must be restored, not lost.
      send(view.pid, {:read, ctx.bob.id, DateTime.utc_now() |> DateTime.truncate(:second)})
      html = render(view)
      assert html =~ "ed-bubble--grp-first"
      assert html =~ "ed-bubble--grp-last"
    end

    test "renaming a room member refreshes the name in already-rendered flat rows (#379/R077)",
         ctx do
      {:ok, channel} =
        Eden.Channels.create_channel(Scope.for_user(ctx.alice), %{"name" => "Team"})

      {:ok, room} =
        Eden.Channels.create_room(Scope.for_user(ctx.alice), channel.id, %{"name" => "talk"})

      {:ok, _} = Eden.Channels.ensure_member(Scope.for_user(ctx.bob), channel.id)
      :ok = Chat.join_room(room.id, ctx.bob.id)
      {:ok, _} = Chat.create_message(Scope.for_user(ctx.bob), room.id, %{"body" => "hi from bob"})
      # A second consecutive message → compact (collapsed under the first, no repeated header).
      {:ok, m2} = Chat.create_message(Scope.for_user(ctx.bob), room.id, %{"body" => "and again"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}/r/#{room.id}")
      # Room selection (finish_open_room) is async — barrier on the message being rendered.
      wait_until(fn -> render(view) =~ "hi from bob" end)
      assert render(view) =~ "Bob"
      assert :sys.get_state(view.pid).socket.assigns.compacts[m2.id] == true

      # Bob renames himself → {:user_updated} → reload_selected re-streams the room. The old room
      # branch skipped the re-stream, so the flat rows kept the stale name.
      {:ok, _} = Eden.Accounts.update_profile(ctx.bob, %{display_name: "Bobby Renamed"})
      html = render(view)
      assert html =~ "Bobby Renamed"

      # #155 regression shield: the re-stream ran through mark_compact, so m2 stays compact — a
      # raw re-stream (the group branch's old bug) would drop the flag and spring the header back.
      assert :sys.get_state(view.pid).socket.assigns.compacts[m2.id] == true
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

    test "delivers to the OPEN chat once the tab is hidden — the other half of the focus gate (#363/R108)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      # Focused (tab visible + this chat open) → suppressed.
      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: ctx.conversation.id, preview: "a"})}
      )

      render(view)
      refute_push_event(view, "notify", %{})

      # Tab hidden → not focused any more, though the chat is still open → delivered. This is the
      # tab_visible half of focused? that no prior test exercised.
      render_hook(view, "tab_hidden", %{})

      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: ctx.conversation.id, preview: "b"})}
      )

      assert_push_event(view, "notify", %{conversation_id: cid})
      assert cid == ctx.conversation.id
    end

    test "the client event drops the internal :preview and :avatar_key, keeps :body/:avatar_url (#363/R203)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      send(
        view.pid,
        {:notify,
         notify_payload(%{
           conversation_id: 7,
           sender_id: ctx.alice.id,
           preview: "hello there",
           avatar_key: "avatars/secret.jpg"
         })}
      )

      assert_push_event(view, "notify", payload)
      assert payload.body == "hello there"
      assert payload.avatar_url =~ "/users/#{ctx.alice.id}/avatar"
      # The raw size-guard body + the internal storage key never reach the client.
      refute Map.has_key?(payload, :preview)
      refute Map.has_key?(payload, :avatar_key)
    end

    test "a media message with a caption leads the banner body with the media marker (#363/R202)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      # Caption present → "Photo, <caption>" (the marker isn't swallowed by the text).
      send(
        view.pid,
        {:notify,
         notify_payload(%{conversation_id: 7, media_kind: "image", preview: "nice shot"})}
      )

      assert_push_event(view, "notify", %{body: "Photo, nice shot"})

      # Media-only (empty preview) → the bare marker, as before.
      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: 8, media_kind: "video", preview: ""})}
      )

      assert_push_event(view, "notify", %{body: "Video"})
    end

    test "a knock event words the body as a join request (#363/R029)", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      send(
        view.pid,
        {:notify, notify_payload(%{conversation_id: 9, kind: "knock", conv_title: "secret"})}
      )

      assert_push_event(view, "notify", %{body: "Requested to join", kind: "knock"})
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
