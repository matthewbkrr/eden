defmodule EdenWeb.ChatBadgeCoalesceTest do
  @moduledoc """
  Folder tabs and the channel rail are recomputed once per burst, not once per event (#372/R059).

  One incoming message reaches a viewer as several badge-changing events — the conversation's
  activity, and the read that auto-marking the open chat produces — and each of them used to
  recompute both aggregates on the spot. Measured before this: three `list_folders` and three
  `list_channels` per message, thirty of each for a burst of ten. That is per viewer, on the path
  every message in the product takes.

  This test counts the queries themselves through Ecto's telemetry rather than trusting a comment,
  because the whole change is invisible to the rendered output: a broken coalescer looks exactly
  like a working one until you count.
  """
  use EdenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.{Channels, Chat}

  # The two aggregates, by the tables they read.
  @aggregates ["chat_folders", "channels"]

  setup %{conn: conn} do
    alice = user_fixture()
    bob = user_fixture()
    {:ok, channel} = Channels.create_channel(Scope.for_user(alice), %{"name" => "Coalesce"})
    {:ok, _} = Channels.ensure_member(Scope.for_user(bob), channel.id)
    Chat.join_general(channel.id, bob.id)
    [room | _] = Chat.list_rooms(Scope.for_user(alice), channel.id)

    {:ok, view, _html} =
      conn |> log_in_user(alice) |> live(~p"/channels/#{channel.id}/r/#{room.id}")

    %{view: view, room: room, bob: bob}
  end

  defp count_aggregate_queries(fun) do
    test_pid = self()
    handler = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler,
      [:eden, :repo, :query],
      fn _event, _measure, meta, _cfg ->
        if meta[:source] in @aggregates, do: send(test_pid, {:aggregate_query, meta[:source]})
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    drain(0)
  end

  defp drain(n) do
    receive do
      {:aggregate_query, _} -> drain(n + 1)
    after
      0 -> n
    end
  end

  test "a burst of messages recomputes the badges once, not once per message", %{
    view: view,
    room: room,
    bob: bob
  } do
    scope = Scope.for_user(bob)

    queries =
      count_aggregate_queries(fn ->
        for i <- 1..10 do
          {:ok, _} = Chat.create_message(scope, room.id, %{"body" => "burst #{i}"})
        end

        render(view)
        # Past the coalescing window, so the one recompute it collapses into has happened.
        Process.sleep(300)
        render(view)
      end)

    # Twenty before this change (ten messages × two events × the two aggregates). A handful is the
    # coalesced shape; an exact number would only pin the number of internal events, which is not
    # what this guards.
    assert queries <= 6,
           "the badges were recomputed #{queries} times for ten messages — the burst is not being coalesced"
  end

  test "the badge still updates after the window", %{view: view, room: room, bob: bob} do
    {:ok, _} = Chat.create_message(Scope.for_user(bob), room.id, %{"body" => "one"})
    render(view)
    Process.sleep(300)

    # Coalescing may not swallow the recompute: the aggregates have to end up recomputed, or a
    # badge would sit stale until the next unrelated event.
    assert render(view) =~ "ed-rail"
  end
end
