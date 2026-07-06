defmodule EdenWeb.WelcomeTotpLive do
  @moduledoc """
  Post-registration onboarding (#306): offers a brand-new user the chance to enroll
  two-factor before entering the app. Reuses the Accounts TOTP setup (`setup_totp/1` →
  QR + confirm code → `activate_totp/3`), then reveals one-time backup codes. Skippable —
  2FA is an offer for regular users (admins are forced to enroll at the `:require_admin`
  gate anyway). `return_to` carries any pre-registration destination, re-validated here
  as a local path to avoid an open redirect.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts
  alias Eden.Accounts.Scope

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user
    return_to = safe_return_to(params["return_to"])

    if Accounts.totp_enrolled?(user) do
      # Already has a factor (e.g. the link reopened later) — nothing to offer.
      {:ok, push_navigate(socket, to: return_to)}
    else
      {:ok,
       socket
       |> assign(
         page_title: gettext("Secure your account"),
         return_to: return_to,
         totp_setup: totp_setup(user),
         totp_error: nil,
         totp_backup_codes: nil
       )}
    end
  end

  @impl true
  def handle_event("activate", %{"totp" => %{"code" => code}}, socket) do
    case Accounts.activate_totp(
           socket.assigns.current_scope.user,
           socket.assigns.totp_setup.secret,
           code
         ) do
      {:ok, user, backup_codes} ->
        {:noreply,
         assign(socket,
           current_scope: Scope.for_user(user),
           totp_setup: nil,
           totp_error: nil,
           totp_backup_codes: backup_codes
         )}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, totp_error: gettext("That code didn't match. Try again."))}
    end
  end

  def handle_event("skip", _params, socket),
    do: {:noreply, push_navigate(socket, to: socket.assigns.return_to)}

  def handle_event("finish", _params, socket),
    do: {:noreply, push_navigate(socket, to: socket.assigns.return_to)}

  defp totp_setup(user) do
    {secret, uri} = Accounts.setup_totp(user)

    %{
      secret: secret,
      key: Base.encode32(secret, padding: false),
      qr: uri |> EQRCode.encode() |> EQRCode.svg(width: 168, viewbox: true)
    }
  end

  # Only follow a local path (the param is user-editable) — else land in the app.
  defp safe_return_to("/" <> _ = path) do
    if String.starts_with?(path, "//"), do: ~p"/app", else: path
  end

  defp safe_return_to(_), do: ~p"/app"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen grid place-items-center px-5 py-10">
      <div class="w-full max-w-md">
        <h1 class="mb-1" style="font-size:1.375rem; font-weight:650;">
          {gettext("Secure your account")}
        </h1>
        <p class="mb-6" style="color: var(--ed-muted); font-size:0.875rem;">
          {gettext(
            "Add two-factor authentication — a 6-digit code from an authenticator app at sign-in. Recommended, but you can also do this later in Settings."
          )}
        </p>

        <.ed_flash flash={@flash} />

        <%!-- After activation: show the one-time backup codes, then continue. --%>
        <div :if={@totp_backup_codes} class="space-y-4">
          <p style="font-size:0.875rem;">
            {gettext(
              "Two-factor is on. Save these backup codes somewhere safe — each works once if you lose your device."
            )}
          </p>
          <ul
            class="grid grid-cols-2 gap-x-6 gap-y-1.5 rounded-[var(--ed-radius)] p-3 font-mono"
            style="background: var(--ed-surface-2); font-size:0.875rem; letter-spacing:0.04em;"
          >
            <li :for={c <- @totp_backup_codes}>{c}</li>
          </ul>
          <button type="button" phx-click="finish" class="ed-btn ed-btn--primary w-full">
            {gettext("I've saved them — continue")}
          </button>
        </div>

        <%!-- Mid-setup: QR + manual key + confirm-code form + skip. --%>
        <div :if={@totp_setup} class="space-y-4">
          <div class="flex flex-wrap items-start gap-4">
            <div class="rounded-[var(--ed-radius)] p-2" style="background:#fff; width:184px;">
              {Phoenix.HTML.raw(@totp_setup.qr)}
            </div>
            <div class="space-y-1.5">
              <span style="font-size:0.75rem; color: var(--ed-muted);">
                {gettext("Or enter this key manually")}
              </span>
              <code
                class="block rounded-[var(--ed-radius)] px-2 py-1.5 font-mono break-all"
                style="background: var(--ed-surface-2); font-size:0.8125rem; letter-spacing:0.06em; max-width:16rem;"
              >
                {@totp_setup.key}
              </code>
            </div>
          </div>

          <.form for={%{}} as={:totp} phx-submit="activate" class="space-y-3">
            <label class="block space-y-1.5">
              <span style="font-size:0.8125rem; color: var(--ed-muted);">
                {gettext("Enter the 6-digit code")}
              </span>
              <input
                type="text"
                name="totp[code]"
                value=""
                inputmode="numeric"
                autocomplete="one-time-code"
                class="ed-input"
                required
                autofocus
              />
            </label>
            <p :if={@totp_error} style="color: var(--ed-danger); font-size:0.75rem;">
              {@totp_error}
            </p>
            <button type="submit" class="ed-btn ed-btn--primary w-full">
              {gettext("Turn on two-factor")}
            </button>
          </.form>

          <button type="button" phx-click="skip" class="ed-btn ed-btn--ghost w-full">
            {gettext("Skip for now")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
