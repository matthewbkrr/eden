defmodule EdenWeb.AdminLive do
  @moduledoc """
  Platform admin panel (#174, RFC Phase 2). Gated to admins by the `:require_admin`
  on_mount hook (checked at mount and on every patch). Lists everyone and lets an
  admin edit a user's **admin-managed** identity fields (corp email / Должность /
  structure via `Accounts.apply_managed_fields/2`); a **super_admin** can also
  change a user's platform role (`Accounts.set_user_role/3`). All authorization is
  enforced in the context — this LiveView is the presentation + the gate.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts
  alias Eden.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    # Identity shows everywhere, so refresh the list when anyone's profile /
    # managed fields / role change (our own saves come back through here too).
    if connected?(socket), do: Accounts.subscribe_user_updates()

    {:ok,
     socket
     |> assign(page_title: gettext("Admin"), users: Accounts.list_users())
     |> assign(selected: nil, managed_form: nil, reset_link: nil)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket), do: {:noreply, select_user(socket, id)}

  def handle_event("deselect", _params, socket),
    do: {:noreply, assign(socket, selected: nil, managed_form: nil, reset_link: nil)}

  # Every action below assumes a selected person. A forged/stale event with nobody
  # selected would pass nil into a context function that expects a %User{} and crash
  # the LiveView — no-op it once here instead.
  def handle_event(event, _params, %{assigns: %{selected: nil}} = socket)
      when event in ~w(reset_link reset_totp validate save set_role),
      do: {:noreply, socket}

  def handle_event("reset_link", _params, socket) do
    case Accounts.create_password_reset(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, raw} ->
        {:noreply, assign(socket, reset_link: url(~p"/reset/#{raw}"))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You can't reset that person's access."))}
    end
  end

  def handle_event("reset_totp", _params, socket) do
    case Accounts.admin_reset_totp(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, updated} ->
        {:noreply,
         socket |> refresh_user(updated) |> put_flash(:info, gettext("Two-factor reset."))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You can't reset that person's access."))}
    end
  end

  def handle_event("validate", %{"user" => params}, socket) do
    form =
      socket.assigns.selected
      |> Accounts.change_managed_fields(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, managed_form: form)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.apply_managed_fields(socket.assigns.selected, params) do
      {:ok, updated} ->
        {:noreply, socket |> refresh_user(updated) |> put_flash(:info, gettext("Saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, managed_form: to_form(changeset))}
    end
  end

  def handle_event("set_role", %{"role" => role}, socket) do
    case Accounts.set_user_role(socket.assigns.current_scope, socket.assigns.selected, role) do
      {:ok, updated} ->
        {:noreply, socket |> refresh_user(updated) |> put_flash(:info, gettext("Role updated."))}

      {:error, :last_super_admin} ->
        {:noreply, put_flash(socket, :error, gettext("Can't remove the last super-admin."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't change the role."))}
    end
  end

  @impl true
  def handle_info({:user_updated, user}, socket), do: {:noreply, refresh_user(socket, user)}

  defp select_user(socket, id) do
    case Enum.find(socket.assigns.users, &(to_string(&1.id) == to_string(id))) do
      nil -> socket
      user -> assign(socket, selected: user, managed_form: managed_form(user), reset_link: nil)
    end
  end

  # Keep the local view consistent after ANY change to a user — our own save /
  # role change, or another admin's arriving via the {:user_updated} broadcast:
  # swap the row in the list, and when it's the open person refresh both the
  # header struct AND the edit form, so an open form never shows (or, on save,
  # writes back) stale values. Refreshing the form does drop the current admin's
  # unsaved edits when the person is changed underneath them — the safe trade
  # (show/save the truth, not clobber a concurrent change).
  defp refresh_user(socket, %User{} = user) do
    users = Enum.map(socket.assigns.users, &if(&1.id == user.id, do: user, else: &1))

    if socket.assigns.selected && socket.assigns.selected.id == user.id do
      assign(socket, users: users, selected: user, managed_form: managed_form(user))
    else
      assign(socket, users: users)
    end
  end

  defp managed_form(user), do: to_form(Accounts.change_managed_fields(user))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen">
      <div class="mx-auto max-w-5xl px-5 sm:px-6 py-10">
        <header class="flex items-center gap-3 mb-8">
          <.link navigate={~p"/app"} class="ed-btn--icon" aria-label={gettext("Back")}>
            <.icon name="hero-arrow-left-mini" class="size-5" />
          </.link>
          <h1 style="font-size:1.375rem; font-weight:650;">{gettext("Admin")}</h1>
          <span class="ml-auto" style="color: var(--ed-muted); font-size:0.8125rem;">
            {ngettext("%{count} person", "%{count} people", length(@users))}
          </span>
        </header>

        <.ed_flash flash={@flash} />

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_380px]">
          <%!-- People --%>
          <section
            class="rounded-[var(--ed-radius-lg)] border overflow-hidden"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
            aria-label={gettext("People")}
          >
            <ul class="divide-y" style="border-color: var(--ed-border);">
              <li :for={u <- @users}>
                <button
                  type="button"
                  phx-click="select"
                  phx-value-id={u.id}
                  aria-pressed={to_string(@selected && @selected.id == u.id)}
                  class={[
                    "w-full flex items-center gap-3 px-4 py-2.5 text-left ed-admin-row",
                    @selected && @selected.id == u.id && "is-selected"
                  ]}
                >
                  <.user_avatar user={u} size="ed-avatar--sm" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-medium" style="font-size:0.9375rem;">
                      {u.display_name}
                    </span>
                    <span class="block truncate" style="color: var(--ed-muted); font-size:0.8125rem;">
                      @{u.username}<span :if={u.position}> · {u.position}</span>
                    </span>
                  </span>
                  <.role_badge role={u.role} />
                </button>
              </li>
            </ul>
          </section>

          <%!-- Detail --%>
          <section
            :if={@selected}
            class="rounded-[var(--ed-radius-lg)] border p-5 self-start"
            style="border-color: var(--ed-border); background: var(--ed-surface);"
          >
            <div class="flex items-center gap-3 mb-4">
              <.user_avatar user={@selected} size="ed-avatar--lg" />
              <div class="min-w-0">
                <div class="font-semibold truncate" style="font-size:1rem;">
                  {@selected.display_name}
                </div>
                <div style="color: var(--ed-muted); font-size:0.8125rem;">@{@selected.username}</div>
              </div>
              <button
                type="button"
                phx-click="deselect"
                class="ed-btn--icon ml-auto lg:hidden"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark-mini" class="size-5" />
              </button>
            </div>

            <.form
              for={@managed_form}
              id="managed-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <p style="color: var(--ed-muted); font-size:0.8125rem;">
                {gettext("Managed fields — the person can't edit these themselves.")}
              </p>
              <.ed_field field={@managed_form[:position]} label={gettext("Position")} />
              <.ed_field field={@managed_form[:corp_email]} label={gettext("Corporate email")} />
              <.ed_field field={@managed_form[:structure]} label={gettext("Structure")} />
              <div class="flex justify-end">
                <button type="submit" class="ed-btn ed-btn--primary">{gettext("Save")}</button>
              </div>
            </.form>

            <%!-- Role — super_admin only (set_user_role also re-checks in the context). --%>
            <div
              :if={Accounts.super_admin?(@current_scope.user)}
              class="mt-5 pt-5 border-t"
              style="border-color: var(--ed-border);"
            >
              <h3 style="font-size:0.8125rem; color: var(--ed-muted);">{gettext("Platform role")}</h3>
              <div class="ed-seg mt-2" role="group" aria-label={gettext("Platform role")}>
                <button
                  :for={role <- ~w(member admin super_admin)}
                  type="button"
                  class={["ed-seg__btn", @selected.role == role && "is-active"]}
                  aria-pressed={to_string(@selected.role == role)}
                  phx-click="set_role"
                  phx-value-role={role}
                >
                  {role_label(role)}
                </button>
              </div>
            </div>

            <%!-- Reset access (#232): mint a one-time link. Hidden when the acting
                  admin may not reset this person (a plain admin ↛ a super_admin). --%>
            <div
              :if={Accounts.can_reset_password?(@current_scope.user, @selected)}
              class="mt-5 pt-5 border-t"
              style="border-color: var(--ed-border);"
            >
              <h3 style="font-size:0.8125rem; color: var(--ed-muted);">{gettext("Reset access")}</h3>
              <p class="mt-1" style="font-size:0.75rem; color: var(--ed-muted);">
                {gettext(
                  "Generate a one-time link (valid 24h) and hand it to the person to set a new password."
                )}
              </p>
              <div :if={is_nil(@reset_link)} class="mt-2">
                <button type="button" phx-click="reset_link" class="ed-btn ed-btn--ghost text-sm">
                  {gettext("Generate reset link")}
                </button>
              </div>
              <div :if={@reset_link} class="mt-2 space-y-1.5">
                <input
                  type="text"
                  value={@reset_link}
                  readonly
                  onclick="this.select()"
                  class="ed-input"
                  style="font-size:0.75rem;"
                  aria-label={gettext("Reset link")}
                />
                <p style="font-size:0.6875rem; color: var(--ed-muted);">
                  {gettext("Copy it now — it won't be shown again.")}
                </p>
              </div>

              <%!-- Reset two-factor (#250): recovery when the person lost their
                    authenticator AND backup codes. Only shown if they have it on. --%>
              <div
                :if={Accounts.totp_enrolled?(@selected)}
                class="mt-3 pt-3 border-t"
                style="border-color: var(--ed-border);"
              >
                <p style="font-size:0.75rem; color: var(--ed-muted);">
                  {gettext("This person has two-factor on. Reset it only if they've lost access.")}
                </p>
                <button
                  type="button"
                  phx-click="reset_totp"
                  data-confirm={gettext("Turn off this person's two-factor authentication?")}
                  class="ed-btn ed-btn--ghost text-sm mt-2"
                >
                  {gettext("Reset two-factor")}
                </button>
              </div>
            </div>
          </section>

          <%!-- Empty detail state (desktop) --%>
          <section
            :if={is_nil(@selected)}
            class="hidden lg:flex rounded-[var(--ed-radius-lg)] border p-8 items-center justify-center text-center self-start"
            style="border-color: var(--ed-border); background: var(--ed-surface); color: var(--ed-muted); font-size:0.875rem;"
          >
            {gettext("Select a person to manage their profile and role.")}
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :size, :string, default: "ed-avatar--sm"

  defp user_avatar(assigns) do
    ~H"""
    <span class={["ed-avatar", @size]} aria-hidden="true">
      <img :if={avatar_src(@user)} src={avatar_src(@user)} alt="" />
      <span :if={is_nil(avatar_src(@user))}>{initials(@user.display_name)}</span>
    </span>
    """
  end

  defp avatar_src(%{avatar_key: key, id: id}) when is_binary(key),
    do: ~p"/users/#{id}/avatar?v=#{:erlang.phash2(key)}"

  defp avatar_src(_user), do: nil

  defp initials(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initials(_), do: "?"

  attr :role, :string, required: true

  defp role_badge(%{role: "member"} = assigns), do: ~H""

  defp role_badge(assigns) do
    ~H"""
    <span
      class="shrink-0 rounded-[var(--ed-radius-full)] px-2 py-0.5"
      style={[
        "font-size:0.6875rem; font-weight:600; ",
        (@role == "super_admin" &&
           "color: var(--ed-on-primary); background: var(--ed-primary);") ||
          "color: var(--ed-warning); background: color-mix(in oklch, var(--ed-warning) 16%, transparent);"
      ]}
    >
      {role_label(@role)}
    </span>
    """
  end

  defp role_label("member"), do: gettext("Member")
  defp role_label("admin"), do: gettext("Admin")
  defp role_label("super_admin"), do: gettext("Super-admin")
end
