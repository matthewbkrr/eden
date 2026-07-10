defmodule Eden.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :eden

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # The exact value EDEN_ALLOW_RESET must carry to arm reset!/0 — spelled out so it can't
  # fire from a stray truthy value.
  @reset_confirm "yes-wipe-everything"

  @doc """
  DESTRUCTIVE go-live reset (#353): empties every data table (users, messages, attachments,
  invites, …) and clears the local uploads volume, leaving a pristine, migrated schema. The
  go-live flow is: back up → `reset!` → `bootstrap_super_admin` → create real invites.

  Guarded: only runs when `EDEN_ALLOW_RESET=#{@reset_confirm}`, and only TRUNCATEs (the schema
  + `schema_migrations` are kept, so `bin/migrate` is not needed afterwards). Run via
  `EDEN_ALLOW_RESET=#{@reset_confirm} bin/eden eval 'Eden.Release.reset!()'`.
  """
  def reset! do
    if System.get_env("EDEN_ALLOW_RESET") != @reset_confirm do
      raise """
      Refusing to reset. This DROPS ALL DATA (users, messages, attachments) and clears uploads.
      Re-run with EDEN_ALLOW_RESET=#{@reset_confirm} to confirm.
      """
    end

    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &truncate_all/1)
    end

    wipe_uploads()
    :ok
  end

  defp truncate_all(repo) do
    case data_tables(repo) do
      [] ->
        :ok

      tables ->
        quoted = Enum.map_join(tables, ", ", &~s("#{&1}"))
        repo.query!("TRUNCATE TABLE #{quoted} RESTART IDENTITY CASCADE")
    end
  end

  @doc """
  Bootstraps the FIRST platform super_admin on a fresh DB (#353) — prod has no Mix, so this
  runs via `bin/eden eval`. Reads `EDEN_BOOTSTRAP_USERNAME` + `EDEN_BOOTSTRAP_PASSWORD` from
  the environment (never in code/logs); optional `EDEN_BOOTSTRAP_DISPLAY_NAME` defaults to the
  username. Delegates to `Eden.Accounts.bootstrap_super_admin/3`, which refuses if a super_admin
  already exists. Run via:

      EDEN_BOOTSTRAP_USERNAME=matveyihi EDEN_BOOTSTRAP_PASSWORD='…' \\
        bin/eden eval 'Eden.Release.bootstrap_super_admin()'
  """
  def bootstrap_super_admin do
    load_app()
    username = System.fetch_env!("EDEN_BOOTSTRAP_USERNAME")
    password = System.fetch_env!("EDEN_BOOTSTRAP_PASSWORD")
    display_name = System.get_env("EDEN_BOOTSTRAP_DISPLAY_NAME")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _r ->
        Eden.Accounts.bootstrap_super_admin(username, password, display_name: display_name)
      end)

    case result do
      {:ok, user} ->
        IO.puts("✓ super_admin bootstrapped: #{user.username} (id=#{user.id})")
        :ok

      {:error, :already_bootstrapped} ->
        IO.puts("• a super_admin already exists — nothing to do")
        :ok

      {:error, changeset} ->
        raise "bootstrap failed: #{inspect(changeset.errors)}"
    end
  end

  # Every public table except schema_migrations (the schema itself is kept — TRUNCATE, not drop).
  defp data_tables(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      )

    List.flatten(rows)
  end

  # Clear the LOCAL uploads root's contents (keeping the mount point), only when the local
  # storage adapter is active. An S3 bucket is never touched here (cleared out-of-band).
  defp wipe_uploads do
    root = local_uploads_root()

    if root && File.dir?(root),
      do: for(entry <- File.ls!(root), do: File.rm_rf!(Path.join(root, entry)))

    :ok
  end

  # The local uploads dir, or nil when the S3 adapter is active (nothing to wipe on-box).
  defp local_uploads_root do
    if Application.get_env(@app, Eden.Storage)[:adapter] == Eden.Storage.Local do
      Application.get_env(@app, Eden.Storage.Local)[:root]
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
