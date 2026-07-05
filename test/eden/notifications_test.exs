defmodule Eden.NotificationsTest do
  # No DB — the Web adapter is pure PubSub. Recipient SELECTION (which needs the DB) is
  # Chat's job and is covered in chat_test's "notification gating" describe; here we only
  # prove the delivery seam fans an already-chosen recipient set out over the transport.
  use ExUnit.Case, async: true

  alias Eden.Accounts.{Scope, User}
  alias Eden.Notifications
  alias Eden.Notifications.Web

  defp scope(id), do: %Scope{user: %User{id: id}}

  describe "topic/1 and subscribe/1" do
    test "topic/1 is the per-user notify topic, delegating to the Web adapter" do
      assert Notifications.topic(7) == "user:7:notify"
      assert Notifications.topic(7) == Web.topic(7)
    end

    test "subscribe/1 subscribes the scoped user to their own notify stream" do
      assert :ok = Notifications.subscribe(scope(101))
      Web.deliver(101, %{conversation_id: 1, preview: "hi"})
      assert_receive {:notify, %{conversation_id: 1, preview: "hi"}}
    end
  end

  describe "deliver/2" do
    test "fans the same payload out to every recipient" do
      Phoenix.PubSub.subscribe(Eden.PubSub, Web.topic(201))
      Phoenix.PubSub.subscribe(Eden.PubSub, Web.topic(202))

      payload = %{conversation_id: 9, preview: "yo"}
      assert :ok = Notifications.deliver([201, 202], payload)

      # This process is subscribed to both recipients' topics → two deliveries.
      assert_receive {:notify, ^payload}
      assert_receive {:notify, ^payload}
    end

    test "an empty recipient list is a no-op" do
      assert :ok = Notifications.deliver([], %{conversation_id: 1})
      refute_receive {:notify, _}, 30
    end

    test "delivers nothing to a user who isn't in the recipient set" do
      Phoenix.PubSub.subscribe(Eden.PubSub, Web.topic(301))
      assert :ok = Notifications.deliver([302], %{conversation_id: 1})
      refute_receive {:notify, _}, 30
    end
  end
end
