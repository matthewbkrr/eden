defmodule EdenWeb.PresenceTest do
  use EdenWeb.ConnCase, async: true

  alias EdenWeb.Presence

  test "tracks an online user and lists their id" do
    user = user_fixture()
    refute MapSet.member?(Presence.online_ids(), user.id)

    {:ok, _ref} = Presence.track_user(self(), user.id)

    assert MapSet.member?(Presence.online_ids(), user.id)
  end
end
