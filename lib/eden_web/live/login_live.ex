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
        <h1 class="mb-1" style="font-size:1.375rem; font-weight:650;">{gettext("Log in to eden")}</h1>
        <p class="mb-6" style="color: var(--ed-muted); font-size:0.875rem;">
          {gettext("Use your username and password.")}
        </p>

        <.auth_flash flash={@flash} />

        <.form for={@form} action={~p"/users/log_in"} class="space-y-4">
          <label class="block space-y-1.5">
            <span style="font-size:0.8125rem; color: var(--ed-muted);">{gettext("Username")}</span>
            <input
              class="ed-input"
              type="text"
              name="user[username]"
              autocomplete="username"
              required
              autofocus
            />
          </label>
          <label class="block space-y-1.5">
            <span style="font-size:0.8125rem; color: var(--ed-muted);">{gettext("Password")}</span>
            <input
              class="ed-input"
              type="password"
              name="user[password]"
              autocomplete="current-password"
              required
            />
          </label>
          <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Log in")}</button>
        </.form>
      </div>
    </div>
    """
  end

  defp auth_flash(assigns) do
    ~H"""
    <div class="space-y-2 mb-4 empty:hidden">
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="ed-toast ed-toast--error">
        <span class="ed-toast__bar"></span>{msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="ed-toast ed-toast--info">
        <span class="ed-toast__bar"></span>{msg}
      </div>
    </div>
    """
  end
end
