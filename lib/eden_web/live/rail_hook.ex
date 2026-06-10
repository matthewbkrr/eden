defmodule EdenWeb.RailHook do
  @moduledoc """
  Shared shell behavior for LiveViews that render the left rail (ChatLive,
  ChannelLive): loads the channel list, subscribes to rail updates, and
  handles the rail's events (new-channel modal + creation) and
  `:channels_changed` refreshes via `attach_hook/4` — one implementation
  instead of a copy per LiveView. Events the hook doesn't own fall through
  (`:cont`) to the LiveView's own callbacks.
  """
  use Gettext, backend: EdenWeb.Gettext

  import Phoenix.Component
  import Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: EdenWeb.Endpoint,
    router: EdenWeb.Router,
    statics: EdenWeb.static_paths()

  alias Eden.Channels

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Channels.subscribe_user(scope)

    socket =
      socket
      |> assign(
        channels: Channels.list_channels(scope),
        show_new_channel: false,
        new_channel_form: to_form(Channels.change_channel())
      )
      |> attach_hook(:rail_events, :handle_event, &rail_event/3)
      |> attach_hook(:rail_info, :handle_info, &rail_info/2)

    {:cont, socket}
  end

  defp rail_event("rail_new_channel", _params, socket) do
    {:halt,
     assign(socket, show_new_channel: true, new_channel_form: to_form(Channels.change_channel()))}
  end

  defp rail_event("rail_close_new_channel", _params, socket) do
    {:halt, assign(socket, show_new_channel: false)}
  end

  defp rail_event("rail_create_channel", %{"channel" => params}, socket) do
    case Channels.create_channel(socket.assigns.current_scope, params) do
      {:ok, channel} ->
        {:halt,
         socket
         |> assign(show_new_channel: false)
         |> push_navigate(to: ~p"/channels/#{channel.id}")}

      {:error, :limit} ->
        {:halt,
         socket
         |> assign(show_new_channel: false)
         |> put_flash(
           :error,
           gettext("You can have up to %{count} channels.", count: Channels.max_channels())
         )}

      {:error, changeset} ->
        {:halt, assign(socket, new_channel_form: to_form(changeset))}
    end
  end

  # A hand-crafted "rail_create_channel" without the form payload must not fall
  # through to a LiveView that has no clause for it (FunctionClauseError).
  defp rail_event("rail_create_channel", _params, socket), do: {:halt, socket}

  defp rail_event(_event, _params, socket), do: {:cont, socket}

  defp rail_info(:channels_changed, socket) do
    {:halt, assign(socket, channels: Channels.list_channels(socket.assigns.current_scope))}
  end

  defp rail_info(_message, socket), do: {:cont, socket}
end
