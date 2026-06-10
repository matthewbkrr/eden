defmodule EdenWeb.ShellComponents do
  @moduledoc """
  The Discord-style app shell: the far-left rail (messenger on top — the
  top-left slot — then the user's channels, then "+") and the shared
  channel form modal (create / rename). Rendered by every workspace LiveView;
  the rail's events and data are wired once in `EdenWeb.RailHook`.
  """
  use Phoenix.Component
  use Gettext, backend: EdenWeb.Gettext

  import EdenWeb.CoreComponents

  use Phoenix.VerifiedRoutes,
    endpoint: EdenWeb.Endpoint,
    router: EdenWeb.Router,
    statics: EdenWeb.static_paths()

  alias Eden.Channels.Channel

  attr :channels, :list, required: true
  attr :active, :any, required: true, doc: ":messenger or a channel id"
  attr :class, :any, default: nil

  @doc """
  The far-left rail. The messenger (DMs — the whole pre-corporate eden) is the
  first, top-left item; the user's channels follow; "+" opens the new-channel
  modal (`rail_new_channel`, handled by `EdenWeb.RailHook`).
  """
  def rail(assigns) do
    ~H"""
    <nav class={["ed-rail", @class]} aria-label={gettext("Workspaces")}>
      <.link
        navigate={~p"/app"}
        class={["ed-rail__btn ed-rail__btn--home", @active == :messenger && "ed-rail__btn--active"]}
        title={gettext("Messages")}
        aria-label={gettext("Messages")}
      >
        <.icon name="hero-chat-bubble-left-right" class="size-5" />
      </.link>

      <div :if={@channels != []} class="ed-rail__sep"></div>

      <.link
        :for={channel <- @channels}
        navigate={~p"/channels/#{channel.id}"}
        class={["ed-rail__btn", @active == channel.id && "ed-rail__btn--active"]}
        title={channel.name}
        aria-label={channel.name}
      >
        {channel_initials(channel.name)}
      </.link>

      <button
        type="button"
        class="ed-rail__btn ed-rail__btn--new"
        phx-click="rail_new_channel"
        title={gettext("New channel")}
        aria-label={gettext("New channel")}
      >
        <.icon name="hero-plus-micro" class="size-5" />
      </button>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :submit, :string, required: true
  attr :close, :string, required: true
  attr :submit_label, :string, required: true

  @doc "Shared channel form modal — used for both create (rail) and rename (channel menu)."
  def channel_form_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30" id={@id}>
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click={@close}
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown={@close}
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{@title}</h2>
            <button class="ed-btn--icon" phx-click={@close} aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <.form for={@form} id={"#{@id}-form"} phx-submit={@submit} class="space-y-4">
            <.ed_field
              field={@form[:name]}
              label={gettext("Channel name")}
              maxlength={Channel.max_name()}
            />
            <.ed_field
              field={@form[:about]}
              label={gettext("About (optional)")}
              maxlength={Channel.max_about()}
            />
            <div class="flex justify-end">
              <button type="submit" class="ed-btn ed-btn--primary">{@submit_label}</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @doc "Up to two initials for a channel's rail icon."
  def channel_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
