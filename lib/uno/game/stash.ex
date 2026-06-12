defmodule Uno.Game.Stash do
  @moduledoc """
  Хранилище снапшотов партий в ETS — точка восстановления для let-it-crash.

  Маленький GenServer, чья единственная работа — **владеть** публичной
  ETS-таблицей: владелец живёт в дереве супервизии отдельно от процессов партий
  и переживает их падения, поэтому снапшоты доступны рестартующему
  `Game.Server` (`restart: :transient` — supervisor поднимает упавший процесс,
  `init` подхватывает снапшот).

  Записи и чтения идут напрямую в ETS, мимо GenServer: у каждого ключа
  (`room_code`) ровно один писатель — его же процесс партии, гонок нет, а
  сериализация всех партий через один процесс была бы бутылочным горлышком без
  выгоды. Игровых правил здесь нет — это инфраструктура процессного слоя.

  Снапшот живёт, пока партия жива или упала; при штатной смерти комнаты
  (`Game.Server.terminate/2` на `:normal`/`:shutdown`) запись чистится — новая
  комната со случайно совпавшим кодом не воскресит чужое состояние.
  """

  use GenServer

  alias Uno.Game.State

  @table __MODULE__

  # --- API (прямые ETS-операции, процесс-владелец не участвует) ---

  @doc "Сохраняет снапшот партии (ключ — `room_code` внутри состояния)."
  @spec put(State.t()) :: :ok
  def put(%State{room_code: room_code} = game) when is_binary(room_code) do
    true = :ets.insert(@table, {room_code, game})
    :ok
  end

  @doc "Снапшот партии `room_code`, если есть."
  @spec get(String.t()) :: {:ok, State.t()} | :error
  def get(room_code) do
    case :ets.lookup(@table, room_code) do
      [{^room_code, %State{} = game}] -> {:ok, game}
      [] -> :error
    end
  end

  @doc "Удаляет снапшот партии `room_code` (штатная смерть комнаты)."
  @spec delete(String.t()) :: :ok
  def delete(room_code) do
    true = :ets.delete(@table, room_code)
    :ok
  end

  # --- GenServer-владелец таблицы ---

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Профиль write-heavy: снапшот на каждое действие во всех партиях (по
    # разным ключам), чтение — только при восстановлении после падения.
    table =
      :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])

    {:ok, table}
  end
end
