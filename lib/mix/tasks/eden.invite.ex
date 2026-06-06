defmodule Mix.Tasks.Eden.Invite do
  @shortdoc "Creates an invite link and prints its URL"

  @moduledoc """
  Creates an invite and prints the URL to share.

      mix eden.invite                       # single-use, expires in 7 days, no inviter
      mix eden.invite --max-uses 5          # multi-use
      mix eden.invite --days 1              # custom expiry
      mix eden.invite --from alice          # attribute to an existing user

  Use this once to bootstrap the very first account (no inviter needed), and
  afterwards to mint invites from the command line.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [max_uses: :integer, days: :integer, from: :string])

    inviter = resolve_inviter(opts[:from])

    invite_opts =
      []
      |> maybe_put(:max_uses, opts[:max_uses])
      |> maybe_put(:expires_at, days_to_expiry(opts[:days]))

    case Eden.Accounts.create_invite(inviter, invite_opts) do
      {:ok, invite, token} ->
        Mix.shell().info("""

        Invite created — max_uses: #{invite.max_uses}, expires: #{invite.expires_at}

            #{base_url()}/invite/#{token}

        Share this link. The token is shown only once.
        """)

      {:error, changeset} ->
        Mix.raise("Could not create invite: #{inspect(changeset.errors)}")
    end
  end

  defp resolve_inviter(nil), do: nil

  defp resolve_inviter(username) do
    Eden.Accounts.get_user_by_username(username) ||
      Mix.raise("No user with username #{inspect(username)}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp days_to_expiry(nil), do: nil

  defp days_to_expiry(days) when days > 0 do
    DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
  end

  defp days_to_expiry(days), do: Mix.raise("--days must be a positive integer, got: #{days}")

  defp base_url do
    EdenWeb.Endpoint.url()
  rescue
    _ -> "http://localhost:4000"
  end
end
