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

  test "shows the empty state when nothing is selected", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _view, html} = live(conn, ~p"/app")
    assert html =~ "No conversation selected"
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
      assert has_element?(view, ".ed-compose")

      # Switch conversations → the staged tray is dropped, otherwise A's media
      # would ride into B's composer and a send would attach it to the wrong chat.
      view |> element(~s(a[href="/app/c/#{conv2.id}"])) |> render_click()
      refute has_element?(view, ".ed-compose")
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
      send(view.pid, {:typing_expired, ctx.alice.id, make_ref()})
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
      assert has_element?(view, ".ed-compose")

      # The hook pushes media_sending{id} the instant the send is submitted: the
      # overlay closes at once (normal composer returns) even though the entry is
      # still staged, and the id is queued to stamp the real message.
      render_hook(view, "media_sending", %{"id" => "cid-7"})
      refute has_element?(view, ".ed-compose")
      assert has_element?(view, "#composer-body")
      # Sends are serialized while one is in flight: the attach affordance is gated
      # (pointer-events off) so a second media send can't overlap the first (#95).
      assert has_element?(view, "#composer label.pointer-events-none")

      # Submit: the stashed id stamps the album so its optimistic twin swaps out
      # client-side by data-client-id (no heuristic).
      view |> form("#composer", %{message: %{body: "look"}}) |> render_submit()

      assert {:ok, [%{body: "look", client_id: "cid-7", attachments: [%{kind: "image"}]}]} =
               Chat.list_messages(Scope.for_user(ctx.alice), ctx.conversation.id)

      refute has_element?(view, ".ed-compose")
    end

    test "the stall-watchdog reset re-shows the overlay so a stuck send can be cancelled (#95)",
         ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      file =
        file_input(view, "#composer", :attachment, [
          %{name: "a.png", content: File.read!(real_png_path()), type: "image/png"}
        ])

      render_upload(file, "a.png", 20)
      render_hook(view, "media_sending", %{"id" => "cid-stall"})
      refute has_element?(view, ".ed-compose")

      # The upload stalled (no real row, no error); the hook's watchdog asks the
      # server to clear the flag. The entry is still staged, so the overlay (with its
      # cancel button) returns and the user can abandon the stuck send.
      render_hook(view, "media_send_reset", %{})
      assert has_element?(view, ".ed-compose")
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

    test "the 1:1 header opens the other participant's profile", ctx do
      {:ok, bob} =
        Eden.Accounts.update_profile(ctx.bob, %{display_name: "Bob", bio: "Likes tea."})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      html =
        view
        |> element(~s(button[phx-click="show_profile"][phx-value-id="#{bob.id}"]))
        |> render_click()

      assert html =~ "@bob"
      assert html =~ "Likes tea."
      # The popover offers a Message button (the DM bridge), not the old modal.
      assert has_element?(view, ".ed-popover")
      assert has_element?(view, ~s(.ed-popover button[phx-click="message_user"]))
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

    test "a group header opens the member list, then a member's profile", ctx do
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      members = view |> element(~s(button[phx-click="show_members"])) |> render_click()
      assert members =~ "Members"
      assert members =~ "Carol"
      assert members =~ "(you)"

      profile =
        view
        |> element(~s(button[phx-click="show_profile"][phx-value-id="#{carol.id}"]))
        |> render_click()

      assert profile =~ "@carol"
      assert profile =~ "Message"
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

    test "forward copies the message into the chosen conversation", ctx do
      carol = user_fixture(%{username: "carolfwd"})
      {:ok, target} = Chat.create_conversation(Scope.for_user(ctx.alice), [carol.id])

      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{
          "body" => "share me"
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_click(view, "forward_prompt", %{"id" => to_string(msg.id)})
      assert render(view) =~ "Forward to"

      render_click(view, "forward", %{"target" => to_string(target.id)})

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
end
