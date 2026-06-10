defmodule EdenWeb.SettingsLive do
  @moduledoc """
  Device preferences: appearance (theme) and language. These are stored per
  device (theme in localStorage via the manager in root.html.heex; language in
  the session via `EdenWeb.LocaleController`) and work before sign-in. When
  accounts land (Phase 1), account-scoped settings live alongside this screen.
  """
  use EdenWeb, :live_view

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

    {:ok, socket}
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
                    {gettext("JPEG or PNG, up to 5 MB.")}
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
            class="rounded-[var(--ed-radius-lg)] border p-5"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Appearance")}</h2>
            <p class="mt-0.5 mb-4" style="color: var(--ed-muted); font-size:0.8125rem;">
              {gettext("Choose how eden looks on this device.")}
            </p>
            <div class="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
              <span style="font-size:0.875rem;">{gettext("Theme")}</span>
              <div class="ed-seg" role="group" aria-label={gettext("Theme")}>
                <button
                  class="ed-seg__btn"
                  data-active="system"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="system"
                >
                  <.icon name="hero-computer-desktop-micro" class="size-4 hidden sm:block" />
                  {gettext("System")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="light"
                  phx-click={JS.dispatch("phx:set-theme")}
                  data-phx-theme="light"
                >
                  <.icon name="hero-sun-micro" class="size-4 hidden sm:block" /> {gettext("Light")}
                </button>
                <button
                  class="ed-seg__btn"
                  data-active="dark"
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
                  class="ed-folder-row ed-folder-row--pinned"
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
                  <form
                    id={"rename-folder-#{row.id}"}
                    phx-submit="rename_folder"
                    class="flex-1 min-w-0"
                  >
                    <input type="hidden" name="folder_id" value={row.id} />
                    <input
                      name="name"
                      value={row.name}
                      maxlength={Eden.Chat.Folder.max_name()}
                      class="ed-folder-row__name"
                      aria-label={gettext("Folder name")}
                      draggable="false"
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
                maxlength={Eden.Chat.Folder.max_name()}
                placeholder={gettext("New folder name")}
                class="ed-input flex-1"
              />
              <button type="submit" class="ed-btn ed-btn--primary" disabled={@new_folder == ""}>
                {gettext("Add")}
              </button>
            </form>

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
                  const ids = [...this.el.querySelectorAll("li[draggable=true]")].map((i) => i.dataset.id)
                  this.dragging = null
                  this.pushEvent("reorder_folders", { ids })
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
        {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Folder name is too long."))}
      end
    end
  end

  def handle_event("rename_folder", %{"folder_id" => id, "name" => name}, socket) do
    case Chat.rename_folder(socket.assigns.current_scope, id, name) do
      {:ok, _folder} -> {:noreply, reload_folders(socket)}
      {:error, :not_found} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Folder name is too long."))}
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

  defp reload_folders(socket), do: assign_folders(socket)

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
