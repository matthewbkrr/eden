defmodule EdenWeb.SettingsTotpTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts
  alias Eden.Repo

  defp enroll(user) do
    {secret, _uri} = Accounts.setup_totp(user)

    {:ok, user, _codes} =
      Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

    # #263: activation now burns the confirmation code (stamps totp_last_used_at). Clear it
    # so a follow-up step in the same 30s test window can verify with the current code — in
    # real use the next action lands in a later window.
    user = user |> Ecto.Changeset.change(totp_last_used_at: nil) |> Repo.update!()
    {user, secret}
  end

  defp promote(user, role), do: user |> Ecto.Changeset.change(role: role) |> Repo.update!()

  describe "as a member" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture(%{password: "password123"}))}
    end

    test "enroll: set up, confirm a code, and see one-time backup codes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      html = lv |> element("button", "Set up two-factor") |> render_click()
      assert html =~ "authenticator app"

      # Pull the manual key out of the rendered setup and derive the live code.
      key = Regex.run(~r/<code[^>]*>\s*([A-Z2-7]+)\s*<\/code>/, html) |> List.last()
      secret = Base.decode32!(key, padding: false)

      html =
        lv
        |> form("form[phx-submit=totp_activate]",
          totp: %{code: NimbleTOTP.verification_code(secret)}
        )
        |> render_submit()

      assert html =~ "backup codes"
    end

    test "a wrong confirmation code shows an error and doesn't enroll", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/settings/account")
      lv |> element("button", "Set up two-factor") |> render_click()

      html =
        lv
        |> form("form[phx-submit=totp_activate]", totp: %{code: "000000"})
        |> render_submit()

      assert html =~ "didn&#39;t match" or html =~ "didn't match"
    end

    test "an enrolled member can turn it off with a valid code", %{conn: conn} do
      {user, secret} = enroll(user_fixture(%{username: "offme", password: "password123"}))
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/settings/account")
      assert html =~ "On"

      html =
        lv
        |> form("form[phx-submit=totp_disable]",
          totp: %{code: NimbleTOTP.verification_code(secret)}
        )
        |> render_submit()

      refute html =~ "phx-submit=\"totp_disable\""
      refute Accounts.totp_enrolled?(Accounts.get_user!(user.id))
    end
  end

  test "an enrolled admin sees it's required and gets no disable form", %{conn: conn} do
    admin = promote(user_fixture(%{username: "mfaadmin", password: "password123"}), "admin")
    {admin, _secret} = enroll(admin)

    {:ok, _lv, html} = live(log_in_user(conn, admin), ~p"/settings/account")

    assert html =~ "Required for your admin role"
    refute html =~ "phx-submit=\"totp_disable\""
  end
end
