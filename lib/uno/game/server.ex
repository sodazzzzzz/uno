defmodule Uno.Game.Server do
  @moduledoc """
  Процесс одной партии UNO — один `GenServer` на партию.

  Процесс оправдан по делу: он хранит **изменяемое** состояние партии,
  **сериализует** ходы (сообщения обрабатываются по одному — гонок нет) и даёт
  **изоляцию падений** (одна партия рухнула — другие живут). Адресуется по
  `room_code` через `Registry`, живёт под `DynamicSupervisor`.

  Сервер НЕ содержит правил UNO — он хранит `Uno.Game.State`, принимает
  сообщения и делегирует в чистый `Uno.Game.Rules` (golden rule: правила —
  только в чистом слое). Здесь — управление лобби и проекция; старт партии,
  действия игроков, broadcast и таймер хода появятся следующими кусками.

  `restart: :temporary` — без персистентности воскрешать упавшую партию пустой
  бессмысленно; изоляцию даёт сам `:one_for_one`-супервизор.
  """

  use GenServer, restart: :temporary

  alias Uno.Game.{Rules, State}

  @max_players 4

  @typedoc "Игрок, как его принимает лобби."
  @type player :: %{id: State.player_id(), name: String.t(), is_bot: boolean}

  # --- Публичный API (клиентская сторона) ---

  @doc "Запускает процесс партии. `opts`: `:room_code` (обяз.), `:players` (опц.)."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    room_code = Keyword.fetch!(opts, :room_code)
    GenServer.start_link(__MODULE__, opts, name: via(room_code))
  end

  @doc "Полное состояние партии (для тестов/отладки; на клиент идёт только проекция)."
  @spec state(String.t()) :: State.t()
  def state(room_code), do: GenServer.call(via(room_code), :state)

  @doc "Проекция состояния для игрока `player_id` (`Rules.project/2`)."
  @spec project(String.t(), State.player_id()) :: Rules.projection()
  def project(room_code, player_id), do: GenServer.call(via(room_code), {:project, player_id})

  @doc """
  Добавляет игрока в лобби. Управление лобби (не правила игры): только в фазе
  `:lobby`, не больше #{@max_players} игроков, без повтора `id`.

  При успехе возвращает обновлённый **ростер** (`[player]`), а НЕ полный `State`:
  полное состояние (с руками) не должно покидать процесс — иначе инвариант
  скрытой информации (§4.2) легко нарушить, уронив `State` в assigns LiveView.
  """
  @spec add_player(String.t(), player) ::
          {:ok, [player]} | {:error, :game_started | :full | :already_joined}
  def add_player(room_code, player), do: GenServer.call(via(room_code), {:add_player, player})

  @doc "Адресный кортеж процесса партии в `Registry`."
  @spec via(String.t()) :: {:via, module, {module, String.t()}}
  def via(room_code), do: {:via, Registry, {Uno.Game.Registry, room_code}}

  # --- GenServer ---

  @impl true
  def init(opts) do
    room_code = Keyword.fetch!(opts, :room_code)
    players = Keyword.get(opts, :players, [])
    {:ok, State.new(room_code, players)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:project, player_id}, _from, state) do
    {:reply, Rules.project(state, player_id), state}
  end

  def handle_call({:add_player, player}, _from, state) do
    case validate_join(state, player) do
      :ok ->
        new_state = State.add_player(state, player)
        {:reply, {:ok, new_state.players}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Проверки лобби (не правила хода): фаза, вместимость, уникальность id.
  defp validate_join(%State{phase: phase}, _player) when phase != :lobby,
    do: {:error, :game_started}

  defp validate_join(%State{players: players}, _player) when length(players) >= @max_players,
    do: {:error, :full}

  defp validate_join(%State{players: players}, %{id: id}) do
    if Enum.any?(players, &(&1.id == id)), do: {:error, :already_joined}, else: :ok
  end
end
