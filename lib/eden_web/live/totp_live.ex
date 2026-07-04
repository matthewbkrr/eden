defmodule EdenWeb.TotpLive do
  @moduledoc """
  Second-factor challenge (#250). Reached only mid-login, after the password step
  set a short-lived `totp_pending_user_id` in the session for an enrolled user. The
  form posts natively to `POST /login/totp` (`UserSessionController.totp/2`), which
  completes the sign-in. No session token is issued until the code checks out — so
  a stolen password alone doesn't get in.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts

  # Must match UserSessionController's pending-2FA TTL.
  @pending_ttl_seconds 300

  def mount(_params, session, socket) do
    case pending_user(session) do
      %Accounts.User{} = user ->
        {:ok,
         assign(socket,
           page_title: gettext("Two-factor authentication"),
           display_name: user.display_name,
           form: to_form(%{}, as: "totp")
         )}

      nil ->
        # No (or expired) pending step — send them back to the start of login.
        {:ok, push_navigate(socket, to: ~p"/login")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen grid place-items-center px-5 py-10">
      <div class="w-full max-w-sm">
        <h1 class="mb-1" style="font-size:1.375rem; font-weight:650;">
          {gettext("Two-factor authentication")}
        </h1>
        <p class="mb-6" style="color: var(--ed-muted); font-size:0.875rem;">
          {gettext("Enter the 6-digit code from your authenticator app, or a backup code.")}
        </p>

        <.ed_flash flash={@flash} />

        <.form
          for={@form}
          action={~p"/login/totp"}
          id="totp-form"
          phx-update="ignore"
          class="space-y-4"
        >
          <.ed_field
            field={@form[:code]}
            label={gettext("Authentication code")}
            autocomplete="one-time-code"
            inputmode="numeric"
            required
            autofocus
          />
          <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Verify")}</button>
        </.form>

        <.link navigate={~p"/login"} class="mt-5 inline-block" style="font-size:0.8125rem;">
          <span style="color: var(--ed-muted);">{gettext("Back to sign in")}</span>
        </.link>
      </div>
    </div>
    """
  end

  defp pending_user(session) do
    with id when is_integer(id) <- session["totp_pending_user_id"],
         at when is_integer(at) <- session["totp_pending_at"],
         true <- System.system_time(:second) - at <= @pending_ttl_seconds,
         %Accounts.User{} = user <- Accounts.get_user(id) do
      user
    else
      _ -> nil
    end
  end
end
