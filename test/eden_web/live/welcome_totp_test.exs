defmodule EdenWeb.WelcomeTotpLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts

  describe "/welcome/two-factor (#306)" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "renders the entry state with set-up and skip options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome/two-factor")
      assert html =~ "Secure your account"
      assert html =~ "Set up two-factor"
      assert html =~ "Skip for now"
    end

    test "the QR/manual key is minted only on the explicit set-up click (#306 review)", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/welcome/two-factor")
      # Not generated up front — so a reconnect can't swap the secret mid-scan.
      refute html =~ "enter this key manually"

      html = view |> element(~s(button[phx-click="start_setup"])) |> render_click()
      assert html =~ "enter this key manually"
    end

    test "skip lands in the app", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome/two-factor")
      view |> element(~s(button[phx-click="skip"])) |> render_click()
      assert_redirect(view, ~p"/app")
    end

    test "skip honors a local return_to", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome/two-factor?return_to=%2Fchannels%2F7")
      view |> element(~s(button[phx-click="skip"])) |> render_click()
      assert_redirect(view, "/channels/7")
    end

    test "ignores a non-local return_to (open-redirect guard)", %{conn: conn} do
      {:ok, view, _} =
        live(conn, ~p"/welcome/two-factor?return_to=https%3A%2F%2Fevil.example%2Fx")

      view |> element(~s(button[phx-click="skip"])) |> render_click()
      assert_redirect(view, ~p"/app")
    end

    test "ignores a backslash protocol-relative bypass (#306 review)", %{conn: conn} do
      # "/\evil.example" — a browser normalises the backslash to "//evil.example".
      {:ok, view, _} = live(conn, ~p"/welcome/two-factor?return_to=%2F%5Cevil.example")
      view |> element(~s(button[phx-click="skip"])) |> render_click()
      assert_redirect(view, ~p"/app")
    end

    test "activating with a valid code enrolls two-factor and reveals backup codes", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome/two-factor")
      html = view |> element(~s(button[phx-click="start_setup"])) |> render_click()

      # Derive the live code from the manual key shown in the setup.
      key = Regex.run(~r/<code[^>]*>\s*([A-Z2-7]+)\s*<\/code>/, html) |> List.last()
      secret = Base.decode32!(key, padding: false)

      html =
        view
        |> form("form[phx-submit=activate]", totp: %{code: NimbleTOTP.verification_code(secret)})
        |> render_submit()

      assert html =~ "backup codes"
    end

    test "a wrong code shows an error and doesn't enroll", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome/two-factor")
      view |> element(~s(button[phx-click="start_setup"])) |> render_click()

      html =
        view
        |> form("form[phx-submit=activate]", totp: %{code: "000000"})
        |> render_submit()

      assert html =~ "didn&#39;t match" or html =~ "didn't match"
    end
  end

  test "an already-enrolled user is sent straight through", %{conn: conn} do
    user = user_fixture()
    {secret, _} = Accounts.setup_totp(user)
    {:ok, user, _} = Accounts.activate_totp(user, secret, NimbleTOTP.verification_code(secret))

    assert {:error, {:live_redirect, %{to: "/app"}}} =
             live(log_in_user(conn, user), ~p"/welcome/two-factor")
  end
end
