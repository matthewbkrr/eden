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
    scope = socket.assigns.current_scope

    if connected?(socket) do
      EdenWeb.Presence.track_user(self(), scope.user.id)
      Phoenix.PubSub.subscribe(Eden.PubSub, EdenWeb.Presence.topic())
      Chat.subscribe_user(scope)
    end

    socket =
      socket
      |> assign(
        page_title: gettext("Chats"),
        selected: nil,
        subscribed_id: nil,
        show_new: false,
        show_members: false,
        profile: nil,
        people: [],
        has_more: false,
        oldest_id: nil,
        other_read_at: nil,
        online_ids: EdenWeb.Presence.online_ids(),
        composer: empty_composer()
      )
      |> stream(:conversations, Chat.list_conversations(scope))
      |> stream(:messages, [])
      |> allow_upload(:photo,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: Chat.max_attachment_bytes()
      )

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
    {:noreply, socket |> unsubscribe() |> assign(selected: nil) |> refresh_sidebar()}
  end

  @impl true
  def handle_event("composer_changed", %{"message" => %{"body" => body}}, socket) do
    # Track the value server-side so resetting to "" after send produces a real
    # diff that clears the input.
    {:noreply, assign(socket, composer: to_form(%{"body" => body}, as: "message"))}
  end

  def handle_event("send", %{"message" => %{"body" => body} = msg}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns
    client_id = msg["client_id"]

    cond do
      is_nil(conversation) -> {:noreply, socket}
      socket.assigns.uploads.photo.entries != [] -> send_photo(socket, scope, conversation, body)
      String.trim(body) == "" -> {:noreply, assign(socket, composer: empty_composer())}
      true -> send_text(socket, scope, conversation, body, client_id)
    end
  end

  # Ignore malformed send payloads (e.g. a crafted event) instead of crashing.
  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photo, ref)}
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

  def handle_event("close_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  # Open a co-member's profile. Your own profile is editable in Settings, so
  # route there instead. Authorization (shared conversation) lives in the context.
  def handle_event("show_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    if id == to_string(scope.user.id) do
      {:noreply, push_navigate(socket, to: ~p"/settings")}
    else
      case Chat.get_shared_user(scope, id) do
        {:ok, user} ->
          {:noreply, assign(socket, profile: user, show_members: false)}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Profile unavailable."))}
      end
    end
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, profile: nil)}
  end

  def handle_event("show_members", _params, socket) do
    {:noreply, assign(socket, show_members: true)}
  end

  def handle_event("close_members", _params, socket) do
    {:noreply, assign(socket, show_members: false)}
  end

  # "Send message" from a profile: open (or reuse) a 1:1 with that user. The
  # profile was reached through a shared conversation, so re-checking the share
  # both authorizes and validates the id before creating anything.
  def handle_event("message_user", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, user} <- Chat.get_shared_user(scope, id),
         {:ok, conversation} <- Chat.create_conversation(scope, [user.id]) do
      {:noreply,
       socket
       |> assign(profile: nil, show_members: false)
       |> stream(:conversations, Chat.list_conversations(scope), reset: true)
       |> push_patch(to: ~p"/app/c/#{conversation.id}")}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't start the conversation."))}
    end
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
    # Incoming message in the open conversation counts as read; skip our own
    # (nothing to clear, no write needed).
    if message.sender_id != socket.assigns.current_scope.user.id do
      Chat.mark_read(socket.assigns.current_scope, message.conversation_id)
    end

    {:noreply, stream_insert(socket, :messages, message)}
  end

  # A thumbnail finished generating: swap the full image for it, in place. Guard
  # against a late broadcast arriving after the user switched conversations.
  def handle_info({:thumbnail_ready, message}, socket) do
    selected = socket.assigns.selected

    if selected && selected.id == message.conversation_id do
      {:noreply, stream_insert(socket, :messages, message)}
    else
      {:noreply, socket}
    end
  end

  # The other participant read up to read_at — refresh delivery ticks.
  def handle_info({:read, reader_id, read_at}, socket) do
    %{current_scope: scope, selected: conversation} = socket.assigns

    if conversation && reader_id != scope.user.id do
      {:ok, messages} = Chat.list_messages(scope, conversation.id, limit: @page)

      {:noreply,
       socket |> assign(other_read_at: read_at) |> stream(:messages, messages, reset: true)}
    else
      {:noreply, socket}
    end
  end

  # A conversation the user belongs to changed: move it to the top of the list
  # with refreshed unread/preview, without reloading the whole sidebar.
  def handle_info({:conversation_activity, conversation_id}, socket) do
    case Chat.get_conversation_summary(socket.assigns.current_scope, conversation_id) do
      {:ok, conversation} ->
        {:noreply, stream_insert(socket, :conversations, conversation, at: 0)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, online_ids: EdenWeb.Presence.online_ids())}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root h-screen flex overflow-hidden">
      <%!-- Below the header so it never covers the header buttons; the wrapper
            ignores pointer events so only the toast itself is interactive. --%>
      <div class="fixed top-20 left-1/2 -translate-x-1/2 z-40 w-full max-w-sm px-4 pointer-events-none">
        <.ed_flash flash={@flash} />
      </div>

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
          <.conversation_item
            :for={{dom_id, conversation} <- @streams.conversations}
            id={dom_id}
            conversation={conversation}
            user={@current_scope.user}
            online_ids={@online_ids}
            active={@selected && @selected.id == conversation.id}
          />
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
            <button
              type="button"
              class="flex items-center gap-3 min-w-0 flex-1 text-left -ml-1.5 px-1.5 py-1 rounded-[var(--ed-radius)] transition-colors hover:bg-[var(--ed-surface)]"
              phx-click={if @selected.is_group, do: "show_members", else: "show_profile"}
              phx-value-id={peer_id(@selected, @current_scope.user)}
              aria-label={gettext("View profile")}
            >
              <.avatar
                name={title(@selected, @current_scope.user)}
                src={avatar_src(peer(@selected, @current_scope.user))}
                online={online?(@selected, @current_scope.user, @online_ids)}
                size={:sm}
              />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:0.9375rem;">
                  {title(@selected, @current_scope.user)}
                </div>
                <div
                  :if={not @selected.is_group}
                  style={"font-size:0.6875rem; color: var(#{if online?(@selected, @current_scope.user, @online_ids), do: "--ed-online", else: "--ed-muted"});"}
                >
                  {if online?(@selected, @current_scope.user, @online_ids),
                    do: gettext("online"),
                    else: gettext("offline")}
                </div>
                <div
                  :if={@selected.is_group}
                  style="font-size:0.6875rem; color: var(--ed-muted);"
                >
                  {ngettext("%{count} member", "%{count} members", member_count(@selected))}
                </div>
              </div>
            </button>
          </header>

          <div class="flex-1 overflow-y-auto p-4" id="message-scroll" phx-hook=".ScrollBottom">
            <div :if={@has_more} class="text-center mb-3">
              <button class="ed-btn ed-btn--ghost" phx-click="load_more">
                {gettext("Load older")}
              </button>
            </div>
            <div class="flex flex-col gap-2" id="messages" phx-update="stream">
              <.message_bubble
                :for={{dom_id, message} <- @streams.messages}
                id={dom_id}
                message={message}
                mine={message.sender_id == @current_scope.user.id}
                group={@selected.is_group}
                read={read?(message, @other_read_at)}
              />
            </div>
            <%!-- Optimistic, not-yet-acked sends live here (JS-managed; LiveView leaves it alone). --%>
            <div class="flex flex-col gap-2 mt-2" id="pending-messages" phx-update="ignore"></div>
          </div>

          <.form
            for={@composer}
            id="composer"
            phx-hook=".SendQueue"
            data-conversation-id={@selected.id}
            phx-submit="send"
            phx-change="composer_changed"
            class="flex flex-col gap-2 p-3 border-t shrink-0"
            style="border-color: var(--ed-border);"
          >
            <div
              :for={entry <- @uploads.photo.entries}
              data-upload-preview
              class="flex items-center gap-3"
            >
              <.live_img_preview
                entry={entry}
                class="rounded-[var(--ed-radius)] object-cover"
                style="width:3rem; height:3rem;"
              />
              <span
                class="flex-1 min-w-0 truncate"
                style="font-size:0.8125rem; color: var(--ed-muted);"
              >
                {entry.client_name}
              </span>
              <span
                :for={err <- upload_errors(@uploads.photo, entry)}
                style="font-size:0.75rem; color: var(--ed-danger);"
              >
                {upload_error_text(err)}
              </span>
              <button
                type="button"
                class="ed-btn--icon"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark-mini" class="size-5" />
              </button>
            </div>

            <div class="flex items-center gap-2">
              <label class="ed-btn--icon cursor-pointer" aria-label={gettext("Attach photo")}>
                <.icon name="hero-photo-micro" class="size-5" />
                <.live_file_input upload={@uploads.photo} class="hidden" />
              </label>
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
            </div>
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

      <.new_conversation_modal :if={@show_new} people={@people} />
      <.members_modal
        :if={@show_members && @selected}
        conversation={@selected}
        user={@current_scope.user}
        online_ids={@online_ids}
      />
      <.profile_modal
        :if={@profile}
        user={@profile}
        online={MapSet.member?(@online_ids, @profile.id)}
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() { this.toBottom() },
          beforeUpdate() {
            this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
          },
          updated() { if (this.pinned) this.toBottom() },
          toBottom() { this.el.scrollTop = this.el.scrollHeight }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
        export default {
          mounted() { this.fmt() },
          updated() { this.fmt() },
          fmt() {
            const d = new Date(this.el.getAttribute("datetime"));
            if (!isNaN(d)) this.el.textContent = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SendQueue">
        // Optimistic text sends + an in-memory outbound queue. A send is rendered
        // immediately, queued, and (re)sent over the socket; while the socket is
        // down it waits and flushes on reconnect, so a flaky cross-border link
        // doesn't lose or duplicate messages (the server dedups by client_id).
        // Photo sends fall through to the normal LiveView path (they need a live
        // upload). In-memory only: a full page reload clears the queue.
        export default {
          mounted() {
            this.connected = true
            this.convId = this.el.dataset.conversationId
            this.queue = []
            this.input = this.el.querySelector('input[name="message[body]"]')
            this.pending = document.getElementById("pending-messages")
            this.scroller = document.getElementById("message-scroll")
            this.el.addEventListener("submit", (e) => this.onSubmit(e))
          },
          disconnected() { this.connected = false },
          reconnected() {
            this.connected = true
            // Re-arm anything that was in-flight when the link dropped; the
            // server dedups by client_id, so re-sending can't duplicate.
            for (const item of this.queue) item.sent = false
            this.flush()
          },
          updated() {
            // Switched conversation: drop the old thread's optimistic UI + queue.
            if (this.el.dataset.conversationId !== this.convId) {
              this.convId = this.el.dataset.conversationId
              this.queue = []
              if (this.pending) this.pending.replaceChildren()
            }
          },
          onSubmit(e) {
            // Photos go through the normal phx-submit (they carry an upload).
            if (this.el.querySelector("[data-upload-preview]")) return
            // Take over text sends: stop the event reaching LiveView's delegated
            // phx-submit so the message isn't also sent without a client_id.
            e.preventDefault()
            e.stopPropagation()
            const body = (this.input.value || "").trim()
            if (!body) return
            const clientId = crypto.randomUUID()
            this.input.value = ""
            this.addOptimistic(clientId, body)
            this.queue.push({ clientId, body, sent: false })
            this.flush()
          },
          flush() {
            if (!this.connected) return
            // Items stay queued until acked; only then are they removed. An
            // in-flight item (sent) isn't re-sent until a reconnect re-arms it.
            for (const item of this.queue) {
              if (item.sent) continue
              item.sent = true
              this.pushEvent("send", { message: { body: item.body, client_id: item.clientId } }, (reply) => {
                this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
                if (reply && reply.nack) this.markFailed(item.clientId)
                else this.remove(item.clientId)
              })
            }
          },
          addOptimistic(clientId, body) {
            const row = document.createElement("div")
            row.className = "flex justify-end"
            row.dataset.clientId = clientId
            const bubble = document.createElement("div")
            bubble.className = "ed-bubble ed-bubble--me"
            bubble.style.opacity = "0.55"
            bubble.textContent = body
            row.appendChild(bubble)
            this.pending.appendChild(row)
            if (this.scroller) this.scroller.scrollTop = this.scroller.scrollHeight
          },
          remove(clientId) {
            const node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (node) node.remove()
          },
          markFailed(clientId) {
            const node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
            if (!node) return
            const bubble = node.querySelector(".ed-bubble")
            bubble.style.opacity = "1"
            bubble.style.border = "1px solid var(--ed-danger)"
          },
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Lightbox">
        // In-app image viewer: click a photo to open it full-screen in a single
        // shared overlay (close on backdrop click or Esc). Cmd/Ctrl/Shift/middle
        // click fall through to the normal "open original in a new tab".
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
              e.preventDefault()
              this.openLightbox(this.el.dataset.full)
            })
          },
          openLightbox(src) {
            let box = document.getElementById("ed-lightbox")
            if (!box) {
              box = document.createElement("div")
              box.id = "ed-lightbox"
              box.className = "ed-lightbox"
              const img = document.createElement("img")
              img.alt = ""
              box.appendChild(img)
              const close = () => {
                box.classList.remove("ed-lightbox--open")
                document.body.style.overflow = ""
                document.removeEventListener("keydown", box.__onKey)
              }
              box.__onKey = (e) => { if (e.key === "Escape") close() }
              box.addEventListener("click", close)
              document.body.appendChild(box)
            }
            box.querySelector("img").src = src
            box.classList.add("ed-lightbox--open")
            document.body.style.overflow = "hidden"
            document.addEventListener("keydown", box.__onKey)
          },
        }
      </script>
    </div>
    """
  end

  ## Components

  attr :name, :string, required: true
  attr :src, :string, default: nil
  attr :online, :boolean, default: false
  attr :size, :atom, default: nil, values: [nil, :sm, :lg]

  # Circular avatar: shows the user's image when present, initials otherwise.
  defp avatar(assigns) do
    ~H"""
    <span class={["ed-avatar", @size == :sm && "ed-avatar--sm", @size == :lg && "ed-avatar--lg"]}>
      <img :if={@src} src={@src} alt="" />
      <span :if={!@src}>{initials(@name)}</span>
      <span :if={@online} class="ed-avatar__dot"></span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :conversation, :map, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true
  attr :active, :boolean, default: false

  defp conversation_item(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={~p"/app/c/#{@conversation.id}"}
      class={["ed-convo", @active && "ed-convo--active"]}
    >
      <.avatar
        name={title(@conversation, @user)}
        src={avatar_src(peer(@conversation, @user))}
        online={online?(@conversation, @user, @online_ids)}
      />
      <span class="ed-convo__body">
        <span class="ed-convo__top">
          <span class="ed-convo__name">{title(@conversation, @user)}</span>
          <.local_time
            :if={@conversation.last_message_at}
            at={@conversation.last_message_at}
            class="ed-convo__time"
          />
        </span>
        <span class="ed-convo__top">
          <span class="ed-convo__preview">{convo_preview(@conversation)}</span>
          <span :if={@conversation.unread_count > 0} class="ed-badge">
            {@conversation.unread_count}
          </span>
        </span>
      </span>
    </.link>
    """
  end

  # Sidebar preview line. Photos show "📷 <caption|Photo>" so the row is never
  # blank (keeps item height + the time position consistent).
  defp convo_preview(%{last_message_photo?: true} = conversation) do
    caption = conversation.last_message_body
    "📷 " <> if(is_binary(caption) and caption != "", do: caption, else: gettext("Photo"))
  end

  defp convo_preview(%{last_message_body: body}) when is_binary(body) and body != "", do: body
  defp convo_preview(_conversation), do: gettext("No messages yet")

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :mine, :boolean, required: true
  attr :group, :boolean, required: true
  attr :read, :boolean, required: true

  defp message_bubble(assigns) do
    ~H"""
    <div id={@id} class={["flex", @mine && "justify-end"]}>
      <div class={["ed-bubble", (@mine && "ed-bubble--me") || "ed-bubble--them"]}>
        <span
          :if={@group and not @mine and @message.sender}
          class="block"
          style="font-size:0.75rem; font-weight:600; color: var(--ed-primary);"
        >
          {@message.sender.display_name}
        </span>
        <a
          :if={@message.attachment}
          id={"att-#{@message.attachment.id}"}
          phx-hook=".Lightbox"
          data-full={~p"/files/#{@message.attachment.id}"}
          href={~p"/files/#{@message.attachment.id}"}
          target="_blank"
          rel="noopener"
          class="block mb-1 cursor-zoom-in"
        >
          <img
            src={thumb_src(@message.attachment)}
            width={@message.attachment.width}
            height={@message.attachment.height}
            class="rounded-[0.6rem] block"
            style="max-width:min(20rem,100%); max-height:20rem; width:auto; height:auto;"
            loading="lazy"
            alt={gettext("Photo")}
          />
        </a>
        <span :if={@message.body != ""}>{@message.body}</span>
        <span class="ed-bubble__meta">
          <.local_time at={@message.inserted_at} />
          <span :if={@mine and not @group} class="inline-flex items-center" style="margin-left:2px;">
            <.icon :if={not @read} name="hero-check-micro" class="size-3.5" />
            <span :if={@read} class="inline-flex items-center">
              <.icon name="hero-check-micro" class="size-3.5 -mr-2" />
              <.icon name="hero-check-micro" class="size-3.5" />
            </span>
          </span>
        </span>
      </div>
    </div>
    """
  end

  attr :people, :list, required: true

  defp new_conversation_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_new"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_new"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("New conversation")}</h2>
            <button class="ed-btn--icon" phx-click="close_new" aria-label={gettext("Close")}>
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
                >
                  <input type="checkbox" name="member_ids[]" value={u.id} class="size-4" />
                  <.avatar name={u.display_name} src={avatar_src(u)} size={:sm} />
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

  attr :user, :map, required: true
  attr :online, :boolean, required: true

  # Read-only profile of another participant, reached from the chat header (1:1)
  # or the group member list. Editing your own profile happens in Settings.
  defp profile_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_profile"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-xs rounded-[var(--ed-radius-lg)] border p-6 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_profile"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Profile")}
        >
          <div class="flex justify-end -mt-2 -mr-2">
            <button class="ed-btn--icon" phx-click="close_profile" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <div class="flex flex-col items-center text-center">
            <.avatar
              name={@user.display_name}
              src={avatar_src(@user)}
              online={@online}
              size={:lg}
            />
            <h2 class="mt-3 font-semibold" style="font-size:1.0625rem;">{@user.display_name}</h2>
            <p style="color: var(--ed-muted); font-size:0.8125rem;">@{@user.username}</p>
            <p
              class="mt-0.5"
              style={"font-size:0.75rem; color: var(#{if @online, do: "--ed-online", else: "--ed-muted"});"}
            >
              {if @online, do: gettext("online"), else: gettext("offline")}
            </p>

            <p
              :if={@user.bio}
              class="mt-4 whitespace-pre-line break-words text-left w-full"
              style="font-size:0.875rem; color: var(--ed-ink);"
            >
              {@user.bio}
            </p>
          </div>

          <button
            class="ed-btn ed-btn--primary w-full mt-6"
            phx-click="message_user"
            phx-value-id={@user.id}
          >
            <.icon name="hero-chat-bubble-oval-left-micro" class="size-4" /> {gettext("Send message")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :conversation, :map, required: true
  attr :user, :map, required: true
  attr :online_ids, :any, required: true

  # Group member list: tap a member to open their profile (tapping yourself
  # routes to Settings, handled by show_profile).
  defp members_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-30">
      <button
        class="absolute inset-0 w-full h-full"
        style="background: oklch(0 0 0 / 0.55);"
        phx-click="close_members"
        aria-label={gettext("Close")}
        tabindex="-1"
      >
      </button>
      <div class="absolute inset-0 grid place-items-center p-4 pointer-events-none">
        <div
          class="w-full max-w-sm rounded-[var(--ed-radius-lg)] border p-5 space-y-4 pointer-events-auto"
          style="background: var(--ed-surface); border-color: var(--ed-border);"
          phx-window-keydown="close_members"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
        >
          <div class="flex items-center justify-between">
            <h2 style="font-weight:600;">{gettext("Members")}</h2>
            <button class="ed-btn--icon" phx-click="close_members" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark-mini" class="size-5" />
            </button>
          </div>

          <div class="max-h-72 overflow-y-auto space-y-0.5">
            <button
              :for={m <- @conversation.memberships}
              type="button"
              class="flex w-full items-center gap-3 p-2 rounded-[var(--ed-radius)] text-left transition-colors hover:bg-[var(--ed-bg)]"
              phx-click="show_profile"
              phx-value-id={m.user.id}
            >
              <.avatar
                name={m.user.display_name}
                src={avatar_src(m.user)}
                online={MapSet.member?(@online_ids, m.user.id)}
                size={:sm}
              />
              <span class="flex-1 min-w-0">
                <span class="block truncate" style="font-weight:550; font-size:0.875rem;">
                  {m.user.display_name}{if m.user.id == @user.id, do: " " <> gettext("(you)")}
                </span>
                <span class="block truncate" style="color: var(--ed-muted); font-size:0.75rem;">
                  @{m.user.username}
                </span>
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A timestamp that the browser reformats to the viewer's local time (the
  # server-rendered text is a UTC fallback shown before JS runs).
  attr :at, :any, required: true
  attr :class, :string, default: nil

  defp local_time(assigns) do
    ~H"""
    <time
      class={@class}
      phx-hook=".LocalTime"
      id={"t-#{System.unique_integer([:positive])}"}
      datetime={DateTime.to_iso8601(@at)}
    >
      {Calendar.strftime(@at, "%H:%M")}
    </time>
    """
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
      other_read_at: other_read_at(conversation, scope.user),
      has_more: length(messages) == @page,
      oldest_id: messages |> List.first() |> then(&(&1 && &1.id))
    )
    |> stream(:messages, messages, reset: true)
    # Re-stream the sidebar so the active highlight follows the selection (stream
    # items don't re-render on assign changes) and the opened conversation's
    # unread badge clears.
    |> refresh_sidebar()
  end

  defp refresh_sidebar(socket) do
    stream(socket, :conversations, Chat.list_conversations(socket.assigns.current_scope),
      reset: true
    )
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

  # The single other participant of a 1:1 (nil for groups), used for the avatar.
  defp peer(%{is_group: true}, _user), do: nil
  defp peer(conversation, user), do: conversation |> others(user) |> List.first()

  # The peer's id for the header click target (nil for groups, which open the
  # member list rather than a single profile).
  defp peer_id(conversation, user), do: conversation |> peer(user) |> then(&(&1 && &1.id))

  defp member_count(conversation), do: length(conversation.memberships)

  # Avatar image URL for a user, cache-busted by the avatar key (nil → initials).
  defp avatar_src(%{avatar_key: key, id: id}) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_user), do: nil

  defp initials(name), do: name |> String.first() |> String.upcase()

  # Online state is shown for 1:1s (the other participant); groups don't show a dot.
  defp online?(%{is_group: true}, _user, _online_ids), do: false

  defp online?(conversation, user, online_ids) do
    case others(conversation, user) do
      [other | _] -> MapSet.member?(online_ids, other.id)
      [] -> false
    end
  end

  # Read receipts: the other participant's last_read_at for a 1:1 (nil for groups).
  defp other_read_at(%{is_group: true}, _user), do: nil

  defp other_read_at(conversation, user) do
    conversation.memberships
    |> Enum.find(&(&1.user_id != user.id))
    |> then(&(&1 && &1.last_read_at))
  end

  defp read?(_message, nil), do: false
  defp read?(message, read_at), do: DateTime.compare(message.inserted_at, read_at) != :gt

  defp empty_composer, do: to_form(%{}, as: "message")

  defp send_text(socket, scope, conversation, body, client_id \\ nil) do
    case Chat.create_message(scope, conversation.id, %{"body" => body, "client_id" => client_id}) do
      {:ok, _message} ->
        # The form path clears the input via the composer assign; the hook path
        # (client_id present) already cleared it client-side, so leave the assign
        # alone to avoid clobbering text typed during a slow round-trip.
        socket = if client_id, do: socket, else: assign(socket, composer: empty_composer())
        ack(socket, client_id)

      {:error, _changeset} ->
        socket
        |> put_flash(:error, gettext("Message is too long (up to 4000 characters)."))
        |> nack(client_id)
    end
  end

  # When a send comes from the client SendQueue hook (client_id present), reply so
  # it can clear or flag its optimistic bubble; a plain form submit gets :noreply.
  defp ack(socket, nil), do: {:noreply, socket}
  defp ack(socket, client_id), do: {:reply, %{"ack" => client_id}, socket}
  defp nack(socket, nil), do: {:noreply, socket}
  defp nack(socket, client_id), do: {:reply, %{"nack" => client_id}, socket}

  defp send_photo(socket, scope, conversation, body) do
    # Store + persist inside the consume callback, while the temp file exists.
    results =
      consume_uploaded_entries(socket, :photo, fn %{path: path}, _entry ->
        {:ok, Chat.create_photo_message(scope, conversation.id, %{path: path, body: body})}
      end)

    case results do
      [{:ok, _message}] ->
        {:noreply, assign(socket, composer: empty_composer())}

      [{:error, reason}] ->
        {:noreply, put_flash(socket, :error, photo_error(reason))}

      # No entry was consumed (the file is still uploading or failed client-side
      # validation). Don't drop a caption the user already typed.
      [] ->
        if String.trim(body) == "",
          do: {:noreply, socket},
          else: send_text(socket, scope, conversation, body)
    end
  end

  defp photo_error(:unsupported_type), do: gettext("Only image files are allowed.")
  defp photo_error(:too_large), do: gettext("That image is too large (up to 8 MB).")
  defp photo_error(_other), do: gettext("Couldn't send the photo.")

  # Client-side upload validation errors surfaced by `allow_upload/3`.
  defp upload_error_text(:too_large), do: gettext("Up to 8 MB")
  defp upload_error_text(:not_accepted), do: gettext("Images only")
  defp upload_error_text(:too_many_files), do: gettext("One photo at a time")
  defp upload_error_text(_other), do: gettext("Invalid file")

  # Prefer the lighter thumbnail once it exists; fall back to the original while
  # the worker is still generating it.
  defp thumb_src(%{thumbnail_key: key, id: id}) when is_binary(key), do: ~p"/files/#{id}/thumb"
  defp thumb_src(%{id: id}), do: ~p"/files/#{id}"
end
