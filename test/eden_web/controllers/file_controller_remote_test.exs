defmodule EdenWeb.FileControllerRemoteTest do
  # async: false — swaps the global Storage adapter to an in-memory one WITHOUT local_path/1, so the
  # controller takes the REMOTE branch (send_remote / read_range), which the Local suite never
  # exercises (#374/R168). The whole Range/206/416/404 remote path is otherwise untested.
  use EdenWeb.ConnCase, async: false

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  # A minimal in-memory remote adapter: bytes live in Application env (keyed by storage key), there
  # is NO local_path/1 (→ facade returns :error → the controller's remote path), and read_range/2
  # returns ONLY the requested window — so a correct 206 body proves the ranged read, not a full one.
  defmodule Mem do
    @behaviour Eden.Storage

    def store(key, bytes), do: Application.put_env(:eden, __MODULE__, Map.put(map(), key, bytes))
    def wipe, do: Application.put_env(:eden, __MODULE__, %{})
    defp map, do: Application.get_env(:eden, __MODULE__, %{})

    @impl true
    def read(key) do
      case Map.get(map(), key) do
        nil -> {:error, {:http, 404}}
        bytes -> {:ok, bytes}
      end
    end

    @impl true
    def read_range(key, {first, last}) do
      with {:ok, bytes} <- read(key) do
        total = byte_size(bytes)

        # Mirror S3: a range past the real end (object smaller than the DB byte_size) is 416.
        if first < total,
          do: {:ok, binary_part(bytes, first, min(last, total - 1) - first + 1)},
          else: {:error, {:http, 416}}
      end
    end

    @impl true
    def exists?(key), do: Map.has_key?(map(), key)
    # put/put_binary actually store, so create_attachment_message + generate_thumbnail seed Mem.
    @impl true
    def put(key, path) do
      with {:ok, bytes} <- File.read(path) do
        store(key, bytes)
        :ok
      end
    end

    @impl true
    def put_binary(key, bin) do
      store(key, bin)
      :ok
    end

    @impl true
    def delete(_key), do: :ok
  end

  defp scope(user), do: Scope.for_user(user)

  setup do
    prev = Application.get_env(:eden, Eden.Storage)
    Application.put_env(:eden, Eden.Storage, adapter: Mem)
    Mem.wipe()
    on_exit(fn -> Application.put_env(:eden, Eden.Storage, prev) end)

    alice = user_fixture(%{username: "rem_alice"})
    bob = user_fixture(%{username: "rem_bob"})
    {:ok, conv} = Chat.create_conversation(scope(alice), [bob.id])

    body = @png_signature <> String.duplicate("abcdefghij", 50)
    path = Path.join(System.tmp_dir!(), "rem-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)

    {:ok, message} = Chat.create_attachment_message(scope(alice), conv.id, %{path: path})
    att = hd(message.attachments)
    # put already stored the original during create; pin the exact bytes so the range assertions
    # aren't at the mercy of any create-time transform.
    Mem.store(att.storage_key, body)

    %{alice: alice, att: att, body: body}
  end

  test "serves the whole object with 200 on the remote path", ctx do
    conn = ctx.conn |> log_in_user(ctx.alice) |> get(~p"/files/#{ctx.att.id}")
    assert response(conn, 200) == ctx.body
  end

  test "serves a byte range as 206 via read_range (not a full read)", ctx do
    conn =
      ctx.conn
      |> log_in_user(ctx.alice)
      |> put_req_header("range", "bytes=0-9")
      |> get(~p"/files/#{ctx.att.id}")

    assert conn.status == 206
    assert response(conn, 206) == binary_part(ctx.body, 0, 10)
    assert get_resp_header(conn, "content-range") == ["bytes 0-9/#{byte_size(ctx.body)}"]
  end

  test "serves a suffix range on the remote path", ctx do
    conn =
      ctx.conn
      |> log_in_user(ctx.alice)
      |> put_req_header("range", "bytes=-5")
      |> get(~p"/files/#{ctx.att.id}")

    assert conn.status == 206
    assert response(conn, 206) == binary_part(ctx.body, byte_size(ctx.body) - 5, 5)
  end

  test "returns 416 for an unsatisfiable range, uncached", ctx do
    conn =
      ctx.conn
      |> log_in_user(ctx.alice)
      |> put_req_header("range", "bytes=999999-")
      |> get(~p"/files/#{ctx.att.id}")

    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */#{byte_size(ctx.body)}"]
    assert get_resp_header(conn, "cache-control") == []
  end

  test "returns 404 when the remote object is gone, uncached + no disposition", ctx do
    Mem.wipe()
    conn = ctx.conn |> log_in_user(ctx.alice) |> get(~p"/files/#{ctx.att.id}")

    assert response(conn, 404)
    assert get_resp_header(conn, "cache-control") == []
    assert get_resp_header(conn, "content-disposition") == []
  end

  test "a remote THUMBNAIL (unknown size) still honors Range → 206, not a 200 (#403 review)",
       ctx do
    # A real image so the worker produces a thumbnail; its bytes land in Mem via put_binary.
    {:ok, img} = Image.new(800, 600, color: [30, 140, 90])
    {:ok, png} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "thumbsrc-#{System.unique_integer([:positive])}")
    File.write!(path, png)
    on_exit(fn -> File.rm(path) end)

    peer = user_fixture(%{username: "thumb_peer"})
    {:ok, conv} = Chat.create_conversation(scope(ctx.alice), [peer.id])
    {:ok, message} = Chat.create_attachment_message(scope(ctx.alice), conv.id, %{path: path})
    att = hd(message.attachments)
    :ok = Chat.generate_thumbnail(att)

    conn =
      ctx.conn
      |> log_in_user(ctx.alice)
      |> put_req_header("range", "bytes=0-9")
      |> get(~p"/files/#{att.id}/thumb")

    assert conn.status == 206
    assert byte_size(response(conn, 206)) == 10
  end

  test "an object that shrank below its DB byte_size yields a 416, not a 404 (#403 review)",
       ctx do
    # Overwrite the stored blob with FEWER bytes than the recorded byte_size, then request a range
    # that's satisfiable against the DB size but not the real object.
    Mem.store(ctx.att.storage_key, "short")

    conn =
      ctx.conn
      |> log_in_user(ctx.alice)
      |> put_req_header("range", "bytes=100-200")
      |> get(~p"/files/#{ctx.att.id}")

    assert conn.status == 416
    assert get_resp_header(conn, "cache-control") == []
  end
end
