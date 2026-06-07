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
  (делегируются в `Rules`), broadcast обновлений через PubSub и **таймер хода**.

  Broadcast — это только уведомление `{:game_update, room_code}` в топик
  `"game:" <> room_code`: полный `State` по шине не ходит (иначе утечёт скрытое
  состояние), подписчики (LiveView) сами берут свою проекцию через `project/2`.

  ## Таймер хода (turn_ref-схема, §4.3)

  ЛЮБОЕ успешное изменение инкрементит `State.turn_ref` и (в активной фазе)
  планирует `Process.send_after(self(), {:turn_timeout, ref}, turn_ms)`. В
  `handle_info` совпадение `ref` с текущим `turn_ref` проверяется паттерном:
  протухший таймаут от уже сыгранного хода просто игнорируется. Старые таймеры
  НЕ отменяются (`cancel_timer` не нужен) — их обезвреживает сам инкремент
  `turn_ref`. На таймауте — авто-действие из `Rules.apply_timeout/3`.

  Состояние процесса — `%{game: State.t(), turn_ms: pos_integer}`: конфиг хода
  отделён от игрового состояния. `:turn_ms` берётся из opts (по умолчанию 30с).

  `restart: :temporary` — без персистентности воскрешать упавшую партию пустой
  бессмысленно; изоляцию даёт сам `:one_for_one`-супервизор.
  """

  use GenServer, restart: :temporary

  alias Uno.Game.{Deck, Rules, State}

  @max_players 4
  @min_players 2
  @default_turn_ms :timer.seconds(30)

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
    turn_ms = Keyword.get(opts, :turn_ms, @default_turn_ms)
    {:ok, %{game: State.new(room_code, players), turn_ms: turn_ms}}
  end

  @impl true
  def handle_call(:state, _from, %{game: game} = s), do: {:reply, game, s}

  def handle_call({:project, player_id}, _from, %{game: game} = s) do
    {:reply, Rules.project(game, player_id), s}
  end

  def handle_call({:add_player, player}, _from, %{game: game} = s) do
    case validate_join(game, player) do
      :ok ->
        new_game = State.add_player(game, player)
        {:reply, {:ok, new_game.players}, %{s | game: new_game}}

      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(:start_game, _from, %{game: game} = s), do: reply_with(start(game), s)

  def handle_call({:play, player_id, card}, _from, %{game: game} = s),
    do: reply_with(Rules.apply_play(game, player_id, card), s)

  def handle_call({:draw, player_id}, _from, %{game: game} = s),
    do: reply_with(Rules.apply_draw(game, player_id), s)

  def handle_call({:pass, player_id}, _from, %{game: game} = s),
    do: reply_with(Rules.pass(game, player_id), s)

  def handle_call({:choose_color, player_id, color}, _from, %{game: game} = s),
    do: reply_with(Rules.choose_color(game, player_id, color), s)

  # turn_ref-схема (§4.3): сообщение матчится только если его ref совпадает с
  # текущим `turn_ref` игры (одна и та же переменная `ref` в обоих местах).
  @impl true
  def handle_info({:turn_timeout, ref}, %{game: %State{turn_ref: ref} = game} = s) do
    {:ok, timed_out} = Rules.apply_timeout(game)
    {:noreply, commit(s, timed_out)}
  end

  # Протухший таймаут от уже сыгранного хода — безвреден, игнорируем.
  def handle_info({:turn_timeout, _stale_ref}, s), do: {:noreply, s}

  # На успех правила — применяем состояние (перевзвод таймера + broadcast); на
  # отказ — состояние не трогаем, возвращаем ошибку вызывающему.
  defp reply_with({:ok, new_game}, s), do: {:reply, :ok, commit(s, new_game)}
  defp reply_with({:error, _reason} = error, s), do: {:reply, error, s}

  # Фиксирует новое состояние игры: взводит таймер хода и шлёт уведомление.
  defp commit(s, new_game) do
    armed = arm_turn(new_game, s.turn_ms)
    broadcast(armed)
    %{s | game: armed}
  end

  # Взвод таймера хода по turn_ref-схеме: ЛЮБОЕ изменение инкрементит `turn_ref`
  # (старый запланированный таймаут протухает сам), и в активной фазе планируется
  # новый `{:turn_timeout, ref}`. На `:finished` таймер не ставим (deadline nil).
  defp arm_turn(%State{turn_ref: ref} = game, turn_ms) do
    next_ref = ref + 1

    if game.phase in [:playing, :choosing_color] do
      Process.send_after(self(), {:turn_timeout, next_ref}, turn_ms)
      %{game | turn_ref: next_ref, turn_deadline: System.system_time(:millisecond) + turn_ms}
    else
      %{game | turn_ref: next_ref, turn_deadline: nil}
    end
  end

  defp start(%State{phase: :lobby, players: players} = game)
       when length(players) >= @min_players do
    {:ok, Rules.deal(game, Deck.shuffle(Deck.new()))}
  end

  defp start(%State{phase: :lobby}), do: {:error, :not_enough_players}
  defp start(%State{}), do: {:error, :already_started}

  defp broadcast(%State{room_code: room_code}) do
    Phoenix.PubSub.broadcast(Uno.PubSub, topic(room_code), {:game_update, room_code})
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
