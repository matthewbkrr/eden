defmodule EdenWeb.SettingsLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts

  test "renders in English when the locale is en", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "en"})
    {:ok, _view, html} = live(conn, ~p"/settings/language")

    assert html =~ "Settings"
    assert html =~ "Appearance"
    assert html =~ "Interface language"
    # language option labels are shown in their own language, untranslated
    assert html =~ "English"
    assert html =~ "Русский"
  end

  test "renders in Russian when the locale is ru", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})
    {:ok, _view, html} = live(conn, ~p"/settings/language")

    assert html =~ "Настройки"
    assert html =~ "Внешний вид"
    assert html =~ "Язык интерфейса"
  end

  test "account events are a no-op when signed out, not a crash (#259)", %{conn: conn} do
    # /settings is reachable signed-out (device prefs), but an account event pushed by a
    # crafted client must no-op — not dereference the nil scope and kill the process.
    {:ok, view, _html} = live(conn, ~p"/settings")

    for event <- ~w(logout_everywhere set_notify_sound remove_avatar totp_setup) do
      assert render_click(view, event, %{})
    end

    assert render_click(view, "change_password", %{
             "password" => %{"current" => "x", "new" => "y"}
           })

    assert Process.alive?(view.pid)
  end

  describe "section navigation (#282)" do
    test "signed-out visitors see only the device-pref sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Appearance"
      assert html =~ "Language"
      refute html =~ "Chat folders"
      refute html =~ "Notifications"
    end

    test "the menu lists every account section for a signed-in user", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _view, html} = live(conn, ~p"/settings")

      for label <- [
            "Profile",
            "Account",
            "Notifications",
            "Appearance",
            "Language",
            "Reactions",
            "Chat folders"
          ] do
        assert html =~ label
      end
    end

    test "the admin-panel link shows only for platform admins", %{conn: _conn} do
      {:ok, _v, plain} = live(log_in_user(build_conn(), user_fixture()), ~p"/settings")
      refute plain =~ "Admin panel"

      # role is admin-managed (#174), set directly; the Settings link needs only
      # the role, not the TOTP factor that entering /admin requires.
      admin = user_fixture() |> Ecto.Changeset.change(role: "admin") |> Eden.Repo.update!()
      {:ok, _v, html} = live(log_in_user(build_conn(), admin), ~p"/settings")
      assert html =~ "Admin panel"
    end

    test "a section deep-link renders that pane and marks it current", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/settings/reactions")

      assert has_element?(view, ~s(a[aria-current="page"]), "Reactions")
      assert has_element?(view, ".ed-qr-grid")
    end

    test "patch-navigating between sections swaps the pane without a remount", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(view, "#profile-form")

      html = view |> element(~s(a[href="/settings/folders"])) |> render_click()

      assert html =~ "All Chats"
      refute has_element?(view, "#profile-form")
    end

    test "an unknown section falls back to the default pane, highlight and title agreeing", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/settings/nope")

      # The fallback pane, its menu highlight and the page title all resolve to
      # the same section (profile), so nothing diverges. (The connected view also
      # push_patches the URL to /settings/profile — a runtime-only nicety.)
      assert has_element?(view, "#profile-form")
      assert has_element?(view, ~s(a[aria-current="page"]), "Profile")
      assert page_title(view) =~ "Profile"
    end
  end

  describe "profile section" do
    test "is hidden for signed-out visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ "id=\"profile-form\""
    end

    test "the bio character counter reflects the current length and updates live", %{conn: conn} do
      {:ok, user} = Accounts.update_profile(user_fixture(), %{display_name: "Ada", bio: "Hi"})
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/settings/profile")

      assert html =~ "2/500"

      html =
        view
        |> element("#profile-form")
        |> render_change(user: %{display_name: "Ada", bio: "Hello there"})

      assert html =~ "11/500"
    end

    test "shows the signed-in user's current name and bio", %{conn: conn} do
      user = user_fixture(%{display_name: "Ada"})

      {:ok, user} =
        Accounts.update_profile(user, %{display_name: "Ada", bio: "Counts on machines."})

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

  describe "account & security sections (#284)" do
    test "account holds identity; security is its own menu section with password + 2FA", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture())

      # Account: identity controls (username + status), no security cards.
      {:ok, account, ahtml} = live(conn, ~p"/settings/account")
      assert has_element?(account, "#username-form")
      assert ahtml =~ "Your status"
      refute has_element?(account, "#password-form")
      # "Security" appears as a left-menu item (link), not a card here.
      assert has_element?(account, ~s(a[href="/settings/security"]), "Security")

      # Security: its own pane with password + two-factor.
      {:ok, security, shtml} = live(conn, ~p"/settings/security")
      assert has_element?(security, "#password-form")
      assert shtml =~ "Two-factor authentication"
      assert has_element?(security, ~s(a[aria-current="page"]), "Security")
    end
  end

  describe "chat folders section" do
    alias Eden.Accounts.Scope
    alias Eden.Chat

    test "is hidden for signed-out visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ "Chat folders"
    end

    test "shows an empty-state nudge until the first folder exists", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/settings/folders")

      assert html =~ "No folders yet"

      html =
        view |> form("form[phx-submit=create_folder]", %{"name" => "Work"}) |> render_submit()

      refute html =~ "No folders yet"
    end

    test "create, rename, delete, and reorder", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/folders")

      # create
      view |> form("form[phx-submit=create_folder]", %{"name" => "Work"}) |> render_submit()
      view |> form("form[phx-submit=create_folder]", %{"name" => "Family"}) |> render_submit()
      assert ["Work", "Family"] == Enum.map(Chat.list_folders(scope), & &1.name)

      [work, family] = Chat.list_folders(scope)

      # rename (the per-row form carries the folder id)
      view
      |> element("#rename-folder-#{work.id}")
      |> render_submit(%{"folder_id" => to_string(work.id), "name" => "Job"})

      assert "Job" == hd(Chat.list_folders(scope)).name

      # reorder via the hook's pushed event — "All Chats" is part of the list
      # (movable, not deletable) and its position persists
      render_hook(view, "reorder_folders", %{
        "ids" => [to_string(family.id), "all", to_string(work.id)]
      })

      assert ["Family", "Job"] == Enum.map(Chat.list_folders(scope), & &1.name)
      assert 1 == Chat.all_chats_position(scope)

      # delete
      view
      |> element("button[phx-click=delete_folder][phx-value-id=\"#{work.id}\"]")
      |> render_click()

      assert ["Family"] == Enum.map(Chat.list_folders(scope), & &1.name)
    end

    test "renames save on blur (clicking away), with confirmation", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/folders")

      view |> form("form[phx-submit=create_folder]", %{"name" => "Work"}) |> render_submit()
      [folder] = Chat.list_folders(scope)

      # Blur carries the input value (no Enter needed).
      html =
        view
        |> element("#folder-name-#{folder.id}")
        |> render_blur(%{"folder_id" => to_string(folder.id), "value" => "Job"})

      assert html =~ "Folder renamed."
      assert [%{name: "Job"}] = Chat.list_folders(scope)

      # A blur with the unchanged name is a no-op (no new flash, no write).
      render_click(view, "lv:clear-flash", %{"key" => "info"})

      html =
        view
        |> element("#folder-name-#{folder.id}")
        |> render_blur(%{"folder_id" => to_string(folder.id), "value" => "Job"})

      refute html =~ "Folder renamed."
    end

    test "a blank rename shows a blank-name error, not a length error", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/folders")

      view |> form("form[phx-submit=create_folder]", %{"name" => "Work"}) |> render_submit()
      [folder] = Chat.list_folders(scope)

      html =
        view
        |> element("#rename-folder-#{folder.id}")
        |> render_submit(%{"folder_id" => to_string(folder.id), "name" => "   "})

      assert html =~ "blank"
      refute html =~ "too long"
      # The saved name is untouched.
      assert [%{name: "Work"}] = Chat.list_folders(scope)
    end
  end

  describe "reactions section (#67)" do
    alias Eden.Accounts.Scope
    alias Eden.Chat

    test "is hidden for signed-out visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ "quick-react row"
    end

    test "toggling an emoji adds then removes it from the personal quick row", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/reactions")

      refute "🔥" in Chat.quick_reactions(scope)

      view
      |> element(~s(.ed-qr[phx-click="toggle_quick_reaction"][phx-value-emoji="🔥"]))
      |> render_click()

      assert "🔥" in Chat.quick_reactions(scope)

      assert has_element?(
               view,
               ~s(.ed-qr--on[phx-click="toggle_quick_reaction"][phx-value-emoji="🔥"])
             )

      # Toggling again removes it.
      view
      |> element(~s(.ed-qr[phx-click="toggle_quick_reaction"][phx-value-emoji="🔥"]))
      |> render_click()

      refute "🔥" in Chat.quick_reactions(scope)
    end

    test "picking a double-click reaction persists and highlights it (#106)", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/reactions")

      # Defaults to the first quick reaction.
      assert Chat.dbl_click_reaction(scope) == hd(Chat.default_quick_reactions())

      # Pick ❤️ from the radiogroup (scoped so it's the dbl picker, not the quick toggle).
      view
      |> element(~s([role="radiogroup"] .ed-qr[phx-value-emoji="❤️"]))
      |> render_click()

      assert Chat.dbl_click_reaction(scope) == "❤️"
      assert has_element?(view, ~s([role="radiogroup"] .ed-qr--on[phx-value-emoji="❤️"]))
    end

    test "reset returns the quick row to the default (and the button only shows when custom)", %{
      conn: conn
    } do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/reactions")

      # Default state: nothing to reset.
      refute has_element?(view, ~s(button[phx-click="reset_quick_reactions"]))

      view
      |> element(~s(.ed-qr[phx-click="toggle_quick_reaction"][phx-value-emoji="🔥"]))
      |> render_click()

      assert has_element?(view, ~s(button[phx-click="reset_quick_reactions"]))

      view |> element(~s(button[phx-click="reset_quick_reactions"])) |> render_click()
      assert Chat.quick_reactions(scope) == Chat.default_quick_reactions()
      refute has_element?(view, ~s(button[phx-click="reset_quick_reactions"]))
    end
  end

  describe "notifications section (#214)" do
    alias Eden.Accounts.Scope
    alias Eden.Chat

    test "is hidden for signed-out visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ "Desktop notifications"
    end

    test "sound toggle flips and persists", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      assert Chat.notification_prefs(scope).sound == true
      view |> element(~s(button[phx-click="set_notify_sound"])) |> render_click()
      assert Chat.notification_prefs(scope).sound == false
      assert has_element?(view, ~s(button[phx-click="set_notify_sound"][aria-checked="false"]))
    end

    test "desktop toggle persists the hook's permission result; denied flashes guidance", %{
      conn: conn
    } do
      user = user_fixture()
      scope = Scope.for_user(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      # The .NotifyPerm hook pushes the browser-permission result.
      render_hook(view, "set_notify_desktop", %{"on" => true, "perm" => "granted"})
      assert Chat.notification_prefs(scope).desktop == true

      html = render_hook(view, "set_notify_desktop", %{"on" => false, "perm" => "denied"})
      assert Chat.notification_prefs(scope).desktop == false
      assert html =~ "Allow notifications"
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

  describe "password (#232)" do
    setup %{conn: conn} do
      user = user_fixture(%{password: "password123"})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "a wrong current password shows an error and stays put", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/settings/security")

      html =
        view
        |> form("#password-form", password: %{current: "wrong-one", new: "newpass12345"})
        |> render_submit()

      assert html =~ "Current password is incorrect"
    end

    test "the right current password sets a new one and redirects to sign in", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _} = live(conn, ~p"/settings/security")

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               view
               |> form("#password-form", password: %{current: "password123", new: "newpass12345"})
               |> render_submit()

      assert %Eden.Accounts.User{} =
               Accounts.get_user_by_username_and_password(user.username, "newpass12345")
    end
  end

  describe "session revocation boots live sockets (#256)" do
    setup %{conn: conn} do
      user = user_fixture(%{password: "password123"})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "an already-open LiveView is redirected to sign in when sessions are revoked", %{
      conn: conn,
      user: user
    } do
      # This connected view stands in for another device / tab. Nothing touches it —
      # the revoke happens elsewhere (log out everywhere / password change / reset).
      {:ok, view, _} = live(conn, ~p"/settings")

      :ok = Accounts.revoke_all_user_sessions(user)

      assert_redirect(view, ~p"/login")
    end

    test "a signed-out (unauthenticated) live view is unaffected by another user's revoke", %{
      user: user
    } do
      # A different user's connected view must not be booted.
      other = user_fixture(%{username: "bystander256"})
      {:ok, view, _} = live(log_in_user(build_conn(), other), ~p"/settings")

      :ok = Accounts.revoke_all_user_sessions(user)

      # No redirect for the bystander — still rendering.
      assert render(view) =~ "Settings" or render(view) =~ "Profile"
    end
  end
end
