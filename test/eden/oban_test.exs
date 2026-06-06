defmodule Eden.ObanTest do
  @moduledoc """
  Smoke test that Oban is wired into the supervision tree and configured against
  the repo. Job-level behavior is tested per-worker as workers are added.
  """
  use ExUnit.Case, async: true

  test "oban is supervised and configured for the repo" do
    config = Oban.config()

    assert %Oban.Config{} = config
    assert config.repo == Eden.Repo
  end
end
