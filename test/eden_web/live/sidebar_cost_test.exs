defmodule EdenWeb.SidebarCostTest do
  # Whether opening a chat re-loads the conversation LIST (#514).
  #
  # This started as a budget on total queries and that instrument turned out to be unusable: the
  # count drifts with async traffic the LiveView happens to process inside the window (presence
  # diffs, PubSub), and measured across runs it ranged 12–23 for the same navigation. A threshold
  # inside that band fails at random, which teaches people to ignore it — so the budget is gone.
  #
  # What replaced it is specific and binary: count only the SIDEBAR'S OWN query — the one
  # `Chat.list_conversations/2` issues — and assert it does not run at all on a navigation. One
  # before this change, none after. Nothing else in the system can make that number move.
  use EdenWeb.ConnCase

  import Phoenix.LiveViewTest
  import Eden.AccountsFixtures

  alias Eden.Accounts.Scope
  alias Eden.Chat

  defp scope(u), do: Scope.for_user(u)

  # `list_conversations/2` is the only place that joins memberships onto conversations AND orders
  # by activity, so this shape identifies it without depending on a function name the telemetry
  # does not carry. The ordering clause is what separates it from the authorization lookup that
  # opening a chat does, which joins the same two tables — without it this counted 2 where the
  # answer is 0.
  #
  # Deliberately no `c0.` in the pattern (#547 review): Ecto's generated alias is not part of the
  # contract, and pinning it would make a refactor look like a regression. A shape that stops
  # matching altogether is caught by the reference assertion below, loudly.
  defp sidebar_query?(sql) do
    String.contains?(sql, ~s(FROM "conversations")) and
      String.contains?(sql, ~s(INNER JOIN "memberships")) and
      String.contains?(sql, ~s(ORDER BY )) and String.contains?(sql, ~s("last_message_at" DESC))
  end

  # Attaches the query watcher to this view and returns a drain function. Attached AFTER mount on
  # purpose: mount legitimately loads the list once, and counting it would say nothing.
  defp watch(view) do
    parent = self()
    handler = "sc-#{System.unique_integer([:positive])}"
    view_pid = view.pid

    :telemetry.attach(
      handler,
      [:eden, :repo, :query],
      fn _e, _m, meta, _c ->
        if self() == view_pid, do: send(parent, {:q, meta[:query] || ""})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    drain = fn ->
      d = fn d, acc -> receive do: ({:q, sql} -> d.(d, [sql | acc])), after: (0 -> acc) end
      d.(d, [])
    end

    {drain, handler}
  end

  test "opening a chat does not re-load the conversation list", %{conn: conn} do
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
      fn _e, _m, meta, _c ->
        if self() == view_pid, do: send(parent, {:q, meta[:query] || ""})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    drain = fn ->
      d = fn d, acc -> receive do: ({:q, sql} -> d.(d, [sql | acc])), after: (0 -> acc) end
      d.(d, [])
    end

    # First establish that the shape still matches something, using a path that is SUPPOSED to
    # reload the list: picking a folder. Without this the whole test would quietly pass on a
    # predicate that stopped matching anything at all — the failure mode a "count of zero" invites.
    # (Mount's own load happens before the handler is attached, so it cannot serve as the check.)
    render_click(view, "select_folder", %{"id" => "all"})
    _ = render(view)
    reference = drain.() |> Enum.count(&sidebar_query?/1)

    assert reference > 0,
           "the query shape no longer matches the sidebar's own load — this test would now " <>
             "pass whatever the code does"

    # `render_patch/2` is a synchronous call into the LiveView, so by the time it returns every
    # query the patch issued has already been counted.
    render_patch(view, "/app/c/#{hd(convs).id}")
    reloads = drain.() |> Enum.count(&sidebar_query?/1)

    assert reloads == 0,
           "opening a chat re-loaded the conversation list #{reloads} time(s) — " <>
             "the active wash and the unread badge are `.InstantNav`'s job, and the list has " <>
             "no LIMIT, so this cost grows with the account rather than with the screen"
  end

  test "going back to the list does not re-load it", %{conn: conn} do
    alice = user_fixture(%{username: "bkalice"})

    convs =
      for i <- 1..5 do
        other = user_fixture(%{username: "bkpeer#{i}"})
        {:ok, c} = Chat.create_conversation(scope(alice), [other.id])
        {:ok, _} = Chat.create_message(scope(other), c.id, %{"body" => "hi #{i}"})
        c
      end

    {:ok, view, _} = live(log_in_user(conn, alice), ~p"/app/c/#{hd(convs).id}")
    {drain, _} = watch(view)

    render_click(view, "select_folder", %{"id" => "all"})
    _ = render(view)
    assert drain.() |> Enum.count(&sidebar_query?/1) > 0, "the query shape no longer matches"

    # Leaving a chat changes exactly one thing in the list: which row is washed, and
    # `.InstantNav` already cleared that when it revealed the list.
    render_patch(view, "/app")
    reloads = drain.() |> Enum.count(&sidebar_query?/1)

    assert reloads == 0,
           "going back to the list re-loaded it #{reloads} time(s) — the rows did not change"
  end

  test "being removed from a group drops its row without re-loading the list", %{conn: conn} do
    alice = user_fixture(%{username: "rmalice"})
    bob = user_fixture(%{username: "rmbob"})

    for i <- 1..5 do
      other = user_fixture(%{username: "rmpeer#{i}"})
      {:ok, c} = Chat.create_conversation(scope(alice), [other.id])
      {:ok, _} = Chat.create_message(scope(other), c.id, %{"body" => "hi #{i}"})
    end

    {:ok, group} = Chat.create_conversation(scope(alice), [bob.id], title: "G", group: true)

    {:ok, view, _} = live(log_in_user(conn, alice), ~p"/app")
    {drain, _} = watch(view)

    render_click(view, "select_folder", %{"id" => "all"})
    _ = render(view)
    assert drain.() |> Enum.count(&sidebar_query?/1) > 0, "the query shape no longer matches"

    # Not the open conversation, so this is the sidebar-only branch: the row goes away, and a
    # stream delete says that without asking the database anything.
    send(view.pid, {:removed_from_conversation, group.id})
    _ = render(view)
    reloads = drain.() |> Enum.count(&sidebar_query?/1)

    assert reloads == 0,
           "dropping one row re-loaded the whole list #{reloads} time(s)"

    refute render(view) =~ "conversations-#{group.id}",
           "the row survived — a delete that does not delete is worse than a reload"
  end

  # No test for "a chat that left the sidebar and comes back". `forget_sidebar_row/2` is now
  # called wherever a row leaves the stream, and that is right by construction — a memory of a row
  # nobody can see must not decide whether the next one is sent. But three attempts to make it go
  # red failed, each for a different reason worth knowing: the copy seeded at mount comes from
  # `list_conversations/2` and never compares equal to a `get_conversation_summary/2` result, so
  # it can never trigger the skip; and `{:conversation_activity}` reaches the reorder branch,
  # which does not consult the memory at all. A test that passes with the fix removed is worse
  # than none, so there isn't one.

  # There is deliberately no equivalent for the rename / photo-change handlers. They only run for
  # a session that has that conversation OPEN (the broadcast rides the conversation topic), and my
  # first attempt measured a member sitting on the list, never reached them, and reported the same
  # number with the fix in and out.
  #
  # And none for `{:message_edited}`: #514 calls its three `refresh_sidebar` calls redundant
  # "because only one chat's preview changes", but measured, an edit costs 7 queries either way —
  # `Chat.get_conversation_summary/2` for one conversation costs about what
  # `list_conversations/2` costs for the whole small list. A saving may exist on the WIRE, but it
  # is not the one the issue claims, and an unmeasured claim is not a reason to change code.
end
