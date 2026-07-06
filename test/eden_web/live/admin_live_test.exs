defmodule EdenWeb.AdminLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts
  alias Eden.Accounts.User
  alias Eden.Repo

  # role isn't cast by registration (it's admin-managed, #174); set it directly.
  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()

  # Enroll TOTP — admins must have a second factor to reach /admin (#250).
  defp enroll_totp(user) do
    {secret, _uri} = Accounts.setup_totp(user)

    {:ok, user, _codes} =
      Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

    user
  end

  # An admin/super_admin that can actually enter the panel (role + enrolled factor).
  defp admin(attrs \\ %{}), do: user_fixture(attrs) |> promote("admin") |> enroll_totp()
  defp super_admin(attrs), do: user_fixture(attrs) |> promote("super_admin") |> enroll_totp()

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
      conn = log_in_user(conn, admin())
      assert {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
    end

    test "redirects an admin without two-factor to Settings to enroll (#250)", %{conn: conn} do
      conn = log_in_user(conn, promote(user_fixture(), "admin"))
      assert {:error, {:redirect, %{to: "/settings"}}} = live(conn, ~p"/admin")
    end
  end

  describe "as an admin" do
    setup %{conn: conn} do
      boss = admin(%{username: "boss", display_name: "Boss"})
      %{conn: log_in_user(conn, boss), boss: boss}
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

    test "resets a person's two-factor for lost-device recovery (#250)", %{conn: conn} do
      worker = user_fixture(%{username: "lostdev"})
      {secret, _} = Accounts.setup_totp(worker)

      {:ok, worker, _} =
        Accounts.activate_totp(worker, secret, NimbleTOTP.verification_code(secret))

      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, worker)
      assert html =~ "Reset two-factor"

      view |> element(~s(button[phx-click="reset_totp"])) |> render_click()
      refute Accounts.totp_enrolled?(Accounts.get_user!(worker.id))
    end

    test "shows no reset-two-factor control for a person without it (#250)", %{conn: conn} do
      worker = user_fixture(%{username: "no2fa"})
      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, worker)
      refute html =~ "Reset two-factor"
    end

    test "deactivates then reactivates a person (#251)", %{conn: conn} do
      worker = user_fixture(%{username: "leaver"})
      {:ok, view, _} = live(conn, ~p"/admin")
      select(view, worker)

      html = view |> element(~s(button[phx-click="deactivate"])) |> render_click()
      refute Accounts.active?(Accounts.get_user!(worker.id))
      assert html =~ "Reactivate account"

      html = view |> element(~s(button[phx-click="reactivate"])) |> render_click()
      assert Accounts.active?(Accounts.get_user!(worker.id))
      assert html =~ "Deactivate account"
    end

    test "hides the deactivate control for your own account (#251)", %{conn: conn, boss: boss} do
      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, boss)
      refute html =~ "Deactivate account"
    end

    test "a plain admin gets no deactivate control for a super_admin (#251)", %{conn: conn} do
      sa = promote(user_fixture(%{username: "topdog2"}), "super_admin")
      {:ok, view, _} = live(conn, ~p"/admin")
      html = select(view, sa)
      refute html =~ "Deactivate account"
    end

    test "a person-action event with nobody selected is a safe no-op (#250, #251)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin")
      # Forged/stale events with no selection must not crash the LiveView.
      render_click(view, "reset_totp", %{})
      render_click(view, "reset_link", %{})
      render_click(view, "deactivate", %{})
      render_click(view, "reactivate", %{})
      assert render(view) =~ "Select a person"
    end

    test "mints a registration invite link and lists it (#302)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin")

      html = view |> element(~s(button[phx-click="create_invite"])) |> render_click()

      # The one-time URL is surfaced, and a matching active invite now exists.
      assert html =~ "/invite/"
      assert [invite] = Accounts.list_active_invites()
      assert invite.max_uses == 1
      assert html =~ "1 use left"
    end

    test "revokes an outstanding invite (#302)", %{conn: conn, boss: boss} do
      {:ok, _invite, _token} = Accounts.create_invite(boss)
      {:ok, view, _} = live(conn, ~p"/admin")
      assert render(view) =~ "Revoke"

      view |> element(~s(button[phx-click="revoke_invite"])) |> render_click()

      assert Accounts.list_active_invites() == []
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

    test "a demoted admin's open session is ejected to /settings (#262)", %{
      conn: conn,
      boss: boss
    } do
      {:ok, view, _} = live(conn, ~p"/admin")

      # The acting admin is demoted from another super_admin's session: the {:user_updated}
      # for OUR OWN account, now a plain member, must eject us — :require_admin only gates at
      # mount, so a mid-session demotion wouldn't otherwise remove access until navigation.
      send(view.pid, {:user_updated, %{boss | role: "member"}})

      assert_redirect(view, ~p"/settings")
    end
  end

  describe "as a super_admin" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, super_admin(%{username: "superboss"}))}
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
