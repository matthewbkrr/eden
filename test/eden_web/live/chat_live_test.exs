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

  describe "folders" do
    setup [:setup_conversation]

    test "no folder tabs until the user has a folder", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, html} = live(conn, ~p"/app")
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

    test "the All Chats tab renders at its stored position", ctx do
      scope = Scope.for_user(ctx.alice)
      {:ok, work} = Chat.create_folder(scope, %{"name" => "Work"})
      :ok = Chat.reorder_folders(scope, [to_string(work.id), "all"])

      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")

      # Work's tab comes before the All Chats tab in the carousel.
      [nav] = Regex.run(~r/<nav class="ed-folders".*?<\/nav>/s, html)
      assert [work_at, all_at] = [:binary.match(nav, "Work"), :binary.match(nav, "All Chats")]
      assert elem(work_at, 0) < elem(all_at, 0)
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
