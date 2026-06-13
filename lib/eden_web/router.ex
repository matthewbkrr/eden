defmodule EdenWeb.Router do
  use EdenWeb, :router

  import EdenWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug EdenWeb.Locale
    plug :fetch_current_scope_for_user
    plug :put_root_layout, html: {EdenWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Replace the minimal default CSP with a full nonce-based policy (#54).
    plug EdenWeb.CSP
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Guards the controller routes for signed-out flows (the LiveView pages use the
  # matching :redirect_if_authenticated on_mount hook).
  pipeline :redirect_if_authenticated do
    plug :redirect_if_user_is_authenticated
  end

  # Protected controller routes (not LiveView).
  pipeline :require_authenticated do
    plug :require_authenticated_user
  end

  scope "/", EdenWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/locale", LocaleController, :update
    delete "/users/log_out", UserSessionController, :delete

    # Serve uploaded attachments; the controller authorizes by conversation membership.
    scope "/" do
      pipe_through :require_authenticated
      get "/files/:id", FileController, :show
      get "/files/:id/thumb", FileController, :thumb
      get "/users/:id/avatar", AvatarController, :show
      get "/channels/:id/avatar", ChannelAvatarController, :show
      # Channel invite links. Declared before the /channels/:channel_id live
      # route, so "join" is never parsed as a channel id.
      get "/channels/join/:token", ChannelJoinController, :join
    end

    # Authenticated pages.
    live_session :authenticated,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :require_authenticated}] do
      live "/app", ChatLive
      live "/app/c/:id", ChatLive
      # Permalink: open the conversation scrolled to a specific message.
      live "/app/c/:id/m/:message_id", ChatLive
      # Corporate layer: channel workspaces are ChatLive in channel mode — the
      # message pane (composer, attachments, menus, realtime) is shared as-is.
      live "/channels/:channel_id", ChatLive
      live "/channels/:channel_id/r/:id", ChatLive
      live "/channels/:channel_id/r/:id/m/:message_id", ChatLive
    end

    # Device preferences — available signed out (current_scope may be nil).
    live_session :default,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :mount_current_scope}] do
      live "/settings", SettingsLive
    end
  end

  # Signed-out flows: already-authenticated users are bounced to the app, both
  # at the LiveView (on_mount) and the native POST controller routes (plug).
  scope "/", EdenWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    post "/users/log_in", UserSessionController, :create
    post "/invite/:token", InviteController, :create

    live_session :redirect_if_authenticated,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
      live "/invite/:token", InviteLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", EdenWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:eden, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EdenWeb.Telemetry
      live "/ui", EdenWeb.UiLive
    end
  end
end
