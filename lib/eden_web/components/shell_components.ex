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
      <%!-- The channel list scrolls; the bottom block (settings/logout) is
            pinned outside it so it never scrolls away with many channels. --%>
      <div class="ed-rail__scroll">
        <.link
          navigate={~p"/app"}
          class={[
            "ed-rail__btn ed-rail__btn--home",
            @active == :messenger && "ed-rail__btn--active"
          ]}
          title={gettext("Messages")}
          aria-label={gettext("Messages")}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-5" />
        </.link>

        <div :if={@channels != []} class="ed-rail__sep"></div>

        <%!-- Full hook name, not the ".ContextMenu" shorthand: colocated hooks
            resolve relative to the template's module, and this template
            compiles in ShellComponents — the hook lives in ChatLive. --%>
        <span
          :for={channel <- @channels}
          id={"rail-channel-#{channel.id}"}
          class="ed-rail__slot"
          phx-hook="EdenWeb.ChatLive.ContextMenu"
        >
          <%!-- Desktop reopens the channel's remembered room directly (#81), so
                switching channels lands where you left off. On mobile that skips
                the room-choice screen with no way back, so mobile goes to the bare
                channel (its room list) instead (#92). Two links toggled by
                viewport; with no entry room yet, both fall back to the bare
                channel, so only the second link renders. --%>
          <.link
            :if={channel.entry_room_id}
            navigate={~p"/channels/#{channel.id}/r/#{channel.entry_room_id}"}
            class={[
              "ed-rail__btn hidden md:inline-flex",
              @active == channel.id && "ed-rail__btn--active"
            ]}
            title={channel.name}
            aria-label={rail_label(channel)}
            aria-haspopup="menu"
          >
            <.rail_channel_face channel={channel} />
          </.link>
          <.link
            navigate={~p"/channels/#{channel.id}"}
            class={[
              "ed-rail__btn",
              channel.entry_room_id && "md:hidden",
              @active == channel.id && "ed-rail__btn--active"
            ]}
            title={channel.name}
            aria-label={rail_label(channel)}
            aria-haspopup="menu"
          >
            <.rail_channel_face channel={channel} />
          </.link>
          <span
            :if={channel.unread_count > 0}
            class={["ed-rail__badge", channel.muted && "ed-rail__badge--muted"]}
            aria-hidden="true"
          >
            {rail_badge_text(channel.unread_count)}
          </span>
          <div class="ed-menu" id={"rail-menu-#{channel.id}"} data-menu role="menu" hidden>
            <button
              type="button"
              class="ed-menu__item"
              role="menuitem"
              phx-click="toggle_channel_mute"
              phx-value-id={channel.id}
            >
              <.icon
                name={if channel.muted, do: "hero-bell-micro", else: "hero-bell-slash-micro"}
                class="size-4"
              />
              {if channel.muted, do: gettext("Unmute channel"), else: gettext("Mute channel")}
            </button>
          </div>
        </span>

        <button
          type="button"
          class="ed-rail__btn ed-rail__btn--new"
          phx-click="rail_new_channel"
          title={gettext("New channel")}
          aria-label={gettext("New channel")}
        >
          <.icon name="hero-plus-micro" class="size-5" />
        </button>
      </div>

      <div class="ed-rail__bottom">
        <.link
          navigate={~p"/settings"}
          class="ed-rail__btn ed-rail__btn--ghost"
          title={gettext("Settings")}
          aria-label={gettext("Settings")}
        >
          <.icon name="hero-cog-6-tooth" class="size-5" />
        </.link>
        <.link
          href={~p"/users/log_out"}
          method="delete"
          class="ed-rail__btn ed-rail__btn--ghost"
          title={gettext("Log out")}
          aria-label={gettext("Log out")}
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
        </.link>
      </div>
    </nav>
    """
  end

  # The rail button's face: channel avatar (#70) when set, initials fallback
  # otherwise (?v= cache-busts per avatar). Shared by the two viewport-toggled
  # rail links (#92) so they can't drift apart.
  attr :channel, :any, required: true

  defp rail_channel_face(assigns) do
    ~H"""
    <img :if={@channel.avatar_key} src={channel_avatar_src(@channel)} alt="" class="ed-rail__img" />
    <span :if={!@channel.avatar_key}>{channel_initials(@channel.name)}</span>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :submit, :string, required: true
  attr :close, :string, required: true
  attr :submit_label, :string, required: true
  # Edit mode only (#70): the existing channel + its avatar upload + a phx-change
  # event (live uploads need one to register the selected entry). nil on create
  # (the channel doesn't exist yet, so there's nothing to attach an avatar to).
  attr :channel, :map, default: nil
  attr :upload, :any, default: nil
  attr :change, :string, default: nil

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

          <.form
            for={@form}
            id={"#{@id}-form"}
            phx-change={@change}
            phx-submit={@submit}
            class="space-y-4"
          >
            <%!-- Channel avatar (#70): edit mode only; the upload rides the save. --%>
            <div :if={@channel} class="flex items-center gap-4">
              <% entry = @upload && List.first(@upload.entries) %>
              <span class="ed-avatar ed-avatar--lg" aria-hidden="true">
                <.live_img_preview :if={entry} entry={entry} />
                <img
                  :if={!entry && @channel.avatar_key}
                  src={channel_avatar_src(@channel)}
                  alt=""
                />
                <span :if={!entry && !@channel.avatar_key}>{channel_initials(@channel.name)}</span>
              </span>
              <div class="flex flex-col gap-1.5">
                <div class="flex items-center gap-2">
                  <label class="ed-btn ed-btn--ghost cursor-pointer text-sm">
                    {gettext("Upload photo")}
                    <.live_file_input :if={@upload} upload={@upload} class="sr-only" />
                  </label>
                  <button
                    :if={@channel.avatar_key && @upload && Enum.empty?(@upload.entries)}
                    type="button"
                    phx-click="remove_channel_avatar"
                    class="ed-btn ed-btn--ghost text-sm"
                    style="color: var(--ed-danger);"
                  >
                    {gettext("Remove")}
                  </button>
                  <button
                    :for={e <- (@upload && @upload.entries) || []}
                    type="button"
                    phx-click="cancel_channel_avatar"
                    phx-value-ref={e.ref}
                    class="ed-btn ed-btn--ghost text-sm"
                  >
                    {gettext("Cancel")}
                  </button>
                </div>
                <%!-- Surface a rejected upload (too large / wrong type) instead of
                      failing silently. --%>
                <p
                  :for={err <- (@upload && upload_errors(@upload)) || []}
                  style="color: var(--ed-danger); font-size:0.75rem;"
                >
                  {channel_avatar_error(err)}
                </p>
                <%= for e <- (@upload && @upload.entries) || [] do %>
                  <p
                    :for={err <- upload_errors(@upload, e)}
                    style="color: var(--ed-danger); font-size:0.75rem;"
                  >
                    {channel_avatar_error(err)}
                  </p>
                <% end %>
              </div>
            </div>
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

  @doc "Cache-busted URL for a channel's avatar (#70); nil when it has none."
  def channel_avatar_src(%{id: id, avatar_key: key}) when is_binary(key),
    do: ~p"/channels/#{id}/avatar?v=#{:erlang.phash2(key)}"

  def channel_avatar_src(_channel), do: nil

  # A rejected channel-avatar upload (#70), in human terms.
  defp channel_avatar_error(:too_large), do: gettext("That image is too large (up to 5 MB).")
  defp channel_avatar_error(:not_accepted), do: gettext("Use a JPEG, PNG, GIF or WebP image.")
  defp channel_avatar_error(:too_many_files), do: gettext("Pick a single image.")
  defp channel_avatar_error(_other), do: gettext("Couldn't upload that image.")

  @doc "Up to two initials for a channel's rail icon."
  def channel_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  # The visual badge is aria-hidden, so the unread count rides the icon link's
  # accessible name instead (a screen reader hears "Engineering, 3 unread").
  defp rail_label(%{unread_count: n, name: name}) when n > 0,
    do: gettext("%{name}, %{count} unread", name: name, count: n)

  defp rail_label(%{name: name}), do: name

  # The badge is ~18px; cap the rendered count so 3+ digits don't overflow.
  defp rail_badge_text(n) when n > 99, do: "99+"
  defp rail_badge_text(n), do: Integer.to_string(n)
end
