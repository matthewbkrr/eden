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
      # The 2FA challenge is only reachable with a pending marker in the session — the half-way
      # state between a correct password and a session token. Naming it in the test title without
      # requesting it left the busiest signed-out page unverified (#542 review).
      challenge =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:totp_pending_user_id, user_fixture().id)
        |> Plug.Conn.put_session(:totp_pending_at, System.system_time(:second))

      for {c, path} <- [
            {conn, "/login"},
            {conn, "/invite/no-such-token"},
            {challenge, "/login/totp"}
          ] do
        html = c |> get(path) |> html_response(200)

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

  describe "the deferred half of the app bundle (#511)" do
    @deferred_registry "assets/js/hooks/deferred.js"
    @deferred_entry "assets/js/lazy.js"
    @boot_index "assets/js/hooks/index.js"

    defp deferred_names do
      @deferred_registry
      |> File.read!()
      |> then(&Regex.run(~r/export const DEFERRED = \[(.*?)\]/s, &1))
      |> Enum.at(1)
      # `[A-Za-z0-9]`, not `[A-Za-z]`: ThemeSegA11y has a digit in it, and a name-shaped regex that
      # quietly skips one entry would have made this test pass on a list it never fully read.
      |> then(&Regex.scan(~r/"([A-Za-z0-9]+)"/, &1))
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()
    end

    defp bundled_names do
      @deferred_entry
      |> File.read!()
      |> then(&Regex.scan(~r|^import (\w+) from "\./hooks/(\w+)"|m, &1))
      |> Enum.map(fn [_, name, file] ->
        assert name == file, "#{@deferred_entry} imports #{file} under the name #{name}"
        name
      end)
      |> MapSet.new()
    end

    test "the registered placeholders and the second bundle name the same hooks" do
      registered = deferred_names()
      bundled = bundled_names()

      assert registered != MapSet.new(), "no DEFERRED names found — the regex stopped matching"

      # Each half fails in its own silent way: a name registered but not bundled leaves a
      # placeholder that never hands over (the feature is simply dead), while a hook bundled but
      # not registered is a `phx-hook` LiveView has never heard of.
      assert MapSet.difference(registered, bundled) |> Enum.to_list() == [],
             "registered as deferred but missing from #{@deferred_entry} — those hooks would never load"

      assert MapSet.difference(bundled, registered) |> Enum.to_list() == [],
             "bundled but not registered — LiveView is never told those names exist"
    end

    test "the boot bundle does not import a deferred hook" do
      imported =
        @boot_index
        |> File.read!()
        |> then(&Regex.scan(~r/^import [^"]+ from "\.\/(\w+)"/m, &1))
        |> Enum.map(&Enum.at(&1, 1))
        |> MapSet.new()

      # This is the whole saving. An eager import pulls the hook back into app.js AND leaves it in
      # lazy.js, which is worse than never having split it.
      assert MapSet.intersection(imported, deferred_names()) |> Enum.to_list() == [],
             "the boot index imports a hook that is supposed to arrive in the second bundle"
    end
  end

  describe "how static files are served" do
    test "a client that accepts brotli gets the .br sibling", %{conn: conn} do
      dir = Path.join([File.cwd!(), "priv", "static", "assets", "js"])
      File.mkdir_p!(dir)
      name = "brotli_probe_#{System.unique_integer([:positive])}.js"
      File.write!(Path.join(dir, name), "the plain file")
      # Not actual brotli: Plug.Static serves the sibling as-is, so distinguishable bytes prove
      # WHICH file was chosen, which is the only thing this test is about.
      File.write!(Path.join(dir, name <> ".br"), "the brotli sibling")

      on_exit(fn ->
        File.rm(Path.join(dir, name))
        File.rm(Path.join(dir, name <> ".br"))
      end)

      conn =
        conn
        |> put_req_header("accept-encoding", "br, gzip")
        |> get("/assets/js/#{name}")

      assert get_resp_header(conn, "content-encoding") == ["br"],
             "the endpoint is not offering brotli — the Docker build's .br files would be dead weight"

      assert response(conn, 200) == "the brotli sibling"
    end
  end
end
