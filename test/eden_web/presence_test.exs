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

  test "a status-only update really emits a presence_diff naming the user (#102)" do
    # Guards the sidebar re-stream gate against being circular: confirms the REAL
    # Phoenix.Presence diff for an away→online change carries the key in joins/leaves
    # (not just our hand-crafted test payload).
    user = user_fixture()
    Phoenix.PubSub.subscribe(Eden.PubSub, Presence.topic())
    {:ok, _ref} = Presence.track_user(self(), user.id, "online")
    key = to_string(user.id)

    # The GLOBAL topic also carries other async tests' presence diffs — wait for the one that names
    # THIS user (a plain assert_receive could match a foreign diff and fail the key check, flaking CI).
    assert_diff_names(key)

    Presence.set_status(self(), user.id, "away")

    assert_diff_names(key)
  end

  # Drain presence_diffs on the shared global topic until one names `key` in joins or leaves.
  defp assert_diff_names(key) do
    receive do
      %Phoenix.Socket.Broadcast{event: "presence_diff", payload: p} ->
        if Map.has_key?(p.joins, key) or Map.has_key?(p.leaves, key),
          do: :ok,
          else: assert_diff_names(key)
    after
      1000 -> flunk("no presence_diff named #{key}")
    end
  end
end
