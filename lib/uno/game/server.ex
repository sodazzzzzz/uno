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
  (делегируются в `Rules`), broadcast обновлений через PubSub, **таймер хода** и
  **автоход ботов** (решение берётся у `Uno.Game.Bot.decide/1` и применяется
  `Rules.apply_decision/4`; сам ход — асинхронное `{:bot_move, ref}` с небольшой
  задержкой `:bot_delay`, привязка к `turn_ref` обезвреживает устаревшие).

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

  require Logger

  alias Uno.Game.{Bot, Deck, Rules, State}

  @max_players 4
  @min_players 2
  @default_turn_ms :timer.seconds(30)
  @default_bot_delay 800

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

  @doc """
  Отмечает реального игрока готовым/не готовым к старту (только в лобби). Когда
  все реальные игроки готовы и игроков ≥#{@min_players}, партия стартует
  автоматически (раздача). Боты «готовы» всегда.
  """
  @spec set_ready(String.t(), State.player_id(), boolean) :: :ok
  def set_ready(room_code, player_id, ready?),
    do: GenServer.call(via(room_code), {:set_ready, player_id, ready?})

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
    bot_delay = Keyword.get(opts, :bot_delay, @default_bot_delay)
    {:ok, %{game: State.new(room_code, players), turn_ms: turn_ms, bot_delay: bot_delay}}
  end

  @impl true
  def handle_call(:state, _from, %{game: game} = s), do: {:reply, game, s}

  def handle_call({:project, player_id}, _from, %{game: game, turn_ms: turn_ms} = s) do
    # Дополняем проекцию длительностью хода (процессный конфиг, не игровое
    # состояние) — клиенту для отрисовки кольца-таймера от turn_deadline.
    {:reply, Map.put(Rules.project(game, player_id), :turn_ms, turn_ms), s}
  end

  def handle_call({:add_player, player}, _from, %{game: game} = s) do
    case validate_join(game, player) do
      :ok ->
        new_game = State.add_player(game, player)

        # settle_lobby и уведомит комнату, и авто-стартует, если добор игрока/бота
        # завершил готовность.
        {:reply, {:ok, new_game.players}, settle_lobby(s, new_game)}

      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(
        {:set_ready, player_id, ready?},
        _from,
        %{game: %State{phase: :lobby} = game} = s
      ) do
    {:reply, :ok, settle_lobby(s, State.set_ready(game, player_id, ready?))}
  end

  # Вне лобби готовность не имеет смысла — игнорируем.
  def handle_call({:set_ready, _player_id, _ready?}, _from, s), do: {:reply, :ok, s}

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

  # Ход бота: то же turn_ref-сопоставление паттерном. Решение берём у чистого
  # Bot.decide из проекции и применяем через Rules.apply_decision.
  def handle_info({:bot_move, ref}, %{game: %State{turn_ref: ref} = game} = s) do
    bot_id = current_actor(game)

    case Rules.apply_decision(game, bot_id, Bot.decide(Rules.project(game, bot_id))) do
      {:ok, new_game} ->
        {:noreply, commit(s, new_game)}

      # Бот выдал нелегальный ход (не должно случаться) — не двигаемся и не
      # падаем; на этот ход всё равно взведён таймер, он подстрахует. Логируем,
      # чтобы реальный баг бота не превратился в тихую паузу до таймаута.
      {:error, reason} ->
        Logger.warning(
          "Bot #{inspect(bot_id)} в партии #{game.room_code} вернул нелегальный ход " <>
            "(#{inspect(reason)}); ждём таймер хода"
        )

        {:noreply, s}
    end
  end

  # Устаревший бот-ход (ход уже сменился) — игнорируем.
  def handle_info({:bot_move, _stale_ref}, s), do: {:noreply, s}

  # На успех правила — применяем состояние (перевзвод таймера + broadcast); на
  # отказ — состояние не трогаем, возвращаем ошибку вызывающему.
  defp reply_with({:ok, new_game}, s), do: {:reply, :ok, commit(s, new_game)}
  defp reply_with({:error, _reason} = error, s), do: {:reply, error, s}

  # Фиксирует новое состояние игры: взводит таймер хода, шлёт уведомление и (если
  # ходить должен бот) планирует его автоход.
  defp commit(s, new_game) do
    armed = arm_turn(new_game, s.turn_ms)
    broadcast(armed)
    maybe_schedule_bot(armed, s.bot_delay)
    %{s | game: armed}
  end

  # Если действовать должен бот — планируем его ход отдельным сообщением с
  # задержкой (асинхронно, не блокируя вызывающего). Привязка к `turn_ref`.
  defp maybe_schedule_bot(game, delay) do
    if bot_turn?(game), do: Process.send_after(self(), {:bot_move, game.turn_ref}, delay)
    :ok
  end

  defp bot_turn?(game) do
    case current_actor(game) do
      nil -> false
      actor_id -> Enum.any?(game.players, &(&1.id == actor_id and &1.is_bot))
    end
  end

  # Кто сейчас должен действовать (ходить или выбирать цвет); nil — никто.
  defp current_actor(%State{phase: :choosing_color, pending: {:choose_color, pid}}), do: pid
  defp current_actor(%State{phase: :playing, current_player: pid}), do: pid
  defp current_actor(%State{}), do: nil

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

  # Применяет лобби-состояние: если все реальные готовы и игроков ≥ минимума —
  # раздаёт партию (commit: таймер + broadcast + автоход ботов); иначе просто
  # уведомляет комнату ожидания. Вызывается и из set_ready, и из add_player,
  # чтобы добор игрока/бота, завершивший готовность, тоже стартовал партию.
  defp settle_lobby(s, game) do
    if all_real_ready?(game) do
      commit(s, Rules.deal(game, Deck.shuffle(Deck.new())))
    else
      broadcast(game)
      %{s | game: game}
    end
  end

  # Готовы ли все реальные игроки (боты всегда готовы) И игроков ≥ минимума —
  # условие авто-старта по «Готов».
  defp all_real_ready?(%State{players: players, ready: ready}) do
    length(players) >= @min_players and Enum.all?(players, &(&1.is_bot or &1.id in ready))
  end

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
