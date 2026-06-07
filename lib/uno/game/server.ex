defmodule Uno.Game.Server do
  @moduledoc """
  Процесс одной партии UNO — один `GenServer` на партию.

  Процесс оправдан по делу: он хранит **изменяемое** состояние партии,
  **сериализует** ходы (сообщения обрабатываются по одному — гонок нет) и даёт
  **изоляцию падений** (одна партия рухнула — другие живут). Адресуется по
  `room_code` через `Registry`, живёт под `DynamicSupervisor`.

  Сервер НЕ содержит правил UNO — он хранит `Uno.Game.State`, принимает
  сообщения и делегирует в чистый `Uno.Game.Rules` (golden rule: правила —
  только в чистом слое). Здесь — управление лобби, старт партии, действия игроков
  (делегируются в `Rules`) и broadcast обновлений через PubSub. Таймер хода
  появится следующим куском.

  Broadcast — это только уведомление `{:game_update, room_code}` в топик
  `"game:" <> room_code`: полный `State` по шине не ходит (иначе утечёт скрытое
  состояние), подписчики (LiveView) сами берут свою проекцию через `project/2`.

  `restart: :temporary` — без персистентности воскрешать упавшую партию пустой
  бессмысленно; изоляцию даёт сам `:one_for_one`-супервизор.
  """

  use GenServer, restart: :temporary

  alias Uno.Game.{Deck, Rules, State}

  @max_players 4
  @min_players 2

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

  @doc "Топик PubSub с обновлениями партии (`{:game_update, room_code}`)."
  @spec topic(String.t()) :: String.t()
  def topic(room_code), do: "game:" <> room_code

  @doc """
  Начинает партию: раздаёт карты (`Rules.deal/2` на свежей перемешанной колоде).
  Нужны фаза `:lobby` и хотя бы #{@min_players} игрока.
  """
  @spec start_game(String.t()) :: :ok | {:error, :not_enough_players | :already_started}
  def start_game(room_code), do: GenServer.call(via(room_code), :start_game)

  @doc "Игрок `player_id` играет карту `card`."
  @spec play(String.t(), State.player_id(), Deck.card()) :: :ok | {:error, Rules.reason()}
  def play(room_code, player_id, card),
    do: GenServer.call(via(room_code), {:play, player_id, card})

  @doc "Игрок `player_id` добирает карту."
  @spec draw(String.t(), State.player_id()) :: :ok | {:error, Rules.reason()}
  def draw(room_code, player_id), do: GenServer.call(via(room_code), {:draw, player_id})

  @doc "Игрок `player_id` пасует (после добора)."
  @spec pass(String.t(), State.player_id()) :: :ok | {:error, Rules.reason()}
  def pass(room_code, player_id), do: GenServer.call(via(room_code), {:pass, player_id})

  @doc "Игрок `player_id` выбирает активный цвет после Wild/Wild Draw Four."
  @spec choose_color(String.t(), State.player_id(), Deck.color()) ::
          :ok | {:error, Rules.reason()}
  def choose_color(room_code, player_id, color),
    do: GenServer.call(via(room_code), {:choose_color, player_id, color})

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

  def handle_call(:start_game, _from, state), do: reply_with(start(state), state)

  def handle_call({:play, player_id, card}, _from, state),
    do: reply_with(Rules.apply_play(state, player_id, card), state)

  def handle_call({:draw, player_id}, _from, state),
    do: reply_with(Rules.apply_draw(state, player_id), state)

  def handle_call({:pass, player_id}, _from, state),
    do: reply_with(Rules.pass(state, player_id), state)

  def handle_call({:choose_color, player_id, color}, _from, state),
    do: reply_with(Rules.choose_color(state, player_id, color), state)

  # На успех правила — обновляем состояние и рассылаем уведомление; на отказ —
  # состояние не трогаем и возвращаем ошибку вызывающему.
  defp reply_with({:ok, new_state}, _old_state), do: {:reply, :ok, broadcast(new_state)}
  defp reply_with({:error, _reason} = error, old_state), do: {:reply, error, old_state}

  defp start(%State{phase: :lobby, players: players} = state)
       when length(players) >= @min_players do
    {:ok, Rules.deal(state, Deck.shuffle(Deck.new()))}
  end

  defp start(%State{phase: :lobby}), do: {:error, :not_enough_players}
  defp start(%State{}), do: {:error, :already_started}

  defp broadcast(%State{room_code: room_code} = state) do
    Phoenix.PubSub.broadcast(Uno.PubSub, topic(room_code), {:game_update, room_code})
    state
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
