defmodule EdenWeb.AdminLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts.User
  alias Eden.Repo

  # role isn't cast by registration (it's admin-managed, #174); set it directly.
  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()

  defp select(view, user),
    do: element(view, ~s(button[phx-value-id="#{user.id}"])) |> render_click()

  describe "the /admin access gate (#174)" do
    test "redirects a signed-out visitor to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin")
    end

    test "redirects a plain member to the app", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/admin")
    end

    test "lets an admin in", %{conn: conn} do
      conn = log_in_user(conn, promote(user_fixture(), "admin"))
      assert {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
    end
  end

  describe "as an admin" do
    setup %{conn: conn} do
      admin = promote(user_fixture(%{username: "boss", display_name: "Boss"}), "admin")
      %{conn: log_in_user(conn, admin)}
    end

    test "lists everyone and edits a person's managed fields", %{conn: conn} do
      worker = user_fixture(%{username: "worker", display_name: "Worker"})
      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "Worker"

      select(view, worker)

      view
      |> form("#managed-form", user: %{"position" => "Analyst", "corp_email" => "w@rwb.ru"})
      |> render_submit()

      updated = Repo.get!(User, worker.id)
      assert updated.position == "Analyst"
      assert updated.corp_email == "w@rwb.ru"
    end

    test "surfaces a validation error and doesn't write", %{conn: conn} do
      worker = user_fixture(%{username: "worker2"})
      {:ok, view, _} = live(conn, ~p"/admin")
      select(view, worker)

      html = view |> form("#managed-form", user: %{"corp_email" => "nope"}) |> render_submit()
      assert html =~ "valid email"
      assert Repo.get!(User, worker.id).corp_email == nil
    end

    test "does not offer the role selector to a non-super-admin", %{conn: conn} do
      worker = user_fixture(%{username: "worker3"})
      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, worker)
      refute html =~ "Platform role"
    end

    test "generates a one-time reset link for a person (#232)", %{conn: conn} do
      worker = user_fixture(%{username: "worker6"})
      {:ok, view, _} = live(conn, ~p"/admin")
      select(view, worker)

      html = view |> element(~s(button[phx-click="reset_link"])) |> render_click()
      assert html =~ "/reset/"
    end

    test "hides the reset control when a plain admin selects a super_admin (#232)", %{conn: conn} do
      sa = promote(user_fixture(%{username: "topdog"}), "super_admin")
      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, sa)
      refute html =~ "Generate reset link"
    end

    test "an external update to the open person refreshes the list and the edit form", %{
      conn: conn
    } do
      worker = user_fixture(%{username: "worker5", display_name: "Worker Five"})
      {:ok, view, _} = live(conn, ~p"/admin")
      select(view, worker)

      # Another admin / a sync changes this person's managed fields under us.
      send(view.pid, {:user_updated, %{worker | position: "Externally Set"}})

      # The open edit form (not just the list) reflects it — so a later save can't
      # write the stale value back.
      assert render(view) =~ "Externally Set"
    end
  end

  describe "as a super_admin" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, promote(user_fixture(%{username: "superboss"}), "super_admin"))}
    end

    test "can change a person's platform role", %{conn: conn} do
      worker = user_fixture(%{username: "worker4"})
      {:ok, view, _} = live(conn, ~p"/admin")
      select(view, worker)

      view
      |> element(~s(button[phx-click="set_role"][phx-value-role="admin"]))
      |> render_click()

      assert Repo.get!(User, worker.id).role == "admin"
    end
  end
end
