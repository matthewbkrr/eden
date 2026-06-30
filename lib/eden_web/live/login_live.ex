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
          <.ed_field
            field={@form[:username]}
            label={gettext("Username")}
            autocomplete="username"
            required
            autofocus
          />
          <.ed_field
            field={@form[:password]}
            label={gettext("Password")}
            type="password"
            autocomplete="current-password"
            required
          />
          <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Log in")}</button>
        </.form>
      </div>
    </div>
    """
  end
end
