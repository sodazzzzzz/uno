defmodule Uno.Game.Manager do
  @moduledoc """
  Фасад жизненного цикла партий поверх `DynamicSupervisor` + `Registry`.

  Это **обычный модуль**, не процесс: тонкая обёртка над запуском/поиском/
  остановкой процессов партий (`Uno.Game.Server`) и удобные делегаты к ним.
  Игровой логики здесь нет — она в `Uno.Game.Rules`, состояние — в
  `Uno.Game.Server`.
  """

  alias Uno.Game.Server

  @doc """
  Создаёт партию с кодом `room_code` (опц. `:players`).

  Возвращает `{:ok, pid}` либо `{:error, :already_exists}`, если партия с таким
  кодом уже запущена.
  """
  @spec create(String.t(), keyword) :: {:ok, pid} | {:error, :already_exists}
  def create(room_code, opts \\ []) do
    spec = {Server, Keyword.put(opts, :room_code, room_code)}

    case DynamicSupervisor.start_child(Uno.Game.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
    end
  end

  @doc "Находит процесс партии по `room_code`."
  @spec find(String.t()) :: {:ok, pid} | :error
  def find(room_code) do
    case Registry.lookup(Uno.Game.Registry, room_code) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Добавляет игрока в лобби партии (см. `Server.add_player/2`)."
  @spec join(String.t(), Server.player()) ::
          {:ok, Uno.Game.State.t()} | {:error, :game_started | :full | :already_joined}
  def join(room_code, player), do: Server.add_player(room_code, player)

  @doc "Проекция состояния партии для игрока."
  @spec project(String.t(), Uno.Game.State.player_id()) :: Uno.Game.Rules.projection()
  def project(room_code, player_id), do: Server.project(room_code, player_id)

  @doc "Останавливает процесс партии (и снимает регистрацию `room_code`)."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(room_code) do
    case find(room_code) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(Uno.Game.Supervisor, pid)
      :error -> {:error, :not_found}
    end
  end
end
