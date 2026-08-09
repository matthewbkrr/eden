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

  # The coalescing window this env runs with, so the settle below can outlast it by construction
  # rather than by a number someone has to remember to keep in step.
  @window_ms Application.compile_env(:eden, :badge_coalesce_ms, 40)

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

  # A named capture, not an inline closure: :telemetry warns about local anonymous handlers because
  # it cannot optimize them, and a warning printed by every run of this file is noise that teaches
  # people to ignore warnings (#583 review).
  def handle_query(_event, _measure, meta, test_pid) do
    if meta[:source] in @aggregates, do: send(test_pid, {:aggregate_query, meta[:source]})
  end

  defp count_aggregate_queries(fun) do
    handler = {__MODULE__, System.unique_integer()}

    :telemetry.attach(handler, [:eden, :repo, :query], &__MODULE__.handle_query/4, self())

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

  # Waits for the first recompute instead of sleeping through the window, then settles for LONGER
  # than a whole window.
  #
  # The settle is not padding: a late event schedules its own window, and detaching the handler
  # before that window elapses would leave those queries uncounted — the test would report a
  # smaller number than actually happened, which is the one direction a measurement must never be
  # wrong in (#583 review).
  defp await_recompute(timeout) do
    receive do
      {:aggregate_query, source} ->
        send(self(), {:aggregate_query, source})
        Process.sleep(@window_ms + 100)
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

    # The bound is MEASURED, not chosen. How many statements one recompute runs is
    # `refresh_folders/1` and `refresh_rail/1`'s business, and pinning a number here would make
    # this test fail the day either grows a query — while saying nothing about coalescing (#583
    # review). So the same workload is measured for ONE message, and ten are required to cost no
    # more than two of those passes.
    unit =
      count_aggregate_queries(fn ->
        {:ok, _} = Chat.create_message(scope, room.id, %{"body" => "unit"})
        render(view)
        await_recompute(2_000)
        render(view)
      end)

    # BOTH sides need a floor. Moving the lower bound onto `unit` last round left the burst itself
    # with none: a burst that recomputed nothing at all would sail through `0 <= 2 * unit` — the
    # same vacuous shape this file has now been caught in twice (#583 review).
    assert queries >= 1,
           "the burst recomputed nothing at all — the badges are not being refreshed"

    assert unit >= 1, "a single message recomputed nothing — the measurement has no baseline"

    assert queries <= 2 * unit,
           "ten messages cost #{queries} aggregate queries against #{unit} for one — the burst is not being coalesced"
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
