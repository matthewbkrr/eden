defmodule EdenWeb.AdminLive do
  @moduledoc """
  Platform admin panel (#174, RFC Phase 2). Gated to admins by the `:require_admin`
  on_mount hook (checked at mount and on every patch). Lists everyone and lets an
  admin edit a user's **admin-managed** identity fields (corp email / Должность /
  structure via `Accounts.apply_managed_fields/3`); a **super_admin** can also
  change a user's platform role (`Accounts.set_user_role/3`). An admin can also mint a
  password-reset link, reset a lost second factor, **deactivate / reactivate** an
  account (#251 — `Accounts.deactivate_user/2`, ends every session and blocks sign-in),
  **mint / revoke registration invites** (#302 — `Accounts.create_invite/2` ·
  `revoke_invite/2`, admin-checked in the context via `%Scope{}`), and **permanently
  delete** an account (#303 — `Accounts.delete_user_permanently/2`, irreversible
  anonymization behind a two-step arm), all under the same authority (a plain admin ↛ a
  super_admin, no acting on yourself; the last super_admin can't be deleted). All
  authorization is enforced in the context — this LiveView is the presentation + gate.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts
  alias Eden.Accounts.{Scope, User}
  alias Eden.Channels
  alias Eden.Chat

  # Re-query the invites list each minute so the countdown labels advance and expired rows
  # drop, without a per-second timer.
  @invite_tick_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Identity shows everywhere, so refresh the list when anyone's profile /
      # managed fields / role change (our own saves come back through here too).
      Accounts.subscribe_user_updates()
      # And when any admin mints / revokes / a link is redeemed (#302 review).
      Accounts.subscribe_invites()
      Process.send_after(self(), :tick_invites, @invite_tick_ms)
    end

    {:ok,
     socket
     |> assign(page_title: gettext("Admin"), users: Accounts.list_users())
     |> assign(selected: nil, managed_form: nil, reset_link: nil, delete_armed: false)
     |> assign(invites: Accounts.list_active_invites(), new_invite_url: nil)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket), do: {:noreply, select_user(socket, id)}

  def handle_event("deselect", _params, socket),
    do:
      {:noreply,
       assign(socket, selected: nil, managed_form: nil, reset_link: nil, delete_armed: false)}

  # Onboarding (#302): mint a single-use, 30-minute registration invite attributed to the
  # acting admin, show its URL once, and refresh the outstanding list. Admin-gated by :require_admin.
  def handle_event("create_invite", _params, socket) do
    case Accounts.create_invite(socket.assigns.current_scope) do
      {:ok, _invite, token} ->
        {:noreply,
         socket
         |> assign(new_invite_url: url(~p"/invite/#{token}"))
         |> assign(invites: Accounts.list_active_invites())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't create an invite link."))}
    end
  end

  def handle_event("dismiss_invite_url", _params, socket),
    do: {:noreply, assign(socket, new_invite_url: nil)}

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.invites, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      invite ->
        # Best-effort: revoking is idempotent and the list refresh reflects the truth
        # either way — don't hard-match the result and risk a MatchError on a stale row
        # (matches this module's no-op-stale-events stance, #302 review).
        _ = Accounts.revoke_invite(socket.assigns.current_scope, invite)
        {:noreply, assign(socket, invites: Accounts.list_active_invites())}
    end
  end

  # Every action below assumes a selected person. A forged/stale event with nobody
  # selected would pass nil into a context function that expects a %User{} and crash
  # the LiveView — no-op it once here instead.
  def handle_event(event, _params, %{assigns: %{selected: nil}} = socket)
      when event in ~w(reset_link reset_totp validate save set_role deactivate reactivate
                       arm_delete disarm_delete delete_account),
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
    case Accounts.apply_managed_fields(
           socket.assigns.current_scope,
           socket.assigns.selected,
           params
         ) do
      {:ok, updated} ->
        {:noreply, socket |> refresh_user(updated) |> put_flash(:info, gettext("Saved."))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit that person."))}

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

  def handle_event("deactivate", _params, socket) do
    case Accounts.deactivate_user(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, updated} ->
        # Also kill the person's live channel/room invite links (#305 review): a private-room
        # token keeps granting access regardless of its creator's state. Cross-context, so the
        # web layer orchestrates it — same seam as the deletion scrub below.
        Channels.revoke_invites_by(updated.id)

        {:noreply,
         socket |> refresh_user(updated) |> put_flash(:info, gettext("Account deactivated."))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You can't deactivate that person."))}
    end
  end

  def handle_event("reactivate", _params, socket) do
    case Accounts.reactivate_user(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, updated} ->
        {:noreply,
         socket |> refresh_user(updated) |> put_flash(:info, gettext("Account reactivated."))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You can't reactivate that person."))}
    end
  end

  # Permanent deletion (#303) is a deliberate two-step: arm reveals the confirm, then
  # `delete_account` runs the irreversible anonymization.
  def handle_event("arm_delete", _params, socket),
    do: {:noreply, assign(socket, delete_armed: true)}

  def handle_event("disarm_delete", _params, socket),
    do: {:noreply, assign(socket, delete_armed: false)}

  # The two-step arm is enforced HERE, not just in the UI (#305 review): only an armed
  # confirm runs the irreversible anonymization. The context still re-checks authority, so
  # this guards against an accidental / stale / forged `delete_account` skipping the confirm.
  def handle_event("delete_account", _params, %{assigns: %{delete_armed: true}} = socket) do
    case Accounts.delete_user_permanently(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, updated} ->
        # The web layer orchestrates the cross-context cleanup (contexts don't reach into
        # each other): scrub the person's name from Chat's denormalized system-message meta
        # and drop their private folders now that the account is anonymized (#305 review), and
        # revoke every channel/room invite they minted (#305 review P2 — else a private-room
        # token from the erased account keeps granting access).
        Chat.scrub_deleted_user_content(updated.id)
        Channels.revoke_invites_by(updated.id)

        # The person is now filtered out of the list; drop them + the open panel.
        {:noreply,
         socket
         |> refresh_user(updated)
         |> put_flash(:info, gettext("Account permanently deleted."))}

      {:error, :last_super_admin} ->
        {:noreply, put_flash(socket, :error, gettext("Can't remove the last super-admin."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You can't delete that person."))}
    end
  end

  # Not armed → a bare/forged event never deletes.
  def handle_event("delete_account", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:user_updated, user}, socket) do
    socket = refresh_user(socket, user)

    if user.id == socket.assigns.current_scope.user.id,
      do: sync_self(socket, user),
      else: {:noreply, socket}
  end

  # Another admin minted/revoked, or a link was redeemed (#302 review): refresh the list.
  def handle_info(:invites_changed, socket),
    do: {:noreply, assign(socket, invites: Accounts.list_active_invites())}

  # Periodic re-query so the countdown labels advance and expired rows drop.
  def handle_info(:tick_invites, socket) do
    Process.send_after(self(), :tick_invites, @invite_tick_ms)
    {:noreply, assign(socket, invites: Accounts.list_active_invites())}
  end

  # Our OWN account changed (#262): keep the in-socket scope fresh so a context re-check sees
  # the current role (not the mount-time one), and eject to /settings if admin was revoked —
  # `:require_admin` only gates at mount, so a mid-session demotion wouldn't otherwise remove
  # access until the next navigation.
  defp sync_self(socket, user) do
    # Rebuild the scope via for_user/1 (its documented constructor — never assemble ad hoc)
    # so any derived authorization state is recomputed, not just `user` swapped in (#292 review).
    socket = assign(socket, current_scope: Scope.for_user(user))

    if Accounts.admin?(user) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Your admin access was removed."))
       |> push_navigate(to: ~p"/settings")}
    end
  end

  defp select_user(socket, id) do
    case Enum.find(socket.assigns.users, &(to_string(&1.id) == to_string(id))) do
      nil ->
        socket

      user ->
        assign(socket,
          selected: user,
          managed_form: managed_form(user),
          reset_link: nil,
          delete_armed: false
        )
    end
  end

  # Keep the local view consistent after ANY change to a user — our own save /
  # role change, or another admin's arriving via the {:user_updated} broadcast:
  # swap the row in the list, and when it's the open person refresh both the
  # header struct AND the edit form, so an open form never shows (or, on save,
  # writes back) stale values. Refreshing the form does drop the current admin's
  # unsaved edits when the person is changed underneath them — the safe trade
  # (show/save the truth, not clobber a concurrent change).
  #
  # A permanently-deleted (anonymized, #303) person is REMOVED from the list instead —
  # deletion is terminal and `list_users/0` excludes them, so keep every admin panel
  # consistent (the acting one and any other, over the broadcast). If the deleted person
  # was open, close the detail panel.
  defp refresh_user(socket, %User{} = user) do
    if Accounts.deleted?(user) do
      users = Enum.reject(socket.assigns.users, &(&1.id == user.id))

      if socket.assigns.selected && socket.assigns.selected.id == user.id do
        assign(socket,
          users: users,
          selected: nil,
          managed_form: nil,
          reset_link: nil,
          delete_armed: false
        )
      else
        assign(socket, users: users)
      end
    else
      users = Enum.map(socket.assigns.users, &if(&1.id == user.id, do: user, else: &1))

      if socket.assigns.selected && socket.assigns.selected.id == user.id do
        # Reset the delete arm when the open person's struct is swapped underneath us (e.g.
        # another admin edits them): the confirm must not silently carry onto a changed
        # target (#305 review). The context re-checks authority anyway, so it's cosmetic.
        assign(socket,
          users: users,
          selected: user,
          managed_form: managed_form(user),
          delete_armed: false
        )
      else
        assign(socket, users: users)
      end
    end
  end

  defp managed_form(user), do: to_form(Accounts.change_managed_fields(user))

  # One-line summary of an outstanding invite for the admin list: who minted it (if
  # known — CLI-bootstrapped invites have no inviter), uses left, and how soon it expires.
  defp invite_summary(invite) do
    left = invite.max_uses - invite.used_count
    uses = ngettext("%{count} use left", "%{count} uses left", left)

    case invite.inviter do
      %{username: username} -> "@#{username} · #{uses} · #{expiry_label(invite.expires_at)}"
      _ -> "#{uses} · #{expiry_label(invite.expires_at)}"
    end
  end

  # Short-lived (30-minute #302) invites read best as a countdown; a longer CLI-minted
  # `--days` link falls back to a date+time (UTC-labelled, since it's the raw stored value).
  # Recomputed each render + on the per-minute tick, so it stays fresh (#302 review).
  defp expiry_label(expires_at) do
    minutes = DateTime.diff(expires_at, DateTime.utc_now(), :minute)

    cond do
      minutes <= 0 -> gettext("expired")
      minutes < 60 -> gettext("expires in ~%{n} min", n: minutes)
      true -> gettext("until %{date} UTC", date: Calendar.strftime(expires_at, "%Y-%m-%d %H:%M"))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen">
      <%!-- New-message chime/banner also fires here (#272), not just in the chat. --%>
      <.notifier :if={@notify_prefs} prefs={@notify_prefs} />
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

        <%!-- Onboarding (#302): mint registration invite links. The only in-app path to
              add a new teammate (invite-gated perimeter, ADR-0002); previously CLI-only. --%>
        <section
          class="rounded-[var(--ed-radius-lg)] border p-5 mb-6"
          style="border-color: var(--ed-border); background: var(--ed-surface);"
          aria-label={gettext("Invite people")}
        >
          <div class="flex items-start gap-4">
            <div class="min-w-0">
              <h2 style="font-size:0.9375rem; font-weight:600;">{gettext("Invite people")}</h2>
              <p class="mt-0.5" style="color: var(--ed-muted); font-size:0.8125rem;">
                {gettext(
                  "Create a single-use link (valid 30 minutes) and send it to a new teammate so they can sign up."
                )}
              </p>
            </div>
            <button
              type="button"
              phx-click="create_invite"
              phx-disable-with={gettext("Creating…")}
              class="ed-btn ed-btn--primary text-sm ml-auto shrink-0 whitespace-nowrap"
            >
              {gettext("New invite link")}
            </button>
          </div>

          <%!-- The just-minted URL, shown once — the raw token is never recoverable after. --%>
          <div :if={@new_invite_url} class="mt-3">
            <div class="flex items-center gap-2">
              <input
                type="text"
                value={@new_invite_url}
                readonly
                onclick="this.select()"
                class="ed-input flex-1"
                style="font-size:0.75rem;"
                aria-label={gettext("Invite link")}
              />
              <button
                type="button"
                phx-click="dismiss_invite_url"
                class="ed-btn ed-btn--ghost text-sm shrink-0"
              >
                {gettext("Done")}
              </button>
            </div>
            <p class="mt-1" style="font-size:0.6875rem; color: var(--ed-muted);">
              {gettext("Copy it now — it won't be shown again.")}
            </p>
          </div>

          <%!-- Outstanding invites, each revocable until redeemed or expired. --%>
          <ul :if={@invites != []} class="mt-4 space-y-0.5">
            <li
              :for={inv <- @invites}
              class="flex items-center gap-3 py-1.5 text-sm"
              style="border-top: 1px solid var(--ed-border);"
            >
              <span class="min-w-0 truncate" style="color: var(--ed-muted); font-size:0.8125rem;">
                {invite_summary(inv)}
              </span>
              <button
                type="button"
                phx-click="revoke_invite"
                phx-value-id={inv.id}
                class="ed-btn ed-btn--ghost text-sm ml-auto shrink-0"
                style="color: var(--ed-danger-strong);"
              >
                {gettext("Revoke")}
              </button>
            </li>
          </ul>
        </section>

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
                    @selected && @selected.id == u.id && "is-selected",
                    !u.active && "opacity-60"
                  ]}
                >
                  <.user_avatar user={u} size="ed-avatar--sm" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-medium" style="font-size:0.9375rem;">
                      {u.display_name}
                    </span>
                    <span class="block truncate" style="color: var(--ed-muted); font-size:0.8125rem;">
                      @{u.username}
                      <span :if={u.position}>· {u.position}</span>
                      <span :if={!u.active} style="color: var(--ed-danger);">
                        · {gettext("Deactivated")}
                      </span>
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

            <%!-- Account status (#251): deactivate / reactivate. Same authority as
                  reset (a plain admin ↛ a super_admin); you can't deactivate yourself. --%>
            <div
              :if={
                Accounts.can_reset_password?(@current_scope.user, @selected) &&
                  @selected.id != @current_scope.user.id
              }
              class="mt-5 pt-5 border-t"
              style="border-color: var(--ed-border);"
            >
              <h3 style="font-size:0.8125rem; color: var(--ed-muted);">
                {gettext("Account status")}
              </h3>
              <div :if={@selected.active} class="mt-2">
                <p style="font-size:0.75rem; color: var(--ed-muted);">
                  {gettext(
                    "Deactivating ends every session at once and blocks sign-in until you reactivate."
                  )}
                </p>
                <button
                  type="button"
                  phx-click="deactivate"
                  data-confirm={
                    gettext("Deactivate this account? Their sessions end now and they can't sign in.")
                  }
                  class="ed-btn ed-btn--ghost text-sm mt-2"
                  style="color: var(--ed-danger);"
                >
                  {gettext("Deactivate account")}
                </button>
              </div>
              <div :if={!@selected.active} class="mt-2">
                <p style="font-size:0.75rem; color: var(--ed-danger);">
                  {gettext("This account is deactivated — the person can't sign in.")}
                </p>
                <button type="button" phx-click="reactivate" class="ed-btn ed-btn--ghost text-sm mt-2">
                  {gettext("Reactivate account")}
                </button>
              </div>
            </div>

            <%!-- Reset access (#232): mint a one-time link. Hidden when the acting
                  admin may not reset this person (a plain admin ↛ a super_admin), or
                  when the account is deactivated (#251 — reactivate first; it's moot). --%>
            <div
              :if={Accounts.can_reset_password?(@current_scope.user, @selected) && @selected.active}
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

            <%!-- Delete account (#303): permanent anonymization — scrubs PII, credentials
                  and avatar, keeps the person's messages shown as "Deleted account".
                  Irreversible, so a deliberate two-step arm guards it beyond the browser
                  confirm. Same authority as reset (a plain admin ↛ a super_admin; not you). --%>
            <div
              :if={
                Accounts.can_reset_password?(@current_scope.user, @selected) &&
                  @selected.id != @current_scope.user.id
              }
              class="mt-5 pt-5 border-t"
              style="border-color: var(--ed-border);"
            >
              <h3 style="font-size:0.8125rem; color: var(--ed-danger-strong);">
                {gettext("Delete account")}
              </h3>
              <p class="mt-1" style="font-size:0.75rem; color: var(--ed-muted);">
                {gettext(
                  "Permanently erases this person's name, avatar and login. Their past messages stay, attributed to a deleted account. This can't be undone."
                )}
              </p>

              <button
                :if={!@delete_armed}
                type="button"
                phx-click="arm_delete"
                class="ed-btn ed-btn--ghost text-sm mt-2"
                style="color: var(--ed-danger-strong);"
              >
                {gettext("Delete account…")}
              </button>

              <div :if={@delete_armed} class="mt-2 flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  phx-click="delete_account"
                  data-confirm={gettext("Permanently delete this account? This can't be undone.")}
                  class="ed-btn ed-btn--danger text-sm"
                >
                  {gettext("Delete permanently")}
                </button>
                <button type="button" phx-click="disarm_delete" class="ed-btn ed-btn--ghost text-sm">
                  {gettext("Cancel")}
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
          "color: var(--ed-warning-strong); background: color-mix(in oklch, var(--ed-warning) 16%, transparent);"
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
