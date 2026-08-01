defmodule EdenWeb.SidebarCostTest do
  # What opening a chat costs, in QUERIES (#514).
  #
  # Bytes were the wrong instrument here and measured zero: re-streaming a sidebar whose contents
  # did not change produces almost no diff, so the whole cost is server-side. Counting queries
  # through Ecto telemetry is what makes it visible — the same switch #514's first half needed.
  use EdenWeb.ConnCase

  import Phoenix.LiveViewTest
  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat

  # Measured on this fixture: 19 before, 12 after. The threshold sits between them rather than at
  # the achieved number — it separates "the sidebar is rebuilt on every navigation" from "it is
  # not", which is the thing that must not come back. It does NOT scale with the chat list, and
  # that is the point: `list_conversations/2` has no LIMIT.
  @open_budget 16

  defp scope(u), do: Scope.for_user(u)

  test "opening a chat does not rebuild the sidebar", %{conn: conn} do
    alice = user_fixture(%{username: "scalice"})

    convs =
      for i <- 1..8 do
        other = user_fixture(%{username: "scpeer#{i}"})
        {:ok, c} = Chat.create_conversation(scope(alice), [other.id])
        {:ok, _} = Chat.create_message(scope(other), c.id, %{"body" => "hi #{i}"})
        c
      end

    {:ok, view, _} = live(log_in_user(conn, alice), ~p"/app")

    parent = self()
    handler = "sc-#{System.unique_integer([:positive])}"
    view_pid = view.pid

    # The handler runs INSIDE the process issuing the query, so comparing to the LiveView's pid
    # keeps other async tests out of the count.
    :telemetry.attach(
      handler,
      [:eden, :repo, :query],
      fn _e, _m, _meta, _c -> if self() == view_pid, do: send(parent, :q) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # No sleep, and that is the point (#544 review). `render/1` is a synchronous call INTO the
    # LiveView process, and Erlang guarantees message order between a given pair of processes — so
    # once its reply is in this mailbox, every `:q` the handler sent while handling the patch is
    # already in there too, ahead of the reply. A wall-clock wait would be both slower and a race
    # in the direction that hides a regression: undercounting makes this budget pass.
    drain = fn ->
      d = fn d, n -> receive do: (:q -> d.(d, n + 1)), after: (0 -> n) end
      d.(d, 0)
    end

    _ = render(view)
    _ = drain.()

    # `render_patch/2` is itself the barrier — a synchronous call into the LiveView, so by the
    # time it returns every query the patch issued is already counted.
    #
    # Deliberately NOT followed by another `render/1` (#544 review). That would let an ASYNC
    # message land and be counted too, and one always does here: opening a 1:1 publishes
    # presence, the diff comes back, and `presence_diff` re-streams the sidebar for another
    # ~7 queries. Real, and next on #514's list — but not what this budget is about, and folding
    # it in would give a navigation regression somewhere to hide.
    render_patch(view, "/app/c/#{hd(convs).id}")
    queries = drain.()

    assert queries > 0, "nothing was measured — the telemetry handler stopped matching"

    assert queries <= @open_budget,
           "opening a chat cost #{queries} queries (budget #{@open_budget}) — " <>
             "the sidebar is being rebuilt for the active wash and the unread badge again, " <>
             "which `.InstantNav` already did at tap time"
  end
end
