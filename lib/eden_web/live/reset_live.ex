defmodule EdenWeb.ResetLive do
  @moduledoc """
  Redeems an admin-issued password-reset link (#232) at `/reset/:token`. Shows a
  new-password form when the token is valid, an "expired" state otherwise; on
  submit it sets the new password (and revokes all the user's sessions) then sends
  the person to sign in. No account is revealed — the token stands alone.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Reset password"), token: token)
     |> assign(valid?: Accounts.reset_token_valid?(token), form: to_form(%{}, as: :reset))}
  end

  @impl true
  def handle_event("submit", %{"reset" => %{"password" => password}}, socket) do
    case Accounts.reset_password_with_token(socket.assigns.token, password) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password set. Please sign in."))
         |> push_navigate(to: ~p"/login")}

      {:error, reason} when reason in [:invalid, :expired] ->
        {:noreply, assign(socket, valid?: false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :reset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen flex items-center justify-center px-5">
      <%!-- NotifyHook is mounted on this session; host the notifier so its push_event("notify")
            has a receiver (a logged-in user redeeming a reset). No-op when logged out —
            notify_prefs is nil then (#367/R204). --%>
      <.notifier :if={@notify_prefs} prefs={@notify_prefs} />
      <div
        class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-6"
        style="border-color: var(--ed-border); background: var(--ed-surface);"
      >
        <h1 style="font-size:1.25rem; font-weight:650;">{gettext("Reset password")}</h1>
        <.ed_flash flash={@flash} />

        <div :if={@valid?}>
          <p class="mt-1 mb-5" style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("Choose a new password (at least 8 characters).")}
          </p>
          <.form for={@form} phx-submit="submit" class="space-y-4">
            <label class="block space-y-1.5">
              <span style="font-size:0.8125rem; color: var(--ed-muted);">
                {gettext("New password")}
              </span>
              <input
                type="password"
                name={@form[:password].name}
                value=""
                class="ed-input"
                autocomplete="new-password"
                minlength="8"
                required
              />
              <span
                :for={msg <- Enum.map(@form[:password].errors, &translate_error/1)}
                style="color: var(--ed-danger-strong); font-size:0.75rem;"
              >
                {msg}
              </span>
            </label>
            <button type="submit" class="ed-btn ed-btn--primary w-full">
              {gettext("Set new password")}
            </button>
          </.form>
        </div>

        <div :if={!@valid?}>
          <p class="mt-1" style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("This reset link is invalid or has expired. Ask an admin for a new one.")}
          </p>
          <.link navigate={~p"/login"} class="ed-btn ed-btn--ghost w-full mt-5 justify-center">
            {gettext("Back to sign in")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
