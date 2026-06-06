defmodule EdenWeb.AppHomeLive do
  @moduledoc "Minimal authenticated landing — proves the protected on_mount works. The real chat lands here in Phase 2."
  use EdenWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Home"))}
  end

  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen">
      <header
        class="flex items-center justify-between gap-4 px-5 sm:px-8 h-14 border-b"
        style="border-color: var(--ed-border);"
      >
        <span class="font-semibold tracking-tight" style="font-size:0.9375rem;">eden</span>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/settings"} class="ed-btn--icon" aria-label={gettext("Settings")}>
            <.icon name="hero-cog-6-tooth-mini" class="size-5" />
          </.link>
          <.link href={~p"/users/log_out"} method="delete" class="ed-btn ed-btn--ghost">
            {gettext("Log out")}
          </.link>
        </div>
      </header>

      <main class="mx-auto max-w-2xl px-5 py-16 text-center space-y-2">
        <h1 style="font-size:1.375rem; font-weight:650;">
          {gettext("Welcome, %{name}", name: @current_scope.user.display_name)}
        </h1>
        <p style="color: var(--ed-muted); font-size:0.9375rem;">
          {gettext("You're signed in. Conversations arrive in Phase 2.")}
        </p>
      </main>
    </div>
    """
  end
end
