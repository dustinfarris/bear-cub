defmodule BearCub.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BearCubWeb.Telemetry,
      BearCub.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:bear_cub, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:bear_cub, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BearCub.PubSub},
      # Start a worker by calling: BearCub.Worker.start_link(arg)
      # {BearCub.Worker, arg},
      # Start to serve requests, typically the last entry
      BearCubWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BearCub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BearCubWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
