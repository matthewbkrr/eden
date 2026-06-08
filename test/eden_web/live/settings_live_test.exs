defmodule EdenWeb.SettingsLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts

  test "renders in English when the locale is en", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "en"})
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Settings"
    assert html =~ "Appearance"
    assert html =~ "Interface language"
    # language option labels are shown in their own language, untranslated
    assert html =~ "English"
    assert html =~ "Русский"
  end

  test "renders in Russian when the locale is ru", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Настройки"
    assert html =~ "Внешний вид"
    assert html =~ "Язык интерфейса"
  end

  describe "profile section" do
    test "is hidden for signed-out visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ "id=\"profile-form\""
    end

    test "shows the signed-in user's current name and bio", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})
      {:ok, user} = Accounts.update_profile(user, %{display_name: "Ada", bio: "Counts on machines."})
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "id=\"profile-form\""
      assert html =~ "Ada"
      assert html =~ "Counts on machines."
    end

    test "saves an updated display name and bio", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#profile-form", user: %{display_name: "Ada Lovelace", bio: "  Pioneer.  "})
        |> render_submit()

      assert html =~ "Profile saved."

      updated = Accounts.get_user(user.id)
      assert updated.display_name == "Ada Lovelace"
      # bio is trimmed by the changeset
      assert updated.bio == "Pioneer."
    end

    test "rejects a blank display name", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#profile-form", user: %{display_name: "", bio: ""})
        |> render_submit()

      refute html =~ "Profile saved."
      assert Accounts.get_user(user.id).display_name == "Ada"
    end

    test "uploads and stores an avatar", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings")

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{name: "me.png", content: png_bytes(), type: "image/png"}
        ])

      assert render_upload(avatar, "me.png")

      view
      |> form("#profile-form", user: %{display_name: "Ada", bio: ""})
      |> render_submit()

      assert Accounts.get_user(user.id).avatar_key
    end

    test "removes an existing avatar", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})
      {:ok, user} = Accounts.set_avatar(user, png_path())
      assert user.avatar_key

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("button[phx-click=\"remove_avatar\"]") |> render_click()

      refute Accounts.get_user(user.id).avatar_key
    end
  end

  defp png_bytes(w \\ 600, h \\ 600) do
    {:ok, img} = Image.new(w, h, color: [10, 200, 90])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    bytes
  end

  defp png_path do
    path = Path.join(System.tmp_dir!(), "set-#{System.unique_integer([:positive])}.png")
    File.write!(path, png_bytes())
    on_exit(fn -> File.rm(path) end)
    path
  end
end
