defmodule EdenWeb.UiLive do
  @moduledoc """
  Dev-only design-system style guide (the "kitchen sink").

  Renders every eden component in one page against the live token system so the
  visual language can be reviewed in light / dark / system themes. Mounted only
  under the `:dev_routes` scope in the router; it is not part of the product.
  """
  use EdenWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Design system")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen">
      <header
        class="sticky top-0 z-20 flex items-center justify-between gap-4 px-5 sm:px-8 h-14 border-b"
        style="background: color-mix(in oklab, var(--ed-bg) 86%, transparent); backdrop-filter: blur(8px); border-color: var(--ed-border);"
      >
        <div class="flex items-baseline gap-2.5 min-w-0">
          <span class="font-semibold tracking-tight" style="font-size: 0.9375rem;">eden</span>
          <span style="color: var(--ed-muted); font-size: 0.8125rem;">design system</span>
        </div>
        <.theme_switch />
      </header>

      <main class="mx-auto max-w-5xl px-5 sm:px-8 py-10 space-y-14">
        <.section
          title="Color tokens"
          hint="Semantic, theme-aware. Same names, different values per theme."
        >
          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
            <.swatch name="bg" var="--ed-bg" />
            <.swatch name="surface" var="--ed-surface" />
            <.swatch name="surface-2" var="--ed-surface-2" />
            <.swatch name="border" var="--ed-border" />
            <.swatch name="ink" var="--ed-ink" />
            <.swatch name="muted" var="--ed-muted" />
            <.swatch name="primary" var="--ed-primary" />
            <.swatch name="primary-strong" var="--ed-primary-strong" />
            <.swatch name="online" var="--ed-online" />
            <.swatch name="danger" var="--ed-danger" />
            <.swatch name="warning" var="--ed-warning" />
          </div>
        </.section>

        <.section title="Typography" hint="One system sans, fixed rem scale (~1.2 ratio).">
          <div class="space-y-2">
            <p style="font-size:1.75rem; font-weight:700; letter-spacing:-0.02em;">
              Display · screen titles
            </p>
            <p style="font-size:1.375rem; font-weight:650;">H1 · section header</p>
            <p style="font-size:1.125rem; font-weight:600;">H2 · sub-header</p>
            <p style="font-size:0.9375rem;">
              Body · the conversation is the product. Calm, readable text at a comfortable size for chat.
            </p>
            <p style="font-size:0.875rem; font-weight:550;">Label · buttons and form fields</p>
            <p style="color: var(--ed-muted); font-family: var(--ed-mono); font-size:0.75rem;">
              meta · 14:32 · timestamps & captions
            </p>
          </div>
        </.section>

        <.section title="Buttons" hint="default · hover · disabled, with a visible focus ring.">
          <div class="flex flex-wrap items-center gap-3">
            <button class="ed-btn ed-btn--primary">
              <.icon name="hero-paper-airplane-micro" class="size-4" /> Send message
            </button>
            <button class="ed-btn ed-btn--secondary">Secondary</button>
            <button class="ed-btn ed-btn--ghost">Ghost</button>
            <button class="ed-btn ed-btn--danger">Delete</button>
            <button class="ed-btn ed-btn--primary" disabled>Disabled</button>
            <button class="ed-btn--icon" aria-label="More">
              <.icon name="hero-ellipsis-horizontal-mini" class="size-5" />
            </button>
            <button class="ed-btn--icon" aria-label="Attach">
              <.icon name="hero-photo-micro" class="size-5" />
            </button>
          </div>
        </.section>

        <.section title="Inputs">
          <div class="grid sm:grid-cols-2 gap-4 max-w-2xl">
            <label class="block space-y-1.5">
              <span style="font-size:0.8125rem; color: var(--ed-muted);">Display name</span>
              <input class="ed-input" type="text" value="Anna" />
            </label>
            <label class="block space-y-1.5">
              <span style="font-size:0.8125rem; color: var(--ed-muted);">Search</span>
              <div class="relative">
                <span
                  class="absolute left-2.5 top-1/2 -translate-y-1/2"
                  style="color: var(--ed-muted);"
                >
                  <.icon name="hero-magnifying-glass-micro" class="size-4" />
                </span>
                <input class="ed-input pl-8" type="text" placeholder="Search conversations" />
              </div>
            </label>
          </div>
        </.section>

        <.section title="Avatars">
          <div class="flex items-end gap-5">
            <span class="ed-avatar ed-avatar--sm">МК</span>
            <span class="ed-avatar">АН</span>
            <span class="ed-avatar">АН<span class="ed-avatar__dot"></span></span>
            <span class="ed-avatar ed-avatar--lg">
              <img src={~p"/images/logo.svg"} alt="" /><span class="ed-avatar__dot"></span>
            </span>
          </div>
        </.section>

        <.section title="Badges, pills & tags">
          <div class="flex flex-wrap items-center gap-3">
            <span class="ed-badge">3</span>
            <span class="ed-badge">12</span>
            <span class="ed-pill"><span class="ed-pill__dot"></span> Online</span>
            <span class="ed-pill" style="--ed-online: var(--ed-muted);">
              <span class="ed-pill__dot"></span> Last seen recently
            </span>
            <span class="ed-tag">Photo</span>
            <span class="ed-tag">Group</span>
          </div>
        </.section>

        <.section
          title="Message bubbles"
          hint="Incoming neutral, your own in cobalt; timestamp + read ticks."
        >
          <div class="flex flex-col gap-2 max-w-xl">
            <div class="ed-bubble--system">Today</div>
            <div class="ed-bubble ed-bubble--them">
              Hey! Did the photos from yesterday come through?
              <span class="ed-bubble__meta">14:30</span>
            </div>
            <div class="ed-bubble ed-bubble--them">
              The light at the lake was unreal. <span class="ed-bubble__meta">14:30</span>
            </div>
            <div class="ed-bubble ed-bubble--me">
              Yeah, just got them. Sending the best one now.
              <span class="ed-bubble__meta">
                14:32
                <span class="inline-flex items-center" style="margin-left:1px;">
                  <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
                  <.icon name="hero-check-micro" class="size-3.5" />
                </span>
              </span>
            </div>
            <div class="ed-bubble ed-bubble--me" style="padding:0.25rem; overflow:hidden;">
              <div
                class="rounded-[0.7rem] grid place-items-center"
                style="width:13rem; height:9rem; background: var(--ed-surface-2); color: var(--ed-muted);"
              >
                <.icon name="hero-photo" class="size-8" />
              </div>
              <span class="ed-bubble__meta" style="padding:0.25rem 0.4rem 0.15rem;">
                14:33
                <span class="inline-flex items-center" style="margin-left:1px;">
                  <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
                  <.icon name="hero-check-micro" class="size-3.5" />
                </span>
              </span>
            </div>
            <div class="ed-typing" aria-label="Anna is typing">
              <span></span><span></span><span></span>
            </div>
          </div>
        </.section>

        <.section title="Conversation list">
          <div
            class="max-w-sm p-2 rounded-[var(--ed-radius-lg)] border"
            style="background: var(--ed-bg); border-color: var(--ed-border);"
          >
            <.convo
              name="Anna Korableva"
              preview="Sending the best one now"
              time="14:33"
              online
              unread="2"
              active
            />
            <.convo name="Lake trip 🏔" preview="Mike: who's driving?" time="13:10" unread="5" />
            <.convo name="Dmitry" preview="You: see you tomorrow" time="Mon" />
            <.convo name="Sofia" preview="Photo" time="Sun" online />
          </div>
        </.section>

        <.section title="Empty state" hint="Teach the interface, don't just say 'nothing here'.">
          <div
            class="flex flex-col items-center text-center gap-2 py-12 rounded-[var(--ed-radius-lg)] border"
            style="border-color: var(--ed-border); border-style: dashed;"
          >
            <span
              class="ed-btn--icon"
              style="background: var(--ed-surface-2); width:3rem; height:3rem; color: var(--ed-muted);"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-6" />
            </span>
            <p style="font-weight:600;">No conversation selected</p>
            <p style="color: var(--ed-muted); font-size:0.875rem; max-width:22rem;">
              Pick a chat on the left, or start a new one. Your messages stay in sync across this browser.
            </p>
            <button class="ed-btn ed-btn--primary" style="margin-top:0.5rem;">
              <.icon name="hero-plus-micro" class="size-4" /> New conversation
            </button>
          </div>
        </.section>

        <.section title="Toasts">
          <div class="space-y-2.5 max-w-md">
            <div class="ed-toast ed-toast--info">
              <span class="ed-toast__bar"></span> Reconnecting…
            </div>
            <div class="ed-toast ed-toast--success">
              <span class="ed-toast__bar"></span> Photo sent
            </div>
            <div class="ed-toast ed-toast--error">
              <span class="ed-toast__bar"></span> Couldn't send. We'll retry automatically.
            </div>
          </div>
        </.section>

        <.section title="Assembled preview" hint="The pieces together: list + chat.">
          <div
            class="grid grid-cols-[14rem_1fr] h-80 rounded-[var(--ed-radius-lg)] overflow-hidden border"
            style="border-color: var(--ed-border);"
          >
            <aside
              class="p-2 border-r overflow-hidden"
              style="background: var(--ed-bg); border-color: var(--ed-border);"
            >
              <.convo
                name="Anna"
                preview="Sending the best one"
                time="14:33"
                online
                unread="2"
                active
              />
              <.convo name="Lake trip" preview="Mike: who's driving?" time="13:10" />
              <.convo name="Dmitry" preview="You: see you tomorrow" time="Mon" />
            </aside>
            <div class="flex flex-col min-w-0" style="background: var(--ed-bg);">
              <div
                class="flex items-center gap-3 px-4 h-14 border-b"
                style="border-color: var(--ed-border);"
              >
                <span class="ed-avatar ed-avatar--sm">АН<span class="ed-avatar__dot"></span></span>
                <div class="min-w-0">
                  <div style="font-weight:600; font-size:0.875rem;">Anna</div>
                  <div style="color: var(--ed-online); font-size:0.6875rem;">online</div>
                </div>
                <button class="ed-btn--icon ml-auto" aria-label="More">
                  <.icon name="hero-ellipsis-horizontal-mini" class="size-5" />
                </button>
              </div>
              <div class="flex-1 flex flex-col gap-2 p-4 overflow-hidden">
                <div class="ed-bubble ed-bubble--them">
                  Did the photos come through?<span class="ed-bubble__meta">14:30</span>
                </div>
                <div class="ed-bubble ed-bubble--me">
                  Yeah, sending now.<span class="ed-bubble__meta">14:32</span>
                </div>
              </div>
              <div
                class="flex items-center gap-2 p-3 border-t"
                style="border-color: var(--ed-border);"
              >
                <button class="ed-btn--icon" aria-label="Attach">
                  <.icon name="hero-photo-micro" class="size-5" />
                </button>
                <input class="ed-input" placeholder="Message" />
                <button
                  class="ed-btn ed-btn--primary shrink-0"
                  style="width:2.5rem; padding:0; border-radius:var(--ed-radius-full);"
                  aria-label="Send"
                >
                  <.icon name="hero-paper-airplane-micro" class="size-4" />
                </button>
              </div>
            </div>
          </div>
        </.section>
      </main>
    </div>
    """
  end

  # --- local presentational components ------------------------------------

  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="space-y-1">
        <h2 style="font-size:0.75rem; font-weight:600; letter-spacing:0.04em; text-transform:uppercase; color: var(--ed-muted);">
          {@title}
        </h2>
        <p :if={@hint} style="font-size:0.8125rem; color: var(--ed-muted);">{@hint}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :name, :string, required: true
  attr :var, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <div class="ed-swatch" style={"background: var(#{@var});"}></div>
      <div class="flex items-baseline justify-between gap-2">
        <span style="font-size:0.8125rem; font-weight:550;">{@name}</span>
        <code style="font-size:0.6875rem; color: var(--ed-muted); font-family: var(--ed-mono);">
          {@var}
        </code>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :preview, :string, required: true
  attr :time, :string, required: true
  attr :online, :boolean, default: false
  attr :unread, :string, default: nil
  attr :active, :boolean, default: false

  defp convo(assigns) do
    ~H"""
    <button class={["ed-convo", @active && "ed-convo--active"]}>
      <span class="ed-avatar">
        {String.slice(@name, 0, 1)}<span :if={@online} class="ed-avatar__dot"></span>
      </span>
      <span class="ed-convo__body">
        <span class="ed-convo__top">
          <span class="ed-convo__name">{@name}</span>
          <span class="ed-convo__time">{@time}</span>
        </span>
        <span class="ed-convo__top">
          <span class="ed-convo__preview">{@preview}</span>
          <span :if={@unread} class="ed-badge">{@unread}</span>
        </span>
      </span>
    </button>
    """
  end

  # Theme switch: dispatches `phx:set-theme`, handled by the manager in root.html.heex.
  defp theme_switch(assigns) do
    ~H"""
    <div
      class="flex items-center gap-0.5 p-0.5 rounded-[var(--ed-radius-full)]"
      style="background: var(--ed-surface-2);"
    >
      <button
        class="ed-btn--icon"
        style="width:2rem;height:2rem;"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>
      <button
        class="ed-btn--icon"
        style="width:2rem;height:2rem;"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>
      <button
        class="ed-btn--icon"
        style="width:2rem;height:2rem;"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
