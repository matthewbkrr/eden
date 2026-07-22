defmodule EdenWeb.ResetLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts
  alias Eden.Accounts.{Scope, User}

  # create_password_reset/2 is authorized — mint via a super_admin actor.
  defp mint_reset(target) do
    actor = user_fixture() |> Ecto.Changeset.change(role: "super_admin") |> Eden.Repo.update!()
    {:ok, raw} = Accounts.create_password_reset(Scope.for_user(actor), target)
    raw
  end

  test "shows the form for a valid token", %{conn: conn} do
    raw = mint_reset(user_fixture())
    {:ok, _view, html} = live(conn, ~p"/reset/#{raw}")
    assert html =~ "New password"
    assert html =~ "Set new password"
  end

  test "shows the invalid/expired state for a bad token", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/reset/nope")
    assert html =~ "invalid or has expired"
    refute html =~ "Set new password"
  end

  test "redeeming sets the new password and redirects to sign in", %{conn: conn} do
    user = user_fixture(%{username: "resetlv", password: "password123"})
    raw = mint_reset(user)
    {:ok, view, _} = live(conn, ~p"/reset/#{raw}")

    assert {:error, {:live_redirect, %{to: "/login"}}} =
             view
             |> form("form",
               reset: %{password: "brandnewpass1", password_confirmation: "brandnewpass1"}
             )
             |> render_submit()

    assert %User{} = Accounts.get_user_by_username_and_password("resetlv", "brandnewpass1")
  end
end
