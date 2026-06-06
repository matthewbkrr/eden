defmodule EdenWeb.ChatLive do
  @moduledoc """
  The chat: a conversation list (sidebar) and the selected conversation's message
  window. Realtime via Chat PubSub; the message collection is a LiveView stream
  with backward pagination. Everything is authorized through the Chat context
  using `current_scope`.
  """
  use EdenWeb, :live_view

  alias Eden.{Accounts, Chat}

  @page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: gettext("Chats"),
        selected: nil,
        subscribed_id: nil,
        show_new: false,
        people: [],
        has_more: false,
        oldest_id: nil,
        composer: to_form(%{}, as: "message")
      )
      |> stream(:conversations, Chat.list_conversations(socket.assigns.current_scope))
      |> stream(:messages, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chat.get_conversation(socket.assigns.current_scope, id) do
      {:ok, conversation} ->
        {:noreply, select_conversation(socket, conversation)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Conversation not found."))
         |> push_navigate(to: ~p"/app")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> unsubscribe() |> assign(selected: nil)}
  end

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns

    if conversation do
      # On success the PubSub broadcast streams the message back to us (and every
      # other member), so there's a single insert path. Errors (blank/too long)
      # just clear nothing.
      Chat.create_message(scope, conversation.id, %{"body" => body})
    end

    {:noreply, assign(socket, composer: to_form(%{}, as: "message"))}
  end

  def handle_event("load_more", _params, socket) do
    %{current_scope: scope, selected: conversation, oldest_id: oldest_id} = socket.assigns

    case conversation && oldest_id &&
           Chat.list_messages(scope, conversation.id, limit: @page, before: oldest_id) do
      {:ok, older} when older != [] ->
        {:noreply,
         socket
         |> stream(:messages, older, at: 0)
         |> assign(has_more: length(older) == @page, oldest_id: hd(older).id)}

      _ ->
        {:noreply, assign(socket, has_more: false)}
    end
  end

  def handle_event("toggle_new", _params, socket) do
    people =
      if socket.assigns.show_new,
        do: socket.assigns.people,
        else: Accounts.list_other_users(socket.assigns.current_scope)

    {:noreply, assign(socket, show_new: !socket.assigns.show_new, people: people)}
  end

  def handle_event("start", %{"member_ids" => ids} = params, socket) do
    scope = socket.assigns.current_scope
    opts = if length(List.wrap(ids)) > 1, do: [group: true, title: params["title"]], else: []

    case Chat.create_conversation(scope, List.wrap(ids), opts) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(show_new: false)
         |> stream(:conversations, Chat.list_conversations(scope), reset: true)
         |> push_patch(to: ~p"/app/c/#{conversation.id}")}

      {:error, :no_members} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't start the conversation."))}
    end
  end

  def handle_event("start", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick at least one person."))}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  ## Helpers

  defp select_conversation(socket, conversation) do
    scope = socket.assigns.current_scope
    socket = unsubscribe(socket)
    Chat.subscribe(conversation.id)
    Chat.mark_read(scope, conversation.id)

    {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)

    socket
    |> assign(
      selected: conversation,
      subscribed_id: conversation.id,
      has_more: length(messages) == @page,
      oldest_id: messages |> List.first() |> then(&(&1 && &1.id))
    )
    |> stream(:messages, messages, reset: true)
  end

  defp unsubscribe(socket) do
    if id = socket.assigns[:subscribed_id], do: Chat.unsubscribe(id)
    assign(socket, subscribed_id: nil)
  end

  defp title(%{is_group: true, title: title}, _user) when is_binary(title) and title != "",
    do: title

  defp title(%{is_group: true} = conversation, user),
    do: conversation |> others(user) |> Enum.map_join(", ", & &1.display_name)

  defp title(conversation, user) do
    case others(conversation, user) do
      [first | _] -> first.display_name
      [] -> gettext("Just you")
    end
  end

  defp others(conversation, user) do
    conversation.memberships
    |> Enum.reject(&(&1.user_id == user.id))
    |> Enum.map(& &1.user)
  end

  defp initials(name), do: name |> String.first() |> String.upcase()

  defp time(at), do: Calendar.strftime(at, "%H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root h-screen flex overflow-hidden">
      <aside
        class={["w-full md:w-80 shrink-0 border-r flex flex-col", @selected && "hidden md:flex"]}
        style="border-color: var(--ed-border);"
      >
        <header
          class="flex items-center justify-between gap-2 px-4 h-14 border-b"
          style="border-color: var(--ed-border);"
        >
          <span class="font-semibold tracking-tight">eden</span>
          <div class="flex items-center gap-1">
            <button
              class="ed-btn--icon"
              phx-click="toggle_new"
              aria-label={gettext("New conversation")}
            >
              <.icon name="hero-pencil-square-mini" class="size-5" />
            </button>
            <.link navigate={~p"/settings"} class="ed-btn--icon" aria-label={gettext("Settings")}>
              <.icon name="hero-cog-6-tooth-mini" class="size-5" />
            </.link>
            <.link
              href={~p"/users/log_out"}
              method="delete"
              class="ed-btn--icon"
              aria-label={gettext("Log out")}
            >
              <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-5" />
            </.link>
          </div>
        </header>

        <div class="flex-1 overflow-y-auto p-2 space-y-0.5" id="conversations" phx-update="stream">
          <.link
            :for={{dom_id, conversation} <- @streams.conversations}
            id={dom_id}
            patch={~p"/app/c/#{conversation.id}"}
            class={["ed-convo", @selected && @selected.id == conversation.id && "ed-convo--active"]}
          >
            <span class="ed-avatar">{initials(title(conversation, @current_scope.user))}</span>
            <span class="ed-convo__body">
              <span class="ed-convo__top">
                <span class="ed-convo__name">{title(conversation, @current_scope.user)}</span>
                <span :if={conversation.last_message_at} class="ed-convo__time">
                  {time(conversation.last_message_at)}
                </span>
              </span>
              <span class="ed-convo__preview">
                {if conversation.is_group, do: gettext("Group"), else: gettext("Direct message")}
              </span>
            </span>
          </.link>
        </div>
      </aside>

      <main
        class={["flex-1 flex flex-col min-w-0", !@selected && "hidden md:flex"]}
        style="background: var(--ed-bg);"
      >
        <%= if @selected do %>
          <header
            class="flex items-center gap-3 px-4 h-14 border-b shrink-0"
            style="border-color: var(--ed-border);"
          >
            <.link navigate={~p"/app"} class="ed-btn--icon md:hidden" aria-label={gettext("Back")}>
              <.icon name="hero-arrow-left-mini" class="size-5" />
            </.link>
            <span class="ed-avatar ed-avatar--sm">
              {initials(title(@selected, @current_scope.user))}
            </span>
            <div class="font-semibold" style="font-size:0.9375rem;">
              {title(@selected, @current_scope.user)}
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4" id="message-scroll" phx-hook=".ScrollBottom">
            <div :if={@has_more} class="text-center mb-3">
              <button class="ed-btn ed-btn--ghost" phx-click="load_more">
                {gettext("Load older")}
              </button>
            </div>
            <div class="flex flex-col gap-2" id="messages" phx-update="stream">
              <div
                :for={{dom_id, message} <- @streams.messages}
                id={dom_id}
                class={["flex", message.sender_id == @current_scope.user.id && "justify-end"]}
              >
                <div class={[
                  "ed-bubble",
                  (message.sender_id == @current_scope.user.id && "ed-bubble--me") ||
                    "ed-bubble--them"
                ]}>
                  <span
                    :if={
                      @selected.is_group and message.sender_id != @current_scope.user.id and
                        message.sender
                    }
                    class="block"
                    style="font-size:0.75rem; font-weight:600; color: var(--ed-primary);"
                  >
                    {message.sender.display_name}
                  </span>
                  {message.body}
                  <span class="ed-bubble__meta">{time(message.inserted_at)}</span>
                </div>
              </div>
            </div>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
              export default {
                mounted() { this.el.scrollTop = this.el.scrollHeight },
                updated() { this.el.scrollTop = this.el.scrollHeight }
              }
            </script>
          </div>

          <.form
            for={@composer}
            phx-submit="send"
            class="flex items-center gap-2 p-3 border-t shrink-0"
            style="border-color: var(--ed-border);"
          >
            <input
              type="text"
              name="message[body]"
              value={@composer[:body].value}
              class="ed-input"
              placeholder={gettext("Message")}
              autocomplete="off"
            />
            <button
              class="ed-btn ed-btn--primary shrink-0"
              style="width:2.5rem; padding:0; border-radius:var(--ed-radius-full);"
              type="submit"
              aria-label={gettext("Send")}
            >
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </button>
          </.form>
        <% else %>
          <div class="flex-1 grid place-items-center text-center p-8">
            <div class="space-y-2">
              <p style="font-weight:600;">{gettext("No conversation selected")}</p>
              <p style="color: var(--ed-muted); font-size:0.875rem;">
                {gettext("Pick a chat or start a new one.")}
              </p>
              <button class="ed-btn ed-btn--primary" phx-click="toggle_new">
                <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("New conversation")}
              </button>
            </div>
          </div>
        <% end %>
      </main>

      <div
        :if={@show_new}
        class="fixed inset-0 z-30 grid place-items-center p-4"
        style="background: oklch(0 0 0 / 0.55);"
      >
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("New conversation")}</h2>
            <button class="ed-btn--icon" phx-click="toggle_new" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <%= if @people == [] do %>
            <p style="color: var(--ed-muted); font-size:0.875rem;">
              {gettext("No one else has joined yet.")}
            </p>
          <% else %>
            <form phx-submit="start" class="space-y-3">
              <input
                type="text"
                name="title"
                class="ed-input"
                placeholder={gettext("Group name (optional)")}
                autocomplete="off"
              />
              <div class="max-h-60 overflow-y-auto space-y-0.5">
                <label
                  :for={u <- @people}
                  class="flex items-center gap-3 p-2 rounded-[var(--ed-radius)] cursor-pointer"
                  style="--hover: var(--ed-surface-2);"
                >
                  <input type="checkbox" name="member_ids[]" value={u.id} class="size-4" />
                  <span class="ed-avatar ed-avatar--sm">{initials(u.display_name)}</span>
                  <span class="flex-1 min-w-0">
                    <span class="block" style="font-weight:550; font-size:0.875rem;">
                      {u.display_name}
                    </span>
                    <span class="block" style="color: var(--ed-muted); font-size:0.75rem;">
                      @{u.username}
                    </span>
                  </span>
                </label>
              </div>
              <button class="ed-btn ed-btn--primary w-full" type="submit">{gettext("Start")}</button>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
