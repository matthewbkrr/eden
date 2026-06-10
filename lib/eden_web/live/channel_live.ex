defmodule EdenWeb.ChannelLive do
  @moduledoc """
  A channel workspace (corporate layer, epic #26): the rail on the far left,
  the channel sidebar (header + menu; the rooms list arrives with #29), and a
  placeholder main pane. Authorization is by channel membership — a
  non-member is redirected home with a flash, same pattern as conversations.
  """
  use EdenWeb, :live_view

  on_mount EdenWeb.RailHook

  import EdenWeb.ShellComponents

  alias Eden.Channels

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Channels"),
       channel: nil,
       subscribed_id: nil,
       show_rename: false,
       rename_form: nil
     )}
  end

  @impl true
  def handle_params(%{"channel_id" => id}, _uri, socket) do
    case Channels.get_channel(socket.assigns.current_scope, id) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> resubscribe(channel.id)
         |> assign(channel: channel, page_title: channel.name)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Channel not found."))
         |> push_navigate(to: ~p"/app")}
    end
  end

  # One channel-topic subscription at a time (live_patch between channels).
  defp resubscribe(socket, channel_id) do
    if old = socket.assigns.subscribed_id, do: Channels.unsubscribe_channel(old)
    Channels.subscribe_channel(channel_id)
    assign(socket, subscribed_id: channel_id)
  end

  @impl true
  def handle_event("open_rename", _params, socket) do
    # The context re-checks on write; this just keeps the modal admin-only.
    if socket.assigns.channel.role in ~w(owner admin) do
      form = to_form(Channels.change_channel(socket.assigns.channel))
      {:noreply, assign(socket, show_rename: true, rename_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_rename", _params, socket) do
    {:noreply, assign(socket, show_rename: false)}
  end

  def handle_event("rename_channel", %{"channel" => params}, socket) do
    case Channels.update_channel(socket.assigns.current_scope, socket.assigns.channel.id, params) do
      {:ok, channel} ->
        {:noreply, assign(socket, channel: channel, show_rename: false, page_title: channel.name)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rename_form: to_form(changeset))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(show_rename: false)
         |> put_flash(:error, gettext("Couldn't update that channel."))}
    end
  end

  def handle_event("delete_channel", _params, socket) do
    case Channels.delete_channel(socket.assigns.current_scope, socket.assigns.channel.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Channel deleted."))
         |> push_navigate(to: ~p"/app")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete that channel."))}
    end
  end

  @impl true
  def handle_info({:channel_renamed, renamed}, socket) do
    # The broadcast carries the actor's role — keep this session's own.
    channel = %{renamed | role: socket.assigns.channel.role}
    {:noreply, assign(socket, channel: channel, page_title: channel.name)}
  end

  def handle_info({:channel_deleted, _id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("This channel was deleted."))
     |> push_navigate(to: ~p"/app")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root h-screen flex overflow-hidden">
      <div class="fixed top-20 left-1/2 -translate-x-1/2 z-40 w-full max-w-sm px-4 pointer-events-none">
        <.ed_flash flash={@flash} />
      </div>

      <.rail channels={@channels} active={@channel && @channel.id} />

      <aside
        :if={@channel}
        class="flex-1 min-w-0 md:flex-none md:w-80 border-r flex flex-col"
        style="border-color: var(--ed-border);"
      >
        <header
          class="flex items-center justify-between gap-2 px-4 h-14 border-b"
          style="border-color: var(--ed-border);"
        >
          <div class="min-w-0">
            <div class="font-semibold truncate">{@channel.name}</div>
            <div
              :if={@channel.about}
              class="truncate"
              style="font-size:0.6875rem; color: var(--ed-muted);"
            >
              {@channel.about}
            </div>
          </div>
          <%!-- click-away lives on the wrapper, not the menu: the opening click
                (on the button) is inside the wrapper, so it can't instantly
                re-hide what the toggle just showed. --%>
          <div
            class="relative shrink-0"
            phx-click-away={JS.hide(to: "#channel-menu")}
            phx-window-keydown={JS.hide(to: "#channel-menu")}
            phx-key="escape"
          >
            <button
              type="button"
              class="ed-btn--icon"
              phx-click={JS.toggle(to: "#channel-menu")}
              aria-haspopup="menu"
              aria-label={gettext("Channel menu")}
            >
              <.icon name="hero-ellipsis-horizontal-mini" class="size-5" />
            </button>
            <%!-- display:none inline, NOT the hidden attribute: Tailwind's
                  preflight makes [hidden] !important, which would override the
                  inline display JS.toggle applies. --%>
            <div
              id="channel-menu"
              class="ed-menu ed-menu--anchored"
              role="menu"
              style="display: none;"
            >
              <button
                :if={@channel.role in ~w(owner admin)}
                type="button"
                class="ed-menu__item"
                role="menuitem"
                phx-click={JS.hide(to: "#channel-menu") |> JS.push("open_rename")}
              >
                <.icon name="hero-pencil-micro" class="size-4" /> {gettext("Edit channel")}
              </button>
              <div :if={@channel.role == "owner"} class="ed-menu__sep"></div>
              <button
                :if={@channel.role == "owner"}
                type="button"
                class="ed-menu__item ed-menu__item--danger"
                role="menuitem"
                phx-click="delete_channel"
                data-confirm={gettext("Delete this channel for everyone? This cannot be undone.")}
              >
                <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete channel")}
              </button>
            </div>
          </div>
        </header>

        <%!-- Rooms list lands with #29. --%>
        <div class="flex-1 overflow-y-auto p-2">
          <p class="text-center py-8" style="color: var(--ed-muted); font-size:0.875rem;">
            {gettext("Thematic chats will appear here.")}
          </p>
        </div>
      </aside>

      <main class="flex-1 hidden md:flex flex-col min-w-0" style="background: var(--ed-bg);">
        <div class="flex-1 grid place-items-center text-center p-8">
          <div :if={@channel} class="space-y-2 max-w-sm">
            <p style="font-weight:600;">{@channel.name}</p>
            <p :if={@channel.about} style="color: var(--ed-muted); font-size:0.875rem;">
              {@channel.about}
            </p>
            <p style="color: var(--ed-muted); font-size:0.875rem;">
              {gettext("Thematic chats will appear here.")}
            </p>
          </div>
        </div>
      </main>

      <.channel_form_modal
        :if={@show_new_channel}
        id="new-channel"
        title={gettext("New channel")}
        form={@new_channel_form}
        submit="rail_create_channel"
        close="rail_close_new_channel"
        submit_label={gettext("Create channel")}
      />
      <.channel_form_modal
        :if={@show_rename}
        id="rename-channel"
        title={gettext("Edit channel")}
        form={@rename_form}
        submit="rename_channel"
        close="close_rename"
        submit_label={gettext("Save")}
      />
    </div>
    """
  end
end
