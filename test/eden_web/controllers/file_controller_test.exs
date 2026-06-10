defmodule EdenWeb.FileControllerTest do
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp scope(user), do: Scope.for_user(user)

  defp image_path(bytes) do
    path = Path.join(System.tmp_dir!(), "img-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  setup do
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    bob = user_fixture(%{username: "bob", display_name: "Bob"})
    {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

    body = @png_signature <> "fake-png-body"
    path = image_path(body)
    {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})

    %{alice: alice, bob: bob, attachment: message.attachment, png: body}
  end

  describe "GET /files/:id" do
    test "serves the bytes to a conversation member", %{
      conn: conn,
      alice: alice,
      attachment: attachment,
      png: png
    } do
      conn = conn |> log_in_user(alice) |> get(~p"/files/#{attachment.id}")

      assert response(conn, 200) == png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "content-disposition") == ["inline"]
      assert ["private, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
    end

    test "also serves the other member of the conversation", %{
      conn: conn,
      bob: bob,
      attachment: attachment,
      png: png
    } do
      conn = conn |> log_in_user(bob) |> get(~p"/files/#{attachment.id}")
      assert response(conn, 200) == png
    end

    test "returns 404 for a non-member", %{conn: conn, attachment: attachment} do
      carol = user_fixture(%{username: "carol"})
      conn = conn |> log_in_user(carol) |> get(~p"/files/#{attachment.id}")
      assert response(conn, 404)
    end

    test "returns 404 for an unknown id", %{conn: conn, alice: alice} do
      conn = conn |> log_in_user(alice) |> get(~p"/files/999999")
      assert response(conn, 404)
    end

    test "returns 404 for a non-integer id", %{conn: conn, alice: alice} do
      conn = conn |> log_in_user(alice) |> get(~p"/files/abc")
      assert response(conn, 404)
    end

    test "redirects an unauthenticated request to login", %{conn: conn, attachment: attachment} do
      conn = get(conn, ~p"/files/#{attachment.id}")
      assert redirected_to(conn) == ~p"/login"
    end

    test "a 404 for a blob missing on disk is not cached immutably", %{
      conn: conn,
      alice: alice,
      attachment: attachment
    } do
      # Delete the stored blob out-of-band, then request it.
      :ok = Eden.Storage.delete(attachment.storage_key)

      conn = conn |> log_in_user(alice) |> get(~p"/files/#{attachment.id}")
      assert response(conn, 404)
      assert get_resp_header(conn, "cache-control") == []
    end
  end

  describe "GET /files/:id range + disposition" do
    test "advertises byte-range support", %{conn: conn, alice: alice, attachment: attachment} do
      conn = conn |> log_in_user(alice) |> get(~p"/files/#{attachment.id}")
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "serves a byte range as 206 partial content", %{
      conn: conn,
      alice: alice,
      attachment: attachment,
      png: png
    } do
      conn =
        conn
        |> log_in_user(alice)
        |> put_req_header("range", "bytes=0-3")
        |> get(~p"/files/#{attachment.id}")

      assert conn.status == 206
      assert response(conn, 206) == binary_part(png, 0, 4)
      assert get_resp_header(conn, "content-range") == ["bytes 0-3/#{byte_size(png)}"]
    end

    test "serves a suffix range", %{conn: conn, alice: alice, attachment: attachment, png: png} do
      total = byte_size(png)

      conn =
        conn
        |> log_in_user(alice)
        |> put_req_header("range", "bytes=-5")
        |> get(~p"/files/#{attachment.id}")

      assert conn.status == 206
      assert response(conn, 206) == binary_part(png, total - 5, 5)
    end

    test "returns 416 for an unsatisfiable range", %{
      conn: conn,
      alice: alice,
      attachment: attachment,
      png: png
    } do
      conn =
        conn
        |> log_in_user(alice)
        |> put_req_header("range", "bytes=999999-")
        |> get(~p"/files/#{attachment.id}")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */#{byte_size(png)}"]
    end

    test "serves a generic file as a download with its sanitized name", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      path = image_path("just plain text, not an image")

      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: path,
          filename: "quarterly report.txt"
        })

      conn = conn |> log_in_user(alice) |> get(~p"/files/#{message.attachment.id}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ~s(filename="quarterly report.txt")
      assert disposition =~ "filename*=UTF-8''quarterly%20report.txt"
    end
  end

  describe "GET /files/:id/thumb" do
    test "returns 404 before the thumbnail has been generated", %{
      conn: conn,
      alice: alice,
      attachment: attachment
    } do
      conn = conn |> log_in_user(alice) |> get(~p"/files/#{attachment.id}/thumb")
      assert response(conn, 404)
    end

    test "serves the generated thumbnail as a member", %{conn: conn, alice: alice, bob: bob} do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

      {:ok, img} = Image.new(1000, 700, color: [10, 200, 90])
      {:ok, png} = Image.write(img, :memory, suffix: ".png")
      path = image_path(png)

      {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
      :ok = Chat.generate_thumbnail(message.attachment)

      conn = conn |> log_in_user(bob) |> get(~p"/files/#{message.attachment.id}/thumb")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
