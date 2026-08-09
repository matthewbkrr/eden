defmodule Eden.Chat.BlobReaper do
  @moduledoc """
  Reclaims blobs nothing references any more (#385/R128).

  Every deliberate delete path already cleans up after itself — `delete_unreferenced_blobs/1` on
  message deletion, `Images.delete_avatar/1` on an avatar swap. What none of them can cover is a
  process that dies between `Storage.put` and the transaction that would have referenced the key:
  the bytes are on disk, no row points at them, and nothing will ever look at them again. On a
  single VPS that has already filled its disk once, a leak with no reconciler is a leak that ends
  in an outage.

  So this sweeps the other way round: it asks the store what it holds and the database what it
  references, and deletes the difference. Three things keep that from being dangerous:

    * **A grace period.** Only blobs written more than `@grace_hours` ago are considered. An
      upload in flight — bytes stored, row not yet committed — is younger than that by orders of
      magnitude, so it is never a candidate.
    * **Derived variants follow their source** (#516). `avatars/ab@192.webp` is referenced by
      nothing directly; it is a rendition of `avatars/ab.jpg`. A variant is kept exactly when its
      source is kept, and reaped when the source is gone.
    * **An adapter that cannot enumerate stops the sweep.** `Storage.list_keys/0` answers `:error`
      where listing is unimplemented (S3 today), and an unknown inventory means delete nothing —
      never "the store is empty, delete everything the DB does not name".

  Scheduled daily by `Oban.Plugins.Cron` (see `config/config.exs`), idempotent, and it logs what
  it removed so the first run on a long-lived box is readable rather than mysterious.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Eden.Accounts.User
  alias Eden.Channels.Channel
  alias Eden.Chat.{Attachment, Conversation}
  alias Eden.{Repo, Storage}

  @doc """
  Every place a storage key can be referenced from.

  Declared rather than spelled out inside the queries so the one thing that makes this module
  dangerous — forgetting a column — is a list someone can read, and so `blob_reaper_test.exs` can
  compare it against the schemas themselves. It caught its own omission on the first run: channel
  and group avatars were missing, and the sweep would have deleted every one of them (#584 review).
  """
  def sources do
    [
      {Attachment, :storage_key},
      {Attachment, :thumbnail_key},
      {User, :avatar_key},
      {Channel, :avatar_key},
      {Conversation, :avatar_key}
    ]
  end

  # Old enough that no upload can still be mid-flight, short enough that a leak is measured in
  # days rather than forever.
  @grace_hours 24

  # `avatars/ab@192.webp` is `Eden.Images.variant_key/2` applied to `avatars/ab.jpg`: the source's
  # extension is REPLACED, so the source cannot be reconstructed from the variant's name — only
  # its stem can. Referenced keys are therefore compared by stem as well.
  @variant ~r/^(?<stem>.+)@\d+\.webp$/

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Storage.list_keys() do
      {:ok, keys} ->
        sweep(keys)

      :error ->
        Logger.info("blob reap: storage adapter cannot enumerate keys — nothing swept")
        :ok
    end
  end

  defp sweep(keys) do
    referenced = referenced_keys()
    cutoff = System.system_time(:second) - @grace_hours * 3600

    # Sorted: the store hands its inventory back in whatever order it walks, and a nightly job that
    # deletes in a stable order is one whose logs can be compared between runs.
    orphans =
      for {key, written_at} <- keys,
          written_at < cutoff,
          not kept?(key, referenced),
          do: key

    orphans = Enum.sort(orphans)

    # Re-read from the database in ONE pass over the candidates rather than two queries per orphan
    # per source: the freshness this buys is the same (it happens after the snapshot, immediately
    # before the deletes), and a first run on a neglected box can have thousands of candidates —
    # per-orphan round trips would turn a nightly job into an hour of chatter (#584 review).
    orphans = orphans -- still_referenced(orphans)

    # Counted by what the store actually did, not by what was asked of it. A delete that failed
    # (a lock, a permission, a vanished mount) leaves the blob exactly where it was, and a log
    # line claiming otherwise is worse than no log at all: the leak stays, and the one place that
    # would have shown it says everything is fine (#584 review).
    {removed, failed} =
      Enum.reduce(orphans, {0, 0}, fn key, {ok, bad} ->
        # Asked once more for THIS key, immediately before deleting it. The batch above is the
        # cheap bulk pass; this is the one that has to be FRESH, because a row can start pointing
        # at the blob in between and the delete is irreversible. The window cannot be closed
        # entirely — storage is not the database, so no lock spans both — but it can be
        # microseconds instead of the minutes a snapshot-only sweep leaves open.
        if still_orphan?(key), do: tally(Storage.delete(key), {ok, bad}), else: {ok, bad}
      end)

    Logger.info(
      "blob reap: #{removed} orphan(s) of #{length(keys)} key(s) removed " <>
        "(#{MapSet.size(referenced.keys)} referenced)"
    )

    if failed > 0 do
      Logger.warning("blob reap: #{failed} orphan(s) could not be deleted and remain in storage")
    end

    :ok
  end

  # A key survives if the database names it, or — for a derived variant — if it names the blob the
  # variant was rendered from. The variant only carries its source's STEM, so that is what both
  # sides are compared by.
  defp kept?(key, %{keys: keys, stems: stems}) do
    # The exact set is consulted for EVERY key, variant-shaped or not: a stored blob whose own name
    # happens to end in `@<n>.webp` is referenced by that name, and reading it only as a rendition
    # of something else would delete a blob the database is pointing at (#584 review).
    MapSet.member?(keys, key) or
      case Regex.named_captures(@variant, key) do
        %{"stem" => stem} -> MapSet.member?(stems, stem)
        nil -> false
      end
  end

  # Streamed, not loaded. Attachments are the table that grows without bound here, and a nightly
  # job has no reason to hold every key of it in memory at once (#584 review); the fold goes
  # straight into the set the sweep needs.
  defp referenced_keys do
    empty = %{keys: MapSet.new(), stems: MapSet.new()}

    Enum.reduce(sources(), empty, fn {schema, field}, acc ->
      {:ok, collected} =
        Repo.transaction(
          fn ->
            from(s in schema, where: not is_nil(field(s, ^field)), select: field(s, ^field))
            |> Repo.stream(max_rows: 500)
            |> Enum.reduce(acc, &remember/2)
          end,
          # A stream holds its transaction open for as long as the walk takes, and the default 15s
          # pool timeout is a limit on the DATABASE being slow, not on this job being long.
          timeout: :infinity
        )

      collected
    end)
  end

  defp tally(:ok, {ok, bad}), do: {ok + 1, bad}
  defp tally({:error, _reason}, {ok, bad}), do: {ok, bad + 1}

  # Which of these candidates the database points at RIGHT NOW.
  #
  # Asked by exact name and — for a rendition — by its source's stem, mirroring `kept?/2`: a stored
  # blob can be referenced under a name that merely looks like a variant, and a variant is
  # referenced by nothing directly (#584 review).
  defp still_referenced([]), do: []

  defp still_referenced(keys) do
    stems =
      for key <- keys, captures = Regex.named_captures(@variant, key), into: %{} do
        {captures["stem"], key}
      end

    # Asked ONCE for the whole candidate list, then filtered in memory. Written as a filter over a
    # function that queried, this ran the full set of per-source queries for every candidate — the
    # batch pass doing N times the work of the per-key pass it was introduced to replace (#584
    # review).
    referenced_now =
      sources()
      |> Enum.flat_map(fn {schema, field} ->
        Repo.all(from(s in schema, where: field(s, ^field) in ^keys, select: field(s, ^field)))
      end)
      |> MapSet.new()

    exact = Enum.filter(keys, &MapSet.member?(referenced_now, &1))

    # Stems still need one query each: a rendition's source is not in the candidate list, so no
    # single `in` covers them. There are only as many as there are variant-shaped candidates.
    from_stems =
      for {stem, key} <- stems, referenced_like?(escape_like(stem) <> ".%"), do: key

    Enum.uniq(exact ++ from_stems)
  end

  defp still_orphan?(key) do
    pattern =
      case Regex.named_captures(@variant, key) do
        %{"stem" => stem} -> escape_like(stem) <> ".%"
        # A name that cannot be a rendition still needs a pattern for the one query; its own
        # escaped name matches only itself.
        nil -> escape_like(key)
      end

    not Enum.any?(sources(), fn {schema, field} ->
      Repo.exists?(
        from(s in schema,
          where:
            field(s, ^field) == ^key or
              fragment("? LIKE ? ESCAPE ?", field(s, ^field), ^pattern, "\\")
        )
      )
    end)
  end

  # `_` is a LIKE wildcard and `Storage.build_key/2` mints keys from base64url, which uses it — an
  # unescaped stem therefore matches keys it has nothing to do with. That direction is fail-SAFE
  # (garbage is kept, never data deleted), but it means a leak that no run would ever reclaim
  # (#584 review). Escaped the same way `Eden.Chat` escapes search terms.
  defp escape_like(term), do: String.replace(term, ~r/[\\%_]/, fn ch -> "\\" <> ch end)

  defp referenced_like?(pattern) do
    Enum.any?(sources(), fn {schema, field} ->
      Repo.exists?(
        from(s in schema,
          where: fragment("? LIKE ? ESCAPE ?", field(s, ^field), ^pattern, "\\")
        )
      )
    end)
  end

  defp remember(key, %{keys: keys, stems: stems}) do
    %{keys: MapSet.put(keys, key), stems: MapSet.put(stems, Path.rootname(key))}
  end
end
