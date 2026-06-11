defmodule Uno.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UnoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:uno, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Uno.PubSub},
      # Кто из игроков сейчас подключён (нужен запущенный PubSub).
      UnoWeb.Presence,
      # Адресация партий по room_code и по процессу на партию.
      {Registry, keys: :unique, name: Uno.Game.Registry},
      {DynamicSupervisor, name: Uno.Game.Supervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      UnoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Uno.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UnoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
