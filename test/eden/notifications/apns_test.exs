defmodule Eden.Notifications.APNsTest do
  # Transport shape only (no DB): what actually goes over the wire to Apple.
  # The fake EC key + Req.Test plug come from test_helper.exs.
  use ExUnit.Case, async: true

  alias Eden.Notifications.APNs

  @rendered %{
    title: "Алиса",
    body: "привет!",
    data: %{"conversation_id" => "42", "message_id" => "7"}
  }

  setup do
    # The provider JWT is cached process-globally for ~45 min — start each test
    # from a cold cache so assertions see a freshly-minted token.
    :persistent_term.erase({APNs, :jwt})
    :ok
  end

  test "POSTs the alert with the provider-token headers Apple requires" do
    test_pid = self()

    Req.Test.stub(APNs, fn conn ->
      send(test_pid, {:req, conn})
      Req.Test.json(conn, %{})
    end)

    assert :ok = APNs.push("abcdef0123456789", @rendered)
    assert_received {:req, conn}

    assert conn.method == "POST"
    assert conn.request_path == "/3/device/abcdef0123456789"
    assert Plug.Conn.get_req_header(conn, "apns-topic") == ["ru.ihi.chat"]
    assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["alert"]
    assert Plug.Conn.get_req_header(conn, "apns-priority") == ["10"]

    # aps.alert carries the rendered text; the routing data rides top-level.
    assert {:ok, body, _} = Plug.Conn.read_body(conn)
    assert %{"aps" => %{"alert" => alert, "sound" => "default"}} = Jason.decode!(body)
    assert alert == %{"title" => "Алиса", "body" => "привет!"}
    assert Jason.decode!(body)["conversation_id"] == "42"
  end

  test "the bearer JWT is a decodable ES256 provider token" do
    test_pid = self()

    Req.Test.stub(APNs, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      Req.Test.json(conn, %{})
    end)

    assert :ok = APNs.push("abcdef0123456789", @rendered)
    assert_received {:auth, ["bearer " <> jwt]}

    assert [header, claims, signature] = String.split(jwt, ".")

    assert %{"alg" => "ES256", "kid" => "TESTKEY123"} =
             header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert %{"iss" => "TESTTEAM12", "iat" => iat} =
             claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert is_integer(iat)
    # JWT ES256 signatures are raw r || s — exactly 64 bytes for P-256.
    assert byte_size(Base.url_decode64!(signature, padding: false)) == 64
  end

  test "410 maps to :unregistered, other failures to a retryable error" do
    Req.Test.stub(APNs, fn conn ->
      case conn.request_path do
        "/3/device/dead" ->
          conn |> Plug.Conn.put_status(410) |> Req.Test.json(%{"reason" => "Unregistered"})

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"reason" => "InternalServerError"})
      end
    end)

    assert :unregistered = APNs.push("dead", @rendered)
    assert {:error, {:apns, 500, _}} = APNs.push("flaky", @rendered)
  end
end
