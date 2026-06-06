defmodule EdenWeb.InviteLive do
  @moduledoc """
  Invite acceptance: validates the token, shows a registration form with live
  validation, and posts natively to `InviteController` which creates the account
  and signs the person in.
  """
  use EdenWeb, :live_view

  alias Eden.Accounts

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.fetch_valid_invite(token) do
        {:ok, _invite} ->
          form = to_form(Accounts.change_user_registration(), as: "user")
          assign(socket, token: token, valid?: true, form: form, page_title: gettext("Join eden"))

        {:error, reason} ->
          assign(socket,
            token: token,
            valid?: false,
            reason: reason,
            page_title: gettext("Invite")
          )
      end

    {:ok, socket}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      params
      |> Accounts.change_user_registration()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  def render(%{valid?: false} = assigns) do
    ~H"""
    <div class="ed-root min-h-screen grid place-items-center px-5 py-10 text-center">
      <div class="max-w-sm space-y-3">
        <h1 style="font-size:1.375rem; font-weight:650;">{invite_problem_title(@reason)}</h1>
        <p style="color: var(--ed-muted); font-size:0.9375rem;">{invite_problem_text(@reason)}</p>
        <.link navigate={~p"/"} class="ed-btn ed-btn--secondary">{gettext("Go to start")}</.link>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="ed-root min-h-screen grid place-items-center px-5 py-10">
      <div class="w-full max-w-sm">
        <h1 class="mb-1" style="font-size:1.375rem; font-weight:650;">{gettext("Join eden")}</h1>
        <p class="mb-6" style="color: var(--ed-muted); font-size:0.875rem;">
          {gettext("You were invited. Pick a username and password.")}
        </p>

        <.ed_flash flash={@flash} />

        <.form for={@form} action={~p"/invite/#{@token}"} phx-change="validate" class="space-y-4">
          <.ed_field
            field={@form[:username]}
            label={gettext("Username")}
            autocomplete="username"
            required
            autofocus
          />
          <.ed_field field={@form[:display_name]} label={gettext("Display name")} required />
          <.ed_field
            field={@form[:password]}
            label={gettext("Password")}
            type="password"
            autocomplete="new-password"
            required
          />
          <button class="ed-btn ed-btn--primary w-full" type="submit">
            {gettext("Create account")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp invite_problem_title(:expired), do: gettext("Invite expired")
  defp invite_problem_title(:exhausted), do: gettext("Invite already used")
  defp invite_problem_title(:revoked), do: gettext("Invite revoked")
  defp invite_problem_title(_), do: gettext("Invalid invite")

  defp invite_problem_text(:expired),
    do: gettext("This invite link has expired. Ask for a new one.")

  defp invite_problem_text(:exhausted),
    do: gettext("This invite link has been used up. Ask for a new one.")

  defp invite_problem_text(:revoked), do: gettext("This invite link is no longer active.")
  defp invite_problem_text(_), do: gettext("This invite link is invalid.")
end
