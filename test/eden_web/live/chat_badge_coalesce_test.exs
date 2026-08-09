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

    %{view: view, room: room, alice: alice, bob: bob}
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

    # `after`, not a plain call: a raising body would otherwise leave the handler attached for the
    # rest of the suite, counting queries in tests that never asked (#583 review).
    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain(0)
  end

  defp drain(n) do
    receive do
      {:aggregate_query, _} -> drain(n + 1)
    after
      0 -> n
    end
  end

  # Re-renders until the rail badge carries its count, or gives up. Cheaper than a fixed sleep, and
  # it fails with the render in hand rather than with a bare timeout.
  defp await_badge(view, timeout) when timeout > 0 do
    html = render(view)

    if html =~ ~r/ed-rail__badge[^>]*>\s*1\s*</ do
      html
    else
      Process.sleep(25)
      await_badge(view, timeout - 25)
    end
  end

  defp await_badge(view, _timeout), do: render(view)

  # Waits for the recompute rather than sleeping through the window: it returns the moment the
  # first aggregate query lands, so the test costs what the mechanism costs instead of a fixed
  # second of wall clock (#583 review). The short settle after it is for a possible second window.
  defp await_recompute(timeout) do
    receive do
      {:aggregate_query, source} ->
        send(self(), {:aggregate_query, source})
        Process.sleep(60)
    after
      timeout -> :timeout
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

        # The window is widened in config/test.exs so the burst lands in ONE of them; this returns
        # the moment that recompute has run, instead of sleeping through a fixed second.
        await_recompute(2_000)
        render(view)
      end)

    # Both bounds matter, and each catches a different way of being wrong.
    #
    # The upper one is no longer a guess about machine speed: the window is widened in the test env
    # (`config/test.exs`), so ten inserts and their broadcasts land inside ONE of them on any box,
    # and the coalesced answer is a small constant. Four leaves room for the read broadcast to
    # arrive in a second window without ever admitting one recompute per message (#583 review).
    #
    # The lower one is not a formality: an upper bound alone is satisfied by deleting the recompute
    # altogether, which is the same vacuous shape this file was already caught in once.
    assert queries >= 1,
           "the badges were never recomputed at all — the aggregates are not being refreshed"

    assert queries <= 4,
           "the badges were recomputed #{queries} times for ten messages — the burst is not being coalesced"
  end

  test "the badge itself catches up after the window", %{view: view, alice: alice, bob: bob} do
    # A DM, NOT the open room: a message in the room the viewer is looking at is auto-read, so its
    # badge would legitimately stay at zero and prove nothing. The messenger badge on the rail is
    # an aggregate this session must recompute to learn about.
    {:ok, dm} = Chat.create_conversation(Scope.for_user(bob), [alice.id])
    refute render(view) =~ "ed-rail__badge"

    {:ok, _} = Chat.create_message(Scope.for_user(bob), dm.id, %{"body" => "unread one"})
    # Polled, not slept through: the badge is the observable end of the recompute, so waiting for
    # IT costs what the mechanism costs (#583 review).
    await_badge(view, 2_000)

    # The VALUE, not the container. Asserting the rail markup exists proved nothing — it renders
    # whether or not anything was recomputed, so the test passed with the recompute deleted, which
    # is the one failure it was written to catch (#583 review, unanimous).
    html = render(view)

    assert html =~ ~r/ed-rail__badge[^>]*>\s*1\s*</,
           "the rail badge does not read 1 after one unread DM — the aggregate was never recomputed"
  end
end
