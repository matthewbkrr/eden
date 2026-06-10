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

      assert html =~ ~s(src="/files/#{message.attachment.id}")
      assert html =~ ~s(href="/files/#{message.attachment.id}")
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

      assert message.attachment.kind == "file"
      assert html =~ "ed-file"
      assert html =~ "notes.txt"
      assert html =~ ~s(href="/files/#{message.attachment.id}")
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

      assert message.attachment.kind == "video"
      assert html =~ "<video"
      assert html =~ ~s(<source src="/files/#{message.attachment.id}")
      assert html =~ "video/mp4"
    end

    test "swaps the full image for the thumbnail once it is ready", ctx do
      {:ok, message} =
        Chat.create_attachment_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{
          path: real_png_path()
        })

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      refute render(view) =~ "/files/#{message.attachment.id}/thumb"

      # Generating the thumbnail broadcasts on the conversation topic the view
      # is subscribed to, so the image source updates in place.
      :ok = Chat.generate_thumbnail(message.attachment)
      assert render(view) =~ "/files/#{message.attachment.id}/thumb"
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
      assert html =~ "Send message"
    end

    test "clicking your own entry routes to Settings instead", ctx do
      carol = user_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, group} = Chat.create_conversation(Scope.for_user(ctx.alice), [ctx.bob.id, carol.id])
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{group.id}")

      render_click(view, "show_profile", %{"id" => to_string(ctx.alice.id)})
      assert_redirect(view, ~p"/settings")
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
      assert profile =~ "Send message"
    end

    test "Send message from a profile opens a 1:1", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_click(view, "show_profile", %{"id" => to_string(ctx.bob.id)})
      render_click(view, "message_user", %{"id" => to_string(ctx.bob.id)})

      # Alice and Bob already share a 1:1, so it is reused.
      assert_patch(view, ~p"/app/c/#{ctx.conversation.id}")
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

    test "delete for both shows a tombstone in real time", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "regret"})

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      render_click(view, "delete_for_both", %{"id" => to_string(msg.id)})
      assert has_element?(view, "#messages-#{msg.id}", "Message deleted")
      refute has_element?(view, "#messages-#{msg.id}", "regret")
    end

    test "a previously deleted message renders as a tombstone", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "gone"})

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), msg.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")
      refute html =~ "gone"
      assert html =~ "Message deleted"
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

    test "a tombstone offers only delete-for-me", ctx do
      {:ok, msg} =
        Chat.create_message(Scope.for_user(ctx.alice), ctx.conversation.id, %{"body" => "x"})

      :ok = Chat.delete_message_for_both(Scope.for_user(ctx.alice), msg.id)

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app/c/#{ctx.conversation.id}")

      assert has_element?(view, ~s(#messages-#{msg.id} [phx-click="delete_for_me"]))
      refute has_element?(view, ~s(#messages-#{msg.id} [phx-click="delete_for_both"]))
      refute has_element?(view, ~s(#messages-#{msg.id} [phx-click="forward_prompt"]))
    end
  end
end
