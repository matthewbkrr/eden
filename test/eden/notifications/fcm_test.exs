defmodule Eden.Notifications.FCMTest do
  # Transport shape only (no DB): the OAuth exchange + the v1 send. The fake
  # RSA service account + Req.Test plug come from test_helper.exs.
  use ExUnit.Case, async: true

  alias Eden.Notifications.FCM

  @rendered %{
    title: "Алиса — Экспедиция",
    body: "🎥 Видео · закат",
    data: %{"conversation_id" => "42", "message_id" => "7", "channel_id" => "3"}
  }

  setup do
    # The OAuth token is cached process-globally for ~50 min — start each test
    # from a cold cache so the stub sees the token exchange too.
    :persistent_term.erase({FCM, :oauth})
    :ok
  end

  test "exchanges a signed service-account assertion, then sends the v1 message" do
    test_pid = self()

    Req.Test.stub(FCM, fn conn ->
      case conn.host do
        "oauth2.example.com" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:oauth, URI.decode_query(body)})
          Req.Test.json(conn, %{"access_token" => "test-access-token", "expires_in" => 3600})

        "fcm.googleapis.com" ->
          send(test_pid, {:send, conn})
          Req.Test.json(conn, %{"name" => "projects/eden-test/messages/1"})
      end
    end)

    assert :ok = FCM.push("registration-token-1", @rendered)

    assert_received {:oauth, %{"grant_type" => grant, "assertion" => assertion}}
    assert grant == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert [header, claims, _sig] = String.split(assertion, ".")

    assert %{"alg" => "RS256"} = header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    decoded_claims = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert decoded_claims["iss"] == "eden-test@example.iam.gserviceaccount.com"
    assert decoded_claims["scope"] =~ "firebase.messaging"

    assert_received {:send, conn}
    assert conn.request_path == "/v1/projects/eden-test/messages:send"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-token"]

    assert {:ok, body, _} = Plug.Conn.read_body(conn)
    assert %{"message" => message} = Jason.decode!(body)
    assert message["token"] == "registration-token-1"

    assert message["notification"] == %{
             "title" => "Алиса — Экспедиция",
             "body" => "🎥 Видео · закат"
           }

    assert message["data"]["channel_id"] == "3"
    assert message["android"]["priority"] == "HIGH"
  end

  test "the OAuth token is cached across pushes" do
    test_pid = self()

    Req.Test.stub(FCM, fn conn ->
      case conn.host do
        "oauth2.example.com" ->
          send(test_pid, :oauth_exchange)
          Req.Test.json(conn, %{"access_token" => "test-access-token"})

        _ ->
          Req.Test.json(conn, %{})
      end
    end)

    assert :ok = FCM.push("registration-token-1", @rendered)
    assert :ok = FCM.push("registration-token-2", @rendered)

    assert_received :oauth_exchange
    refute_received :oauth_exchange
  end

  test "a rejected access token (401) drops the OAuth cache so the retry re-exchanges" do
    Req.Test.stub(FCM, fn conn ->
      case conn.host do
        "oauth2.example.com" ->
          Req.Test.json(conn, %{"access_token" => "test-access-token"})

        "fcm.googleapis.com" ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"status" => "UNAUTHENTICATED"}})
      end
    end)

    assert {:error, {:fcm, 401, _}} = FCM.push("registration-token-1", @rendered)
    assert :persistent_term.get({FCM, :oauth}, nil) == nil
  end

  test "404 maps to :unregistered (the v1 UNREGISTERED verdict)" do
    Req.Test.stub(FCM, fn conn ->
      case conn.host do
        "oauth2.example.com" ->
          Req.Test.json(conn, %{"access_token" => "test-access-token"})

        "fcm.googleapis.com" ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"status" => "NOT_FOUND"}})
      end
    end)

    assert :unregistered = FCM.push("gone-registration", @rendered)
  end
end
