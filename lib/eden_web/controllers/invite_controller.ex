defmodule EdenWeb.InviteController do
  use EdenWeb, :controller

  alias Eden.Accounts
  alias EdenWeb.UserAuth

  def create(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.register_user_with_invite(token, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Welcome to eden, %{name}!", name: user.display_name))
        |> UserAuth.log_in_user(user)

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, gettext("Please fix the errors below and try again."))
        |> redirect(to: ~p"/invite/#{token}")

      {:error, reason} ->
        conn
        |> put_flash(:error, invite_error(reason))
        |> redirect(to: ~p"/")
    end
  end

  defp invite_error(:expired), do: gettext("This invite link has expired.")
  defp invite_error(:revoked), do: gettext("This invite link is no longer active.")
  defp invite_error(:exhausted), do: gettext("This invite link has already been used up.")
  defp invite_error(_), do: gettext("This invite link is invalid.")
end
