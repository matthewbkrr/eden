defmodule EdenWeb.AssetBundlesTest do
  # Which JavaScript a page ships (#511).
  #
  # A signed-out page renders a form; it was loading the whole chat client to do it — 80 KB gzip
  # against 44.5 for the split bundle. The split has two halves that can each rot independently:
  # the router has to mark those pages, and the small bundle has to stay small.
  use EdenWeb.ConnCase, async: true

  import Eden.AccountsFixtures

  describe "which bundle a page loads" do
    test "login, the 2FA challenge and invite acceptance load the auth bundle", %{conn: conn} do
      for path <- ["/login", "/invite/no-such-token"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ "/assets/js/auth.js",
               "#{path} is not loading the signed-out bundle"

        refute html =~ "/assets/js/app.js",
               "#{path} is still shipping the chat client"
      end
    end

    test "an authenticated page loads the full bundle", %{conn: conn} do
      html = conn |> log_in_user(user_fixture()) |> get("/app") |> html_response(200)

      assert html =~ "/assets/js/app.js"
      refute html =~ "/assets/js/auth.js"
    end
  end

  describe "what the auth bundle is allowed to contain" do
    @auth_entry "assets/js/auth.js"

    test "it never imports the colocated hook index" do
      source = File.read!(@auth_entry)

      # This is the whole mechanism. The generated `phoenix-colocated/eden` index statically
      # imports all 42 hooks and exports them as one object, so a single import of it puts the
      # lightbox, the upload queue and the message stream back on the login page — and nothing
      # would look broken, the file would just be twice the size again.
      refute source =~ "phoenix-colocated",
             "the auth bundle imports the colocated hook index — that is the entire chat client"
    end

    test "it imports only what a form page can use" do
      allowed =
        ~w(phoenix_html phoenix phoenix_live_view ../vendor/topbar ./shared_hooks ./msg_cache)

      imported =
        File.read!(@auth_entry)
        |> then(&Regex.scan(~r/^import .*?from "([^"]+)"|^import "([^"]+)"/m, &1))
        |> Enum.map(fn m -> m |> Enum.drop(1) |> Enum.find(&(&1 != "")) end)

      assert imported != [], "no imports found — the regex stopped matching this file"

      assert Enum.all?(imported, &(&1 in allowed)),
             "the auth bundle grew an import: #{inspect(imported -- allowed)}. " <>
               "Anything added here lands on the first screen a person ever sees."
    end
  end
end
