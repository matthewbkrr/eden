defmodule EdenWeb.InviteController do
  use EdenWeb, :controller

  alias Eden.Accounts
  alias EdenWeb.UserAuth

  def create(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.register_user_with_invite(token, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Welcome to ihichat, %{name}!", name: user.display_name))
        # A brand-new account is never enrolled — route them through the "set up
        # two-factor" onboarding step (#306) before the app, carrying any original
        # destination so they can continue there after they enroll or skip.
        |> UserAuth.log_in_user(user, to: welcome_totp_path(conn))

      {:error, %Ecto.Changeset{} = changeset} ->
        # Send them back to the form (which re-renders per-field errors) with a flash
        # matching the actual failure — a password mismatch and a taken username are the
        # two common ones and need different copy (#306 review).
        conn
        |> put_flash(:error, registration_error_message(changeset))
        |> redirect(to: ~p"/invite/#{token}")

      {:error, _reason} ->
        # Invite became invalid (expired/revoked/exhausted/unknown) between load
        # and submit; the invite page re-renders the specific reason.
        redirect(conn, to: ~p"/invite/#{token}")
    end
  end

  # Flash copy keyed to which field actually failed — the redirect remounts a FRESH form, so the
  # flash is the ONLY feedback (per-field errors don't survive) and it must be accurate (#307
  # review). The :password bucket carries required (blank) OR length (min 8 / max 72 bytes), so
  # split those out and report them BEFORE :password_confirmation — a password that's blank/too
  # short can't meaningfully "match" yet, and reporting the mismatch would hide the real fix.
  defp registration_error_message(%Ecto.Changeset{errors: errors}) do
    password_issue =
      case errors[:password] do
        {_msg, opts} -> Keyword.get(opts, :validation)
        _ -> nil
      end

    cond do
      password_issue == :required ->
        gettext("Please enter a password.")

      password_issue == :length ->
        gettext("Please choose a password of 8 to 72 characters.")

      Keyword.has_key?(errors, :password_confirmation) ->
        gettext("The passwords didn't match — please try again.")

      Keyword.has_key?(errors, :username) ->
        gettext("That username may be taken. Please try another.")

      true ->
        gettext("Please check the form and try again.")
    end
  end

  # Where to send the newly-registered user: the 2FA onboarding step, forwarding any
  # `user_return_to` (a link they were headed to before registering) so it survives the
  # detour. The onboarding LiveView re-validates the param is a local path before using it.
  defp welcome_totp_path(conn) do
    case get_session(conn, :user_return_to) do
      path when is_binary(path) -> ~p"/welcome/two-factor?#{[return_to: path]}"
      _ -> ~p"/welcome/two-factor"
    end
  end
end
