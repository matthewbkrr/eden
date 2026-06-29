defmodule EdenWeb.SettingsLive do
  @moduledoc """
  Settings. Device preferences — appearance (theme, in localStorage via the
  manager in root.html.heex) and language (session via
  `EdenWeb.LocaleController`) — work before sign-in. Signed-in users also get
  the account-scoped sections: profile (display name, bio, avatar) and chat
  folders (create/rename/delete + drag-to-reorder, including the virtual
  "All Chats" position).
  """
  use EdenWeb, :live_view

  import EdenWeb.PresenceHelpers, only: [status_options: 0]

  alias Eden.Accounts
  alias Eden.Accounts.User
  alias Eden.Chat

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Settings"), locale: Gettext.get_locale(), new_folder: "")
      |> assign_profile()
      |> assign_folders()
      |> assign_reactions()

    {:ok, socket}
  end

  # The personal quick-react row (#67) is account-scoped — only when signed in.
  # `quick_set` is the user's current row (or the default); `reaction_set` is the
  # full pool of selectable emoji.
  defp assign_reactions(socket) do
    case socket.assigns[:current_scope] do
      %{user: %User{}} = scope ->
        assign(socket,
          reaction_set: Chat.allowed_reactions(),
          quick_set: Chat.quick_reactions(scope),
          quick_limit: Chat.quick_reaction_limit(),
          default_quick: Chat.default_quick_reactions(),
          dbl_reaction: Chat.dbl_click_reaction(scope)
        )

      _ ->
        assign(socket,
          reaction_set: [],
          quick_set: [],
          quick_limit: 0,
          default_quick: [],
          dbl_reaction: nil
        )
    end
  end

  # Folders are account-scoped, so they only appear when signed in. `folder_rows`
  # is the management list: the user's folders with the virtual :all row inserted
  # at its stored position (movable, not deletable).
  defp assign_folders(socket) do
    case socket.assigns[:current_scope] do
      %{user: %User{}} = scope ->
        folders = Chat.list_folders(scope)

        assign(socket,
          folders: folders,
          folder_rows: List.insert_at(folders, Chat.all_chats_position(scope), :all)
        )

      _ ->
        assign(socket, folders: [], folder_rows: [])
    end
  end

  # Profile editing is account-scoped, so it only appears when signed in (this
  # page also serves device prefs to signed-out visitors).
  defp assign_profile(socket) do
    case socket.assigns[:current_scope] do
      %{user: %User{} = user} ->
        socket
        |> assign(profile_user: user, profile_form: to_form(Accounts.change_profile(user)))
        |> allow_upload(:avatar,
          accept: ~w(.png .jpg .jpeg .gif .webp),
          max_entries: 1,
          max_file_size: 5_000_000
        )

      _ ->
        assign(socket, profile_user: nil, profile_form: nil)
    end
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

        <.ed_flash flash={@flash} />

        <div class="space-y-6">
          <section
            :if={@profile_user}
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Profile")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("This is how other people see you.")}
            </p>

            <.form
              for={@profile_form}
              id="profile-form"
              phx-change="validate_profile"
              phx-submit="save_profile"
              class="space-y-5"
            >
              <div class="flex items-center gap-4">
                <% entry = List.first(@uploads.avatar.entries) %>
                <span class="ed-avatar ed-avatar--lg" aria-hidden="true">
                  <.live_img_preview :if={entry} entry={entry} />
                  <img
                    :if={!entry && avatar_src(@profile_user)}
                    src={avatar_src(@profile_user)}
                    alt=""
                  />
                  <span :if={!entry && !@profile_user.avatar_key}>
                    {initials(@profile_user.display_name)}
                  </span>
                </span>

                <div class="flex flex-col gap-1.5">
                  <div class="flex items-center gap-2">
                    <label class="ed-btn ed-btn--ghost cursor-pointer text-sm">
                      {gettext("Upload photo")}
                      <.live_file_input upload={@uploads.avatar} class="sr-only" />
                    </label>
                    <button
                      :if={@profile_user.avatar_key && Enum.empty?(@uploads.avatar.entries)}
                      type="button"
                      phx-click="remove_avatar"
                      class="ed-btn ed-btn--ghost text-sm"
                      style="color: var(--ed-danger);"
                    >
                      {gettext("Remove")}
                    </button>
                    <button
                      :for={e <- @uploads.avatar.entries}
                      type="button"
                      phx-click="cancel_avatar"
                      phx-value-ref={e.ref}
                      class="ed-btn ed-btn--ghost text-sm"
                    >
                      {gettext("Cancel")}
                    </button>
                  </div>
                  <p
                    :for={err <- upload_errors(@uploads.avatar)}
                    style="color: var(--ed-danger); font-size:0.75rem;"
                  >
                    {avatar_error(err)}
                  </p>
                  <%= for e <- @uploads.avatar.entries do %>
                    <p
                      :for={err <- upload_errors(@uploads.avatar, e)}
                      style="color: var(--ed-danger); font-size:0.75rem;"
                    >
                      {avatar_error(err)}
                    </p>
                  <% end %>
                  <p
                    :if={Enum.empty?(@uploads.avatar.entries)}
                    style="color: var(--ed-muted); font-size:0.75rem;"
                  >
                    {gettext("JPEG, PNG, GIF or WebP, up to 5 MB.")}
                  </p>
                </div>
              </div>

              <.ed_field field={@profile_form[:display_name]} label={gettext("Display name")} />

              <label class="block space-y-1.5">
                <span style="font-size:0.8125rem; color: var(--ed-muted);">
                  {gettext("About you")}
                </span>
                <textarea
                  name={@profile_form[:bio].name}
                  id={@profile_form[:bio].id}
                  rows="3"
                  class="ed-input"
                  maxlength="500"
                  placeholder={gettext("A short bio")}
                >{Phoenix.HTML.Form.normalize_value("textarea", @profile_form[:bio].value)}</textarea>
                <span
                  :for={msg <- Enum.map(@profile_form[:bio].errors, &translate_error/1)}
                  style="color: var(--ed-danger); font-size:0.75rem;"
                >
                  {msg}
                </span>
              </label>

              <div class="flex justify-end">
                <button type="submit" class="ed-btn ed-btn--primary">{gettext("Save")}</button>
              </div>
            </.form>
          </section>

          <section
            :if={@profile_user}
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Status")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Sets the presence dot others see. Invisible appears offline to everyone.")}
            </p>
            <div class="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
              <span style="font-size:0.875rem; white-space: nowrap;">{gettext("Your status")}</span>
              <div class="ed-seg" role="group" aria-label={gettext("Status")}>
                <button
                  :for={{value, _label, short, _color} <- status_options()}
                  class={["ed-seg__btn", @profile_user.presence_status == value && "is-active"]}
                  type="button"
                  aria-pressed={to_string(@profile_user.presence_status == value)}
                  phx-click="set_status"
                  phx-value-status={value}
                >
                  {short}
                </button>
              </div>
            </div>
          </section>

          <section
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Appearance")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Choose how eden looks on this device.")}
            </p>
            <div class="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
              <span style="font-size:0.875rem;">{gettext("Theme")}</span>
              <div
                class="ed-seg"
                role="group"
                aria-label={gettext("Theme")}
                id="theme-seg"
                phx-hook=".ThemeSegA11y"
              >
                <button
                  class="ed-seg__btn"
                  data-active="system"
                  aria-pressed="false"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="system"
                >
                  <.icon name="hero-computer-desktop-micro" class="size-4 hidden sm:block" />
                  {gettext("System")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="light"
                  aria-pressed="false"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="light"
                >
                  <.icon name="hero-sun-micro" class="size-4 hidden sm:block" /> {gettext("Light")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="dark"
                  aria-pressed="false"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="dark"
                >
                  <.icon name="hero-moon-micro" class="size-4 hidden sm:block" /> {gettext("Dark")}
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
            <form
              action={~p"/locale"}
              method="post"
              class="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4"
            >
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="return_to" value={~p"/settings"} />
              <span style="font-size:0.875rem;">{gettext("Interface language")}</span>
              <div class="ed-seg" role="group" aria-label={gettext("Language")}>
                <button
                  class={["ed-seg__btn", @locale == "en" && "is-active"]}
                  aria-pressed={to_string(@locale == "en")}
                  name="locale"
                  value="en"
                  type="submit"
                >
                  English
                </button>
                <button
                  class={["ed-seg__btn", @locale == "ru" && "is-active"]}
                  aria-pressed={to_string(@locale == "ru")}
                  name="locale"
                  value="ru"
                  type="submit"
                >
                  Русский
                </button>
              </div>
            </form>
          </section>

          <section
            :if={@profile_user}
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Reactions")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext(
                "Pick the emoji in your quick-react row — the shortcuts shown first when you react to a message. Tap to add or remove (up to %{count}).",
                count: @quick_limit
              )}
            </p>
            <div class="flex items-center justify-between mb-2">
              <span style="color: var(--ed-muted); font-size:0.75rem; font-variant-numeric: tabular-nums;">
                {gettext("%{n} of %{max}", n: length(@quick_set), max: @quick_limit)}
              </span>
              <button
                :if={@quick_set != @default_quick}
                type="button"
                class="ed-btn ed-btn--ghost ed-btn--sm"
                phx-click="reset_quick_reactions"
              >
                {gettext("Reset to default")}
              </button>
            </div>
            <div class="ed-qr-grid" role="group" aria-label={gettext("Quick reactions")}>
              <button
                :for={e <- @reaction_set}
                type="button"
                class={["ed-qr", e in @quick_set && "ed-qr--on"]}
                phx-click="toggle_quick_reaction"
                phx-value-emoji={e}
                aria-pressed={to_string(e in @quick_set)}
                disabled={e not in @quick_set and length(@quick_set) >= @quick_limit}
              >
                {e}
              </button>
            </div>

            <div class="mt-5 pt-4" style="border-top: 1px solid var(--ed-border);">
              <p style="font-weight:600; font-size:0.8125rem;">
                {gettext("Double-click to react")}
              </p>
              <p class="mt-0.5 mb-3" style="color: var(--ed-muted); font-size:0.8125rem;">
                {gettext(
                  "Double-clicking a message reacts with this emoji. Pick one from your quick-react row."
                )}
              </p>
              <div class="ed-qr-grid" role="radiogroup" aria-label={gettext("Double-click reaction")}>
                <button
                  :for={e <- @quick_set}
                  type="button"
                  class={["ed-qr", e == @dbl_reaction && "ed-qr--on"]}
                  phx-click="set_dbl_reaction"
                  phx-value-emoji={e}
                  role="radio"
                  aria-checked={to_string(e == @dbl_reaction)}
                >
                  {e}
                </button>
              </div>
            </div>
          </section>

          <section
            :if={@profile_user}
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Chat folders")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext(
                "Group your chats. Drag to reorder — \"All Chats\" can be moved but not deleted."
              )}
            </p>

            <ul id="folder-list" phx-hook=".Sortable" class="space-y-1.5">
              <%= for row <- @folder_rows do %>
                <li
                  :if={row == :all}
                  draggable="true"
                  data-id="all"
                  class="ed-folder-row ed-folder-row--virtual"
                >
                  <span class="ed-folder-row__handle ed-folder-row__handle--grab" aria-hidden="true">
                    <.icon name="hero-bars-3-micro" class="size-4" />
                  </span>
                  <span class="flex-1" style="font-weight:550; font-size:0.875rem;">
                    {gettext("All Chats")}
                  </span>
                  <span style="color: var(--ed-muted); font-size:0.75rem;">
                    {gettext("Default")}
                  </span>
                </li>
                <li
                  :if={row != :all}
                  draggable="true"
                  data-id={row.id}
                  class="ed-folder-row"
                >
                  <span class="ed-folder-row__handle ed-folder-row__handle--grab" aria-hidden="true">
                    <.icon name="hero-bars-3-micro" class="size-4" />
                  </span>
                  <%!-- Renames save on Enter AND on blur (clicking away / leaving
                        the page), with a flash confirming the change. Focusing
                        selects the whole name so it's clearly being edited. --%>
                  <form
                    id={"rename-folder-#{row.id}"}
                    phx-submit="rename_folder"
                    class="flex-1 min-w-0"
                  >
                    <input type="hidden" name="folder_id" value={row.id} />
                    <input
                      id={"folder-name-#{row.id}"}
                      name="name"
                      value={row.name}
                      maxlength={Chat.Folder.max_name()}
                      class="ed-folder-row__name"
                      aria-label={gettext("Folder name")}
                      draggable="false"
                      phx-hook=".SelectOnFocus"
                      phx-blur="rename_folder"
                      phx-value-folder_id={row.id}
                    />
                  </form>
                  <button
                    type="button"
                    class="ed-btn--icon"
                    style="color: var(--ed-danger);"
                    phx-click="delete_folder"
                    phx-value-id={row.id}
                    data-confirm={
                      gettext("Delete this folder? Your chats stay; only the grouping is removed.")
                    }
                    aria-label={gettext("Delete folder")}
                  >
                    <.icon name="hero-trash-micro" class="size-4" />
                  </button>
                </li>
              <% end %>
            </ul>

            <form
              phx-submit="create_folder"
              phx-change="new_folder_changed"
              class="mt-3 flex items-center gap-2"
            >
              <input
                name="name"
                value={@new_folder}
                maxlength={Chat.Folder.max_name()}
                placeholder={gettext("New folder name")}
                class="ed-input flex-1"
              />
              <button type="submit" class="ed-btn ed-btn--primary" disabled={@new_folder == ""}>
                {gettext("Add")}
              </button>
            </form>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectOnFocus">
              // Select the whole value on focus, so clicking a folder name makes
              // it obvious the entire name is being edited (Finder-style).
              export default {
                mounted() { this.el.addEventListener("focus", () => this.el.select()) }
              }
            </script>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeSegA11y">
              // Theme is client-driven (data-theme on <html>), so aria-pressed on the
              // theme segments can't be server-rendered — sync it here and on change.
              export default {
                mounted() {
                  this._sync = () => {
                    const cur = document.documentElement.getAttribute("data-theme") || "system"
                    this.el.querySelectorAll("[data-phx-theme]").forEach((b) =>
                      b.setAttribute("aria-pressed", String(b.dataset.phxTheme === cur)))
                  }
                  this._sync()
                  this._obs = new MutationObserver(this._sync)
                  this._obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
                },
                destroyed() { this._obs && this._obs.disconnect() }
              }
            </script>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".Sortable">
              // HTML5 drag-and-drop reorder. Items rearrange live as you drag; on
              // drop we push the new id order to the server. Handlers bind once per
              // node (guarded), so they survive LiveView re-renders.
              export default {
                mounted() { this.bind() },
                updated() { this.bind() },
                bind() {
                  this.el.querySelectorAll("li[draggable=true]").forEach((item) => {
                    if (item._dnd) return
                    item._dnd = true
                    item.addEventListener("dragstart", (e) => {
                      this.dragging = item
                      this.startOrder = this.order().join()
                      item.classList.add("ed-dragging")
                      e.dataTransfer.effectAllowed = "move"
                    })
                    item.addEventListener("dragend", () => {
                      item.classList.remove("ed-dragging")
                      this.commit()
                    })
                  })
                  if (this._listBound) return
                  this._listBound = true
                  this.el.addEventListener("dragover", (e) => {
                    e.preventDefault()
                    if (!this.dragging) return
                    const after = this.afterElement(e.clientY)
                    if (after == null) this.el.appendChild(this.dragging)
                    else this.el.insertBefore(this.dragging, after)
                  })
                },
                afterElement(y) {
                  const items = [...this.el.querySelectorAll("li[draggable=true]:not(.ed-dragging)")]
                  return items.find((item) => {
                    const box = item.getBoundingClientRect()
                    return y < box.top + box.height / 2
                  }) || null
                },
                commit() {
                  this.dragging = null
                  const ids = this.order()
                  // A click on the handle or a cancelled drag isn't a reorder.
                  if (ids.join() !== this.startOrder) this.pushEvent("reorder_folders", { ids })
                },
                order() {
                  return [...this.el.querySelectorAll("li[draggable=true]")].map((i) => i.dataset.id)
                }
              }
            </script>
          </section>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    form =
      socket.assigns.profile_user
      |> Accounts.change_profile(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: form)}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    {user, avatar_error} = consume_avatar(socket)

    case Accounts.update_profile(user, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(profile_user: updated, profile_form: to_form(Accounts.change_profile(updated)))
         |> profile_flash(avatar_error)}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset))}
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    {:ok, user} = Accounts.remove_avatar(socket.assigns.profile_user)
    {:noreply, assign(socket, profile_user: user)}
  end

  # Set the user's presence status (#102). The Accounts broadcast also reaches any
  # open chat tab (per-user presence topic) so its dot/picker update live.
  def handle_event("set_status", %{"status" => status}, socket) do
    case Accounts.set_presence_status(socket.assigns.profile_user, status) do
      {:ok, user} -> {:noreply, assign(socket, profile_user: user)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("cancel_avatar", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("new_folder_changed", %{"name" => name}, socket) do
    {:noreply, assign(socket, new_folder: name)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    if String.trim(name) == "" do
      {:noreply, socket}
    else
      case Chat.create_folder(socket.assigns.current_scope, %{"name" => name}) do
        {:ok, _folder} -> {:noreply, socket |> assign(new_folder: "") |> reload_folders()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, folder_error(reason))}
      end
    end
  end

  # Fired by both the row form's Enter (params carry "name") and the input's
  # blur (params carry "value"), so clicking away also saves.
  def handle_event("rename_folder", %{"folder_id" => id} = params, socket) do
    name = params["name"] || params["value"] || ""

    if unchanged_name?(socket, id, name) do
      {:noreply, socket}
    else
      case Chat.rename_folder(socket.assigns.current_scope, id, name) do
        {:ok, _folder} ->
          {:noreply, socket |> put_flash(:info, gettext("Folder renamed.")) |> reload_folders()}

        {:error, :not_found} ->
          {:noreply, socket}

        {:error, reason} ->
          # Re-render so the row's input falls back to the saved name.
          {:noreply, socket |> put_flash(:error, folder_error(reason)) |> reload_folders()}
      end
    end
  end

  def handle_event("delete_folder", %{"id" => id}, socket) do
    Chat.delete_folder(socket.assigns.current_scope, id)
    {:noreply, reload_folders(socket)}
  end

  def handle_event("reorder_folders", %{"ids" => ids}, socket) do
    Chat.reorder_folders(socket.assigns.current_scope, ids)
    {:noreply, reload_folders(socket)}
  end

  # Toggle one emoji in the personal quick-react row (#67): present → remove,
  # absent → append (kept in pick order). Clearing all reverts to the default set.
  def handle_event("toggle_quick_reaction", %{"emoji" => emoji}, socket) do
    current = socket.assigns.quick_set

    next =
      if emoji in current,
        do: List.delete(current, emoji),
        else: current ++ [emoji]

    {:ok, _saved} = Chat.set_quick_reactions(socket.assigns.current_scope, next)
    # Re-read the whole reactions block: an unset double-click reaction resolves to
    # the FIRST quick reaction, so changing the row can move which chip is active.
    {:noreply, assign_reactions(socket)}
  end

  # Drop the personal quick row back to the default set.
  def handle_event("reset_quick_reactions", _params, socket) do
    {:ok, _saved} = Chat.set_quick_reactions(socket.assigns.current_scope, [])
    {:noreply, assign_reactions(socket)}
  end

  # #106: pick the emoji a double-click reacts with (one of the quick-react row).
  def handle_event("set_dbl_reaction", %{"emoji" => emoji}, socket) do
    {:ok, saved} = Chat.set_dbl_click_reaction(socket.assigns.current_scope, emoji)
    {:noreply, assign(socket, dbl_reaction: saved)}
  end

  defp reload_folders(socket), do: assign_folders(socket)

  # A blur fires on every focus-out; don't rename (or flash) when nothing changed.
  defp unchanged_name?(socket, id, name) do
    case Integer.parse(to_string(id)) do
      {fid, ""} ->
        Enum.any?(socket.assigns.folders, &(&1.id == fid and &1.name == String.trim(name)))

      _ ->
        false
    end
  end

  # Human-readable reason a folder write was rejected, for the flash.
  defp folder_error(:limit),
    do: gettext("You can have up to %{count} folders.", count: Chat.max_folders())

  defp folder_error(%Ecto.Changeset{errors: errors}) do
    case errors[:name] do
      nil -> gettext("Couldn't save that folder.")
      error -> gettext("Folder name") <> ": " <> translate_error(error)
    end
  end

  defp folder_error(_reason), do: gettext("Couldn't save that folder.")

  # Store the pending avatar (if any) inside the consume callback while the temp
  # file exists; return the (possibly updated) user plus any processing error.
  defp consume_avatar(socket) do
    user = socket.assigns.profile_user

    case consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
           {:ok, Accounts.set_avatar(user, path)}
         end) do
      [{:ok, updated}] -> {updated, nil}
      [{:error, reason}] -> {user, reason}
      [] -> {user, nil}
    end
  end

  defp profile_flash(socket, nil), do: put_flash(socket, :info, gettext("Profile saved."))

  defp profile_flash(socket, _error),
    do: put_flash(socket, :error, gettext("Couldn't process that image."))

  defp avatar_src(%{avatar_key: key, id: id}) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_user), do: nil

  defp initials(name), do: name |> String.first() |> String.upcase()

  defp avatar_error(:too_large), do: gettext("Up to 5 MB")
  defp avatar_error(:not_accepted), do: gettext("Images only")
  defp avatar_error(:too_many_files), do: gettext("One photo")
  defp avatar_error(_other), do: gettext("Invalid file")
end
