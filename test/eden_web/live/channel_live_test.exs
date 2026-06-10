defmodule EdenWeb.ChannelLiveTest do
  use EdenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Eden.Accounts.Scope
  alias Eden.Channels

  defp scope(user), do: Scope.for_user(user)

  defp setup_channel(_context) do
    alice = user_fixture(%{username: "alice", display_name: "Alice"})
    {:ok, channel} = Channels.create_channel(scope(alice), %{"name" => "Engineering"})
    %{alice: alice, channel: channel}
  end

  describe "channel workspace" do
    setup [:setup_channel]

    test "a member sees the channel header and the rail marks it active", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      assert html =~ "Engineering"
      assert html =~ "ed-rail__btn--active"
      assert html =~ "Thematic chats will appear here."
    end

    test "a non-member is redirected home", ctx do
      dave = user_fixture(%{username: "dave"})
      conn = log_in_user(ctx.conn, dave)

      assert {:error, {:live_redirect, %{to: "/app"}}} =
               live(conn, ~p"/channels/#{ctx.channel.id}")
    end

    test "a garbage id is redirected home", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/channels/999999")
    end

    test "owner edits name and about from the menu", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "open_rename", %{})

      view
      |> form("#rename-channel-form", %{"channel" => %{"name" => "Core", "about" => "The team"}})
      |> render_submit()

      html = render(view)
      assert html =~ "Core"
      assert html =~ "The team"
      assert {:ok, %{name: "Core"}} = Channels.get_channel(scope(ctx.alice), ctx.channel.id)
    end

    test "a member sees no admin menu items", ctx do
      bob = user_fixture(%{username: "bob"})
      add_member(ctx.channel.id, bob.id)

      conn = log_in_user(ctx.conn, bob)
      {:ok, _view, html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      refute html =~ "Edit channel"
      refute html =~ "Delete channel"
    end

    test "owner deletes the channel and lands home", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "delete_channel", %{})
      assert_redirect(view, "/app")
      assert {:error, :not_found} = Channels.get_channel(scope(ctx.alice), ctx.channel.id)
    end

    test "a rename in another session updates the header live", ctx do
      bob = user_fixture(%{username: "bob2"})
      add_member(ctx.channel.id, bob.id)

      conn = log_in_user(ctx.conn, bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      {:ok, _} = Channels.update_channel(scope(ctx.alice), ctx.channel.id, %{"name" => "Renamed"})

      html = render(view)
      assert html =~ "Renamed"
      # The viewer's own role is preserved (the broadcast carries the actor's).
      refute html =~ "Delete channel"
    end

    test "a delete in another session navigates the viewer home", ctx do
      bob = user_fixture(%{username: "bob3"})
      add_member(ctx.channel.id, bob.id)

      conn = log_in_user(ctx.conn, bob)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      :ok = Channels.delete_channel(scope(ctx.alice), ctx.channel.id)
      assert_redirect(view, "/app")
    end
  end

  describe "rail + create flow" do
    setup [:setup_channel]

    test "the rail lists channels in the messenger too", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "ed-rail"
      # Channel initials icon linking to the workspace.
      assert html =~ ~s(href="/channels/#{ctx.channel.id}")
      assert html =~ ~r/>\s*E\s*<\/a>/
    end

    test "creating a channel from the rail navigates into it", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      render_click(view, "rail_new_channel", %{})
      assert render(view) =~ "New channel"

      view
      |> form("#new-channel-form", %{"channel" => %{"name" => "Design"}})
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/channels/\d+$}

      assert Enum.any?(Channels.list_channels(scope(ctx.alice)), &(&1.name == "Design"))
    end

    test "a new channel from inside a channel workspace works too", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

      render_click(view, "rail_new_channel", %{})

      view
      |> form("#new-channel-form", %{"channel" => %{"name" => "Ops"}})
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/channels/\d+$}
    end

    test "validation errors render in the modal", ctx do
      conn = log_in_user(ctx.conn, ctx.alice)
      {:ok, view, _html} = live(conn, ~p"/app")

      render_click(view, "rail_new_channel", %{})

      html =
        view
        |> form("#new-channel-form", %{"channel" => %{"name" => "   "}})
        |> render_submit()

      assert html =~ "blank"
    end
  end

  # Direct membership plumbing — the public add-member flow lands with #30.
  defp add_member(channel_id, user_id) do
    %Eden.Channels.Membership{}
    |> Eden.Channels.Membership.changeset(%{
      channel_id: channel_id,
      user_id: user_id,
      role: "member"
    })
    |> Eden.Repo.insert!()
  end
end
