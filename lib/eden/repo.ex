defmodule Eden.Repo do
  use Ecto.Repo,
    otp_app: :eden,
    adapter: Ecto.Adapters.Postgres
end
