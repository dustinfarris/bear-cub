defmodule BearCubWeb.Router do
  use BearCubWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BearCubWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BearCubWeb do
    pipe_through :browser

    live "/", KioskLive
  end

  # Phone-first admin (FR-25), fenced from the kiosk by path prefix alone:
  # no auth — the network (tailnet + LAN) is the trust boundary (FR-26/D5).
  scope "/admin", BearCubWeb.Admin do
    pipe_through :browser

    live "/", TodayLive

    live "/chores", ChoreLive.Index, :index
    live "/chores/new", ChoreLive.Form, :new
    live "/chores/:id/edit", ChoreLive.Form, :edit

    live "/kids", KidLive.Index, :index
    live "/kids/:id/edit", KidLive.Form, :edit
  end

  # Other scopes may use custom stacks.
  # scope "/api", BearCubWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:bear_cub, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BearCubWeb.Telemetry
    end
  end
end
