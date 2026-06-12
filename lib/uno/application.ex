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
      # Снапшоты партий (ETS) — стартует ДО супервизора партий: таблица должна
      # существовать и переживать падения процессов партий (let-it-crash).
      Uno.Game.Stash,
      # Интенсивность выше дефолтной (3/5с): партии рестартуют после падений
      # (restart: :transient + снапшот), и пачка одновременных падений не должна
      # гасить супервизор со ВСЕМИ партиями.
      {DynamicSupervisor,
       name: Uno.Game.Supervisor, strategy: :one_for_one, max_restarts: 20, max_seconds: 5},
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
