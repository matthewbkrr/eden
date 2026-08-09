defmodule Eden.Chat.BlobReaperTest do
  @moduledoc """
  The blob reconciler (#385/R128): what it reclaims, and — mostly — what it must not.

  A sweeper that deletes by absence is only as safe as the things that stop it, so those are what
  this file is about: the grace period that protects an upload in flight, the rule that keeps a
  derived variant alive with its source, the refusal to sweep a store it cannot enumerate, and the
  honesty of its own report.
  """
  use Eden.DataCase, async: false

  import Eden.AccountsFixtures

  alias Eden.Chat.BlobReaper
  alias Eden.Storage

  @day 24 * 3600

  setup do
    # A private root per test: the reaper lists a whole store, so a shared directory would make
    # these tests each other's business.
    root = Path.join(System.tmp_dir!(), "reaper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:eden, Eden.Storage.Local)
    Application.put_env(:eden, Eden.Storage.Local, root: root)

    on_exit(fn ->
      Application.put_env(:eden, Eden.Storage.Local, previous)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp store(key, age_seconds \\ 0) do
    :ok = Storage.put_binary(key, "bytes")

    if age_seconds > 0 do
      {:ok, path} = Storage.local_path(key)
      File.touch!(path, System.system_time(:second) - age_seconds)
    end

    key
  end

  defp run, do: :ok = BlobReaper.perform(%Oban.Job{})

  defp with_adapter(module, fun) do
    previous = Application.get_env(:eden, Eden.Storage)
    Application.put_env(:eden, Eden.Storage, adapter: module)

    try do
      fun.()
    after
      Application.put_env(:eden, Eden.Storage, previous)
    end
  end

  test "an old blob nothing references is reclaimed" do
    key = store("attachments/orphan.jpg", 2 * @day)

    run()

    refute Storage.exists?(key), "an orphan older than the grace period survived the sweep"
  end

  test "a blob written moments ago is left alone" do
    # The upload that is still in flight: bytes stored, row not committed yet. Reaping this is the
    # one mistake a reconciler must never make.
    key = store("attachments/in-flight.jpg")

    run()

    assert Storage.exists?(key),
           "a just-written blob was reaped — an upload in flight would vanish"
  end

  test "a referenced blob survives however old it is" do
    user = user_fixture()
    key = store("avatars/referenced.jpg", 30 * @day)
    Repo.update!(Ecto.Changeset.change(user, avatar_key: key))

    run()

    assert Storage.exists?(key), "a blob the database still points at was deleted"
  end

  test "a derived variant lives and dies with its source (#516)" do
    user = user_fixture()
    source = store("avatars/kept.jpg", 30 * @day)
    kept_variant = store("avatars/kept@192.webp", 30 * @day)
    gone_variant = store("avatars/vanished@192.webp", 30 * @day)
    Repo.update!(Ecto.Changeset.change(user, avatar_key: source))

    run()

    assert Storage.exists?(kept_variant),
           "a rendition of a referenced avatar was reaped — nothing points at a variant directly, " <>
             "so treating it as an orphan deletes every avatar's rendered sizes"

    refute Storage.exists?(gone_variant), "a rendition of a blob nobody references survived"
  end

  test "a stored blob whose own name looks like a variant is protected by its own reference" do
    user = user_fixture()
    # Not a rendition of anything: this IS the referenced key, and it merely happens to be shaped
    # like one. Reading it only as a variant would delete a blob the database points at.
    key = store("avatars/looks-like@192.webp", 30 * @day)
    Repo.update!(Ecto.Changeset.change(user, avatar_key: key))

    run()

    assert Storage.exists?(key),
           "a referenced key was reaped because its name resembled a variant"
  end

  test "a blob referenced after the inventory was taken is not deleted" do
    user = user_fixture()
    first = store("attachments/deleted-first.jpg", 2 * @day)
    late = store("avatars/referenced-mid-sweep.jpg", 2 * @day)

    # The window the write-time grace says nothing about: both are orphans when the sweep takes its
    # snapshot, and a row starts pointing at the second one WHILE the sweep is deleting the first.
    # Only a re-check immediately before each delete can catch that (#584 review).
    Process.put(:reference_on_delete, {user, late})

    with_adapter(__MODULE__.ReferencingAdapter, &run/0)

    assert Storage.exists?(late),
           "a blob that became referenced during the sweep was deleted anyway"

    refute Storage.exists?(first), "nothing was deleted at all — this test proved nothing"
  end

  test "a variant whose source becomes referenced mid-sweep is not deleted" do
    user = user_fixture()
    first = store("attachments/deleted-first.jpg", 2 * @day)
    source = store("avatars/late-source.jpg", 2 * @day)
    variant = store("avatars/late-source@192.webp", 2 * @day)

    # Nothing points at the variant directly, ever — it survives only through its source. So the
    # re-check has to ask about the SOURCE, not about the variant's own name (#584 review).
    Process.put(:reference_on_delete, {user, source})

    with_adapter(__MODULE__.ReferencingAdapter, &run/0)

    assert Storage.exists?(variant),
           "the rendition was deleted although its source became referenced during the sweep"

    refute Storage.exists?(first), "nothing was deleted at all — this test proved nothing"
  end

  test "a temp file left by a crashed write is eventually reclaimed" do
    # `atomic_write/2` writes here and renames into place; a crash in between leaves this behind
    # with nothing to ever clean it up unless the sweep can see it (#584 review).
    orphan_temp = store("attachments/crashed.jpg.tmp-abc123", 2 * @day)
    fresh_temp = store("attachments/writing-now.jpg.tmp-def456")

    run()

    refute Storage.exists?(orphan_temp), "a temp file from a crashed write was never reclaimed"

    assert Storage.exists?(fresh_temp),
           "a write in flight was reaped — the grace period is what protects it, not invisibility"
  end

  test "a symlinked directory does not let the sweep escape the storage root" do
    outside_dir = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_dir)
    outsider = Path.join(outside_dir, "not-ours.jpg")
    File.write!(outsider, "not ours")
    File.touch!(outsider, System.system_time(:second) - 2 * @day)
    on_exit(fn -> File.rm_rf(outside_dir) end)

    root = Application.fetch_env!(:eden, Eden.Storage.Local)[:root]
    File.mkdir_p!(Path.join(root, "attachments"))
    :ok = File.ln_s(outside_dir, Path.join([root, "attachments", "escape"]))

    run()

    assert File.exists?(outsider),
           "the sweep walked through a symlinked directory and deleted a file outside the root — " <>
             "an inventory that can leave the root is a deleter that can leave the root"
  end

  test "every schema field holding a storage key is declared as a reference source" do
    # The one mistake that makes this module dangerous is forgetting a column: a key nobody declared
    # is a key the sweep calls garbage, and the deletion is permanent. So the schemas are read and
    # compared against what the reaper says it covers — this test found channel and group avatars
    # missing on its first run, which the sweep would have deleted wholesale (#584 review).
    declared =
      MapSet.new(BlobReaper.sources(), fn {schema, field} ->
        {schema.__schema__(:source), field}
      end)

    in_schemas =
      "lib/eden/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        case Regex.run(~r/schema "(\w+)" do/, source) do
          [_, table] ->
            ~r/field :(\w+_key),/
            |> Regex.scan(source)
            |> Enum.map(fn [_, field] -> {table, String.to_atom(field)} end)

          _ ->
            []
        end
      end)
      |> MapSet.new()

    missing = MapSet.difference(in_schemas, declared)

    assert Enum.empty?(missing),
           "these columns hold storage keys and the reaper does not know about them, so it would " <>
             "delete what they point at: #{inspect(Enum.to_list(missing))}"
  end

  test "avatars of channels and groups are references too" do
    channel_avatar = store("avatars/channel.jpg", 30 * @day)
    group_avatar = store("avatars/group.jpg", 30 * @day)

    user = user_fixture()

    {:ok, channel} =
      Eden.Channels.create_channel(Eden.Accounts.Scope.for_user(user), %{"name" => "Reap"})

    Repo.update!(Ecto.Changeset.change(channel, avatar_key: channel_avatar))

    {:ok, group} =
      Eden.Chat.create_conversation(Eden.Accounts.Scope.for_user(user), [user_fixture().id])

    Repo.update!(Ecto.Changeset.change(group, avatar_key: group_avatar))

    run()

    assert Storage.exists?(channel_avatar), "a channel's avatar was reaped"
    assert Storage.exists?(group_avatar), "a group's avatar was reaped"
  end

  test "an underscore in a key is a literal, not a LIKE wildcard" do
    user = user_fixture()

    # `Storage.build_key/2` mints names from base64url, which uses `_` — and `_` matches any single
    # character in LIKE. An unescaped pattern would let this referenced avatar keep an unrelated
    # orphan alive forever (#584 review).
    referenced = store("avatars/aXb.jpg", 30 * @day)
    orphan = store("avatars/a_b@192.webp", 30 * @day)
    Repo.update!(Ecto.Changeset.change(user, avatar_key: referenced))

    run()

    assert Storage.exists?(referenced), "the referenced avatar was deleted"

    refute Storage.exists?(orphan),
           "an orphan survived because its stem was read as a LIKE pattern — `a_b` matched `aXb`"
  end

  test "an adapter that cannot enumerate sweeps nothing" do
    key = store("attachments/unknowable.jpg", 2 * @day)

    with_adapter(__MODULE__.BlindAdapter, &run/0)

    assert Storage.exists?(key),
           "the sweep ran against a store it cannot list — an unknown inventory must mean " <>
             "delete nothing, not delete everything the database does not name"
  end

  test "a delete the store refuses is not counted as reclaimed" do
    key = store("attachments/undeletable.jpg", 2 * @day)

    # A stub adapter, not a chmod: permission bits do not stop root, and CI runs in a container
    # where root is the default — the test would then delete the blob and fail on its own setup
    # rather than on the behaviour (#584 review).
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        with_adapter(__MODULE__.RefusingAdapter, &run/0)
      end)

    assert Storage.exists?(key),
           "the blob is gone — this test no longer exercises a failed delete"

    assert log =~ "could not be deleted", "a refused delete was reported as a reclaimed orphan"
    refute log =~ "1 orphan(s) of", "the count claimed a removal that never happened"
  end

  defmodule ReferencingAdapter do
    @moduledoc """
    Local in every way except that the first delete also makes ANOTHER blob referenced — the race
    the pre-delete re-check exists for.
    """
    @behaviour Eden.Storage

    @impl true
    defdelegate put(key, path), to: Eden.Storage.Local
    @impl true
    defdelegate put_binary(key, binary), to: Eden.Storage.Local
    @impl true
    defdelegate read(key), to: Eden.Storage.Local
    @impl true
    defdelegate exists?(key), to: Eden.Storage.Local
    @impl true
    defdelegate list_keys(), to: Eden.Storage.Local

    @impl true
    def delete(key) do
      case Process.get(:reference_on_delete) do
        {user, late_key} when key != late_key ->
          Process.delete(:reference_on_delete)
          Eden.Repo.update!(Ecto.Changeset.change(user, avatar_key: late_key))

        _ ->
          :noop
      end

      Eden.Storage.Local.delete(key)
    end
  end

  defmodule BlindAdapter do
    @moduledoc "An adapter without `list_keys/0`, like S3 today."
    @behaviour Eden.Storage

    @impl true
    def put(_key, _path), do: :ok
    @impl true
    def put_binary(_key, _binary), do: :ok
    @impl true
    def read(_key), do: {:error, :enoent}
    @impl true
    def delete(_key), do: :ok
    @impl true
    def exists?(_key), do: false
  end

  defmodule RefusingAdapter do
    @moduledoc "Lists like Local, refuses every delete — a locked file, a read-only mount."
    @behaviour Eden.Storage

    @impl true
    defdelegate put(key, path), to: Eden.Storage.Local
    @impl true
    defdelegate put_binary(key, binary), to: Eden.Storage.Local
    @impl true
    defdelegate read(key), to: Eden.Storage.Local
    @impl true
    defdelegate exists?(key), to: Eden.Storage.Local
    @impl true
    defdelegate list_keys(), to: Eden.Storage.Local

    @impl true
    def delete(_key), do: {:error, :eacces}
  end
end
