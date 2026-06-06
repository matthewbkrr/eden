defmodule EdenWeb.SettingsLive do
  @moduledoc """
  Device preferences: appearance (theme) and language. These are stored per
  device (theme in localStorage via the manager in root.html.heex; language in
  the session via `EdenWeb.LocaleController`) and work before sign-in. When
  accounts land (Phase 1), account-scoped settings live alongside this screen.
  """
  use EdenWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Settings"), locale: Gettext.get_locale())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen">
      <div class="mx-auto max-w-xl px-5 sm:px-6 py-10">
        <header class="flex items-center gap-3 mb-8">
          <.link navigate={~p"/app"} class="ed-btn--icon" aria-label={gettext("Back")}>
            <.icon name="hero-arrow-left-mini" class="size-5" />
          </.link>
          <h1 style="font-size:1.375rem; font-weight:650;">{gettext("Settings")}</h1>
        </header>

        <div class="space-y-6">
          <section
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Appearance")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Choose how eden looks on this device.")}
            </p>
            <div class="flex items-center justify-between gap-4">
              <span style="font-size:0.875rem;">{gettext("Theme")}</span>
              <div class="ed-seg" role="group" aria-label={gettext("Theme")}>
                <button
                  class="ed-seg__btn"
                  data-active="system"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="system"
                >
                  <.icon name="hero-computer-desktop-micro" class="size-4" /> {gettext("System")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="light"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="light"
                >
                  <.icon name="hero-sun-micro" class="size-4" /> {gettext("Light")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="dark"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="dark"
                >
                  <.icon name="hero-moon-micro" class="size-4" /> {gettext("Dark")}
                </button>
              </div>
            </div>
          </section>

          <section
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Language")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Changes the language across eden.")}
            </p>
            <form action={~p"/locale"} method="post" class="flex items-center justify-between gap-4">
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="return_to" value={~p"/settings"} />
              <span style="font-size:0.875rem;">{gettext("Interface language")}</span>
              <div class="ed-seg" role="group" aria-label={gettext("Language")}>
                <button
                  class={["ed-seg__btn", @locale == "en" && "is-active"]}
                  name="locale"
                  value="en"
                  type="submit"
                >
                  English
                </button>
                <button
                  class={["ed-seg__btn", @locale == "ru" && "is-active"]}
                  name="locale"
                  value="ru"
                  type="submit"
                >
                  Русский
                </button>
              </div>
            </form>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
