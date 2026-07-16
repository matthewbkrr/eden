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

    %{alice: alice, bob: bob, attachment: hd(message.attachments), png: body}
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
      # The 404 body is text/plain and carries no attachment disposition inherited from the
      # success path — a browser must show the error, not download it under the original name
      # (#374/R170).
      assert get_resp_header(conn, "content-disposition") == []
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
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
      # A 416 is an error — never cached immutable for a year (#374/R167).
      assert get_resp_header(conn, "cache-control") == []
    end

    test "a range unit is case-insensitive per RFC 9110 (#374/R169)", %{
      conn: conn,
      alice: alice,
      attachment: attachment,
      png: png
    } do
      conn =
        conn
        |> log_in_user(alice)
        |> put_req_header("range", "Bytes=0-3")
        |> get(~p"/files/#{attachment.id}")

      assert conn.status == 206
      assert response(conn, 206) == binary_part(png, 0, 4)
      assert get_resp_header(conn, "content-range") == ["bytes 0-3/#{byte_size(png)}"]
    end

    test "inline media carries its filename so Save-as isn't the URL id (#374/R171)", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      path = image_path(@png_signature <> "img")

      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: path,
          filename: "sunset.png"
        })

      conn = conn |> log_in_user(alice) |> get(~p"/files/#{hd(message.attachments).id}")
      [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~ "inline"
      assert disposition =~ ~s(filename="sunset.png")
      assert disposition =~ "filename*=UTF-8''sunset.png"
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

      conn = conn |> log_in_user(alice) |> get(~p"/files/#{hd(message.attachments).id}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ~s(filename="quarterly report.txt")
      assert disposition =~ "filename*=UTF-8''quarterly%20report.txt"
    end

    test "a metacharacter surviving name sanitization can't break out of the header (#238)", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])
      path = image_path("just plain text, not an image")

      # `Attachment.sanitize_filename/1` already strips `"` `\` /control at create, but a
      # `;` (the Content-Disposition param separator) survives it and reaches the header.
      {:ok, message} =
        Chat.create_attachment_message(scope(alice), conv.id, %{
          path: path,
          filename: "ev;il.txt"
        })

      conn = conn |> log_in_user(alice) |> get(~p"/files/#{hd(message.attachments).id}")
      [disposition] = get_resp_header(conn, "content-disposition")

      # The quoted ASCII fallback neutralizes the `;` to `_`, so nothing after the opening
      # quote can be read as an extra header parameter...
      assert disposition =~ ~s(filename="ev_il.txt")
      # ...while the accurate name still rides the percent-encoded filename*.
      assert disposition =~ "filename*=UTF-8''ev%3Bil.txt"
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
      :ok = Chat.generate_thumbnail(hd(message.attachments))

      conn = conn |> log_in_user(bob) |> get(~p"/files/#{hd(message.attachments).id}/thumb")
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
