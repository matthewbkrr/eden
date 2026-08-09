defmodule Eden.Chat.BlobReaperTest do
  @moduledoc """
  The blob reconciler (#385/R128): what it reclaims, and — mostly — what it must not.

  A sweeper that deletes by absence is only as safe as the things that stop it, so those are what
  this file is about: the grace period that protects an upload in flight, the rule that keeps a
  derived variant alive with its source, and the refusal to sweep a store it cannot enumerate.
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
      old = System.system_time(:second) - age_seconds
      File.touch!(path, old)
    end

    key
  end

  defp run, do: :ok = BlobReaper.perform(%Oban.Job{})

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

  test "an adapter that cannot enumerate sweeps nothing" do
    key = store("attachments/unknowable.jpg", 2 * @day)
    previous = Application.get_env(:eden, Eden.Storage)
    Application.put_env(:eden, Eden.Storage, adapter: __MODULE__.BlindAdapter)
    on_exit(fn -> Application.put_env(:eden, Eden.Storage, previous) end)

    run()

    Application.put_env(:eden, Eden.Storage, previous)

    assert Storage.exists?(key),
           "the sweep ran against a store it cannot list — an unknown inventory must mean " <>
             "delete nothing, not delete everything the database does not name"
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
end
