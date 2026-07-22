defmodule EdenWeb.LoginLive do
  @moduledoc "Username + password sign-in. The form posts natively to the session controller."
  use EdenWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"), page_title: gettext("Log in"))}
  end

  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen grid place-items-center px-5 py-10">
      <div class="w-full max-w-sm">
        <h1 class="mb-1" style="font-size:1.375rem; font-weight:650;">
          {gettext("Log in to ihichat")}
        </h1>
        <p class="mb-6" style="color: var(--ed-muted); font-size:0.875rem;">
          {gettext("Use your username and password.")}
        </p>

        <.ed_flash flash={@flash} />

        <%!-- phx-update="ignore": the form posts natively (no phx-submit/phx-change), so the
              connect re-render has no reason to touch it — and must not. Without this, anything
              typed during the dead render is wiped when the socket connects and re-renders the
              empty form (#153). --%>
        <.form
          for={@form}
          action={~p"/users/log_in"}
          id="login-form"
          phx-update="ignore"
          class="space-y-4"
        >
          <%!-- autocapitalize/autocorrect off: usernames are lowercase @tags, and mobile
                keyboards (#417 — iOS WebView) otherwise capitalize/"fix" the first typed
                character into a failed login. --%>
          <.ed_field
            field={@form[:username]}
            label={gettext("Username")}
            autocomplete="username"
            autocapitalize="none"
            autocorrect="off"
            spellcheck="false"
            required
            autofocus
          />
          <.ed_password_field
            field={@form[:password]}
            label={gettext("Password")}
            autocomplete="current-password"
            required
          />
          <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Log in")}</button>
        </.form>

        <%!-- No email self-recovery by design — the only path back is an admin-minted reset link
              (#368/R087). Say so, so a locked-out user knows where to go. --%>
        <p class="mt-5 text-center" style="color: var(--ed-muted); font-size:0.8125rem;">
          {gettext("Forgot your password? Ask an admin to send you a reset link.")}
        </p>
      </div>
    </div>
    """
  end
end
