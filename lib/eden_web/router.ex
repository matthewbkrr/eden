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
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EdenWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/locale", LocaleController, :update

    # Session lifecycle (native form posts; LiveView can't set cookies).
    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
    post "/invite/:token", InviteController, :create

    # Signed-out pages: bounce already-authenticated users to the app.
    live_session :redirect_if_authenticated,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
      live "/invite/:token", InviteLive
    end

    # Authenticated pages.
    live_session :authenticated,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :require_authenticated}] do
      live "/app", AppHomeLive
    end

    # Device preferences — available signed out (current_scope may be nil).
    live_session :default,
      on_mount: [EdenWeb.Locale, {EdenWeb.UserAuth, :mount_current_scope}] do
      live "/settings", SettingsLive
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
