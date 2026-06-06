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

        <.form
          for={@form}
          action={~p"/invite/#{@token}"}
          phx-change="validate"
          class="space-y-4"
        >
          <.field
            field={@form[:username]}
            label={gettext("Username")}
            autocomplete="username"
            autofocus
          />
          <.field field={@form[:display_name]} label={gettext("Display name")} />
          <.field
            field={@form[:password]}
            label={gettext("Password")}
            type="password"
            autocomplete="new-password"
          />
          <button class="ed-btn ed-btn--primary w-full" type="submit">
            {gettext("Create account")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :rest, :global, include: ~w(autocomplete autofocus)

  defp field(assigns) do
    ~H"""
    <label class="block space-y-1.5">
      <span style="font-size:0.8125rem; color: var(--ed-muted);">{@label}</span>
      <input
        class="ed-input"
        type={@type}
        name={@field.name}
        id={@field.id}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        {@rest}
      />
      <span
        :for={msg <- Enum.map(@field.errors, &translate_error/1)}
        style="color: var(--ed-danger); font-size:0.75rem;"
      >
        {msg}
      </span>
    </label>
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
