defmodule EdenWeb.PresenceTest do
  use EdenWeb.ConnCase, async: true

  alias EdenWeb.Presence

  defp tracked?(id), do: Map.has_key?(Presence.statuses(), id)

  test "tracks an online user and lists their status" do
    user = user_fixture()
    refute tracked?(user.id)

    {:ok, _ref} = Presence.track_user(self(), user.id)

    assert Presence.statuses()[user.id] == "online"
  end

  test "track_user/3 records the effective status; statuses/0 surfaces it (#102)" do
    user = user_fixture()
    {:ok, _ref} = Presence.track_user(self(), user.id, "away")

    assert Presence.statuses()[user.id] == "away"
  end

  test "manual_to_effective/1 maps manual choices to the wire vocabulary (#102)" do
    assert Presence.manual_to_effective("auto") == "online"
    assert Presence.manual_to_effective(nil) == "online"
    assert Presence.manual_to_effective("ghost") == "online"
    assert Presence.manual_to_effective("away") == "away"
    assert Presence.manual_to_effective("dnd") == "dnd"
    assert Presence.manual_to_effective("invisible") == :invisible
  end

  test "set_status to invisible untracks — appears offline to everyone (#102)" do
    user = user_fixture()
    {:ok, _ref} = Presence.track_user(self(), user.id, "online")
    assert tracked?(user.id)

    Presence.set_status(self(), user.id, "invisible")

    refute tracked?(user.id)
  end

  test "set_status updates the meta in place while staying tracked (#102)" do
    user = user_fixture()
    {:ok, _ref} = Presence.track_user(self(), user.id, "online")

    Presence.set_status(self(), user.id, "dnd")

    assert Presence.statuses()[user.id] == "dnd"
  end

  test "set_status re-tracks when returning from untracked/invisible (#102)" do
    user = user_fixture()
    # Never tracked (invisible since mount): update is a nopresence, so set_status
    # falls back to track.
    Presence.set_status(self(), user.id, "away")

    assert Presence.statuses()[user.id] == "away"
  end

  test "a status-only update really emits a presence_diff naming the user (#102)" do
    # Guards the sidebar re-stream gate against being circular: confirms the REAL
    # Phoenix.Presence diff for an away→online change carries the key in joins/leaves
    # (not just our hand-crafted test payload).
    user = user_fixture()
    Phoenix.PubSub.subscribe(Eden.PubSub, Presence.topic())
    {:ok, _ref} = Presence.track_user(self(), user.id, "online")
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}

    Presence.set_status(self(), user.id, "away")

    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload}
    key = to_string(user.id)
    assert Map.has_key?(payload.joins, key) or Map.has_key?(payload.leaves, key)
  end
end
