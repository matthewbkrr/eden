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
  alias Eden.Chat.Attachment
  alias Eden.{Repo, Storage}

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

    orphans =
      for {key, written_at} <- keys,
          written_at < cutoff,
          not kept?(key, referenced),
          do: key

    Enum.each(orphans, &Storage.delete/1)

    Logger.info(
      "blob reap: #{length(orphans)} orphan(s) of #{length(keys)} key(s) removed " <>
        "(#{MapSet.size(referenced.keys)} referenced)"
    )

    :ok
  end

  # A key survives if the database names it, or — for a derived variant — if it names the blob the
  # variant was rendered from. The variant only carries its source's STEM, so that is what both
  # sides are compared by.
  defp kept?(key, %{keys: keys, stems: stems}) do
    case Regex.named_captures(@variant, key) do
      %{"stem" => stem} -> MapSet.member?(stems, stem)
      nil -> MapSet.member?(keys, key)
    end
  end

  defp referenced_keys do
    attachment_keys = Repo.all(from a in Attachment, select: a.storage_key)

    thumbnail_keys =
      Repo.all(from a in Attachment, where: not is_nil(a.thumbnail_key), select: a.thumbnail_key)

    avatar_keys = Repo.all(from u in User, where: not is_nil(u.avatar_key), select: u.avatar_key)

    keys = attachment_keys ++ thumbnail_keys ++ avatar_keys

    %{keys: MapSet.new(keys), stems: MapSet.new(keys, &Path.rootname/1)}
  end
end
