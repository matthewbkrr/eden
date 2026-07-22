defmodule Eden.Notifications.PushWorkerTest do
  use Eden.DataCase, async: true
  use Oban.Testing, repo: Eden.Repo

  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Notifications
  alias Eden.Notifications.{APNs, FCM, PushWorker, Target}

  defp scope(user), do: Scope.for_user(user)

  @payload %{
    "conversation_id" => 42,
    "message_id" => 7,
    "kind" => "dm",
    "sender_name" => "Алиса",
    "preview" => "привет!",
    "media_kind" => nil,
    "channel_id" => nil,
    "conv_title" => nil
  }

  describe "adapter deliver/2 (the inline send path)" do
    test "only enqueues a job — no HTTP, no target resolution" do
      assert :ok = APNs.deliver(123, @payload)
      assert_enqueued(worker: PushWorker, args: %{user_id: 123, kind: "apns"})

      assert :ok = FCM.deliver(456, @payload)
      assert_enqueued(worker: PushWorker, args: %{user_id: 456, kind: "fcm"})
    end
  end

  describe "perform/1" do
    test "a recipient with no registered devices is a cheap no-op" do
      user = user_fixture()

      assert :ok =
               perform_job(PushWorker, %{user_id: user.id, kind: "apns", payload: @payload})
    end

    test "pushes to each enabled device and succeeds" do
      user = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "device-token-1")
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "device-token-2")

      test_pid = self()

      Req.Test.stub(APNs, fn conn ->
        send(test_pid, {:pushed, conn.request_path})
        Req.Test.json(conn, %{})
      end)

      assert :ok = perform_job(PushWorker, %{user_id: user.id, kind: "apns", payload: @payload})
      assert_received {:pushed, "/3/device/device-token-1"}
      assert_received {:pushed, "/3/device/device-token-2"}
    end

    test "a dead token (410) is pruned and the job still succeeds" do
      user = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "dead-device-1")

      Req.Test.stub(APNs, fn conn ->
        conn
        |> Plug.Conn.put_status(410)
        |> Req.Test.json(%{"reason" => "Unregistered"})
      end)

      assert :ok = perform_job(PushWorker, %{user_id: user.id, kind: "apns", payload: @payload})
      assert Notifications.targets_for(user.id, "apns") == []
    end

    test "a transient transport error fails the job so Oban retries" do
      user = user_fixture()
      {:ok, _} = Notifications.upsert_target(scope(user), "apns", "flaky-device-1")

      Req.Test.stub(APNs, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"reason" => "ServiceUnavailable"})
      end)

      assert {:error, {:apns, 503, _}} =
               perform_job(PushWorker, %{user_id: user.id, kind: "apns", payload: @payload})

      # The target survives — only the provider's explicit verdict prunes.
      assert [%Target{}] = Notifications.targets_for(user.id, "apns")
    end
  end
end
