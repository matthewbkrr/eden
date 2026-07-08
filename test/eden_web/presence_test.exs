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

  test "effective/2 folds the manual status with idle (auto-away, #102)" do
    # auto follows idle; manual statuses ignore it.
    assert Presence.effective("auto", false) == "online"
    assert Presence.effective("auto", true) == "away"
    assert Presence.effective("auto") == "online"
    assert Presence.effective("away", true) == "away"
    assert Presence.effective("dnd", true) == "dnd"
    assert Presence.effective("invisible", true) == :invisible
    assert Presence.effective(nil, true) == "online"
  end

  describe "conversation-scoped presence (#209)" do
    test "track_conv publishes online ONLY on that conversation's topic — not global, not others" do
      user = user_fixture()
      {:ok, _ref} = Presence.track_conv(self(), 1, user.id)

      assert Presence.conv_statuses(1)[user.id] == "online"
      # The whole point: scoped, never global (sidebar/profile stay offline) and never leaks to
      # a different conversation.
      refute Map.has_key?(Presence.statuses(), user.id)
      assert Presence.conv_statuses(2) == %{}
    end

    test "untrack_conv removes the scoped track" do
      user = user_fixture()
      {:ok, _ref} = Presence.track_conv(self(), 1, user.id)
      assert Presence.conv_statuses(1)[user.id] == "online"

      Presence.untrack_conv(self(), 1, user.id)

      refute Map.has_key?(Presence.conv_statuses(1), user.id)
    end

    test "a scoped track auto-clears when its process exits" do
      user = user_fixture()
      parent = self()
      Phoenix.PubSub.subscribe(Eden.PubSub, Presence.conv_topic(1))

      pid =
        spawn(fn ->
          {:ok, _} = Presence.track_conv(self(), 1, user.id)
          send(parent, :tracked)
          Process.sleep(:infinity)
        end)

      assert_receive :tracked
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
      assert Presence.conv_statuses(1)[user.id] == "online"

      Process.exit(pid, :kill)

      # Presence monitors the tracked pid and untracks on its :DOWN — a real leave diff.
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
      assert Map.has_key?(leaves, to_string(user.id))
      refute Map.has_key?(Presence.conv_statuses(1), user.id)
    end
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
