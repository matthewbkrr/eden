defmodule Eden.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Drop everything Oban created. Reversible per the project DoD.
  def down, do: Oban.Migration.down(version: 1)
end
