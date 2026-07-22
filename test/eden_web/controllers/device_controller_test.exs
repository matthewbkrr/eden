defmodule EdenWeb.DeviceControllerTest do
  use EdenWeb.ConnCase, async: true

  alias Eden.Notifications.Target
  alias Eden.Repo

  describe "POST /devices" do
    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/devices", %{"kind" => "fcm", "token" => "tok-1234567"})
      assert redirected_to(conn) == ~p"/login"
      assert Repo.aggregate(Target, :count) == 0
    end

    test "registers the current user's device", %{conn: conn} do
      user = Eden.AccountsFixtures.user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/devices", %{"kind" => "apns", "token" => "test-apns-device-tok"})

      assert response(conn, 204)

      assert [%Target{kind: "apns", token: "test-apns-device-tok", user_id: uid}] =
               Repo.all(Target)

      assert uid == user.id
    end

    test "re-registration on every app start stays one row", %{conn: conn} do
      user = Eden.AccountsFixtures.user_fixture()
      authed = log_in_user(conn, user)

      assert authed
             |> post(~p"/devices", %{"kind" => "fcm", "token" => "tok-restart"})
             |> response(204)

      assert authed
             |> post(~p"/devices", %{"kind" => "fcm", "token" => "tok-restart"})
             |> response(204)

      assert Repo.aggregate(Target, :count) == 1
    end

    test "an unknown kind is a 422, missing params a 400", %{conn: conn} do
      user = Eden.AccountsFixtures.user_fixture()
      authed = log_in_user(conn, user)

      assert authed
             |> post(~p"/devices", %{"kind" => "smoke-signal", "token" => "tok-1234567"})
             |> response(422)

      assert authed |> post(~p"/devices", %{"kind" => "fcm"}) |> response(400)
      assert Repo.aggregate(Target, :count) == 0
    end
  end
end
