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
        # Most commonly a username already taken. Send them back to the form
        # (which renders the flash) to choose another.
        conn
        |> put_flash(:error, gettext("That username may be taken. Please try another."))
        |> redirect(to: ~p"/invite/#{token}")

      {:error, _reason} ->
        # Invite became invalid (expired/revoked/exhausted/unknown) between load
        # and submit; the invite page re-renders the specific reason.
        redirect(conn, to: ~p"/invite/#{token}")
    end
  end
end
