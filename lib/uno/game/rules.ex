defmodule Uno.Game.Rules do
  @moduledoc """
  Чистый модуль правил UNO.

  Отвечает за игровую логику над данными: старт партии (раздача + стартовая
  карта), определение следующего игрока и проекцию состояния для конкретного
  игрока (со скрытием чужих рук).

  Здесь НЕТ процессов: ни `GenServer`, ни `send`, ни `Process`, ни `PubSub` —
  всё это процессный слой (`Uno.Game.Server`). Все функции чистые: на входе
  данные (`Uno.Game.State` + параметры), на выходе данные. Поэтому модуль
  тестируется без поднятия процессов.

  Покрывает старт-раздачу (`deal/2`), следующего игрока (`next_player/1`),
  проекцию (`project/2`), валидность хода (`playable?/3`), применение хода —
  розыгрыш карты с эффектами Skip/Reverse/Draw Two/Wild/Wild+4 (`apply_play/3`),
  добор (`apply_draw/2`) и резолв выбора цвета после Wild/Wild+4
  (`choose_color/3` — выход из `:choosing_color`, для Wild Draw Four добор 4 со
  скипом). Эффекты Skip/Reverse (включая «Reverse при 2 = Skip») построены поверх
  `next_player/1`.

  Пока НЕ здесь (следующий кусок правил): явный пас после добора — сейчас
  `apply_draw/2` оставляет ход за игроком — и авто-выбор цвета по большинству при
  таймауте `:choosing_color` (увязан с серверным таймером).
  """

  alias Uno.Game.{Deck, State}

  @hand_size 7
  @colors [:red, :yellow, :green, :blue]

  @typedoc """
  Проекция состояния партии для одного игрока — ровно то, что уходит в LiveView.

  Инвариант скрытого состояния: карты соперников физически отсутствуют — у них
  доступно ТОЛЬКО число карт (`card_count`). Полные `State.hands` за пределы
  домена не выходят.
  """
  @type projection :: %{
          my_hand: [Deck.card()],
          others: [%{id: State.player_id(), name: String.t(), card_count: non_neg_integer}],
          discard_top: Deck.card() | nil,
          current_color: Deck.color() | nil,
          whose_turn: State.player_id() | nil,
          direction: State.direction(),
          phase: State.phase(),
          pending: State.pending(),
          turn_deadline: integer | nil,
          winner: State.player_id() | nil
        }

  @doc """
  Старт партии: раздаёт по #{@hand_size} карт каждому игроку и выкладывает
  стартовую карту сброса.

  `deck` принимается **уже перемешанным** — это держит функцию чистой и делает
  тесты детерминированными (в проде шафлит `Server`/`Deck.shuffle/1`, в тестах —
  `Deck.shuffle/2` по seed или явный список). Раздаём по #{@hand_size} карт
  каждому подряд: при перемешанной колоде порядок раздачи на игру не влияет.

  **Стартовая карта всегда числовая.** Снимаем верх остатка колоды; любую
  не-числовую карту (Wild, Wild Draw Four, Skip, Reverse, Draw Two) возвращаем
  в низ колоды и тянем следующую, пока не выпадет `{:number, n}`. Эта карта
  становится верхом сброса, а её цвет — стартовым `current_color`. Так на старте
  не бывает ни выбора цвета, ни эффекта первой карты.

  Возвращает состояние в фазе `:playing`: ходит первый посаженный игрок,
  направление `:cw`. Таймер хода (`turn_ref`/`turn_deadline`) выставляет уже
  процессный слой — это не дело чистых правил.

  Контракт (нарушение — ошибка вызывающего, не пользовательский ввод): колода
  должна быть достаточно большой для полной раздачи плюс стартовой карты
  (`length(deck) > players * #{@hand_size}`, иначе ход не матчится —
  `FunctionClauseError`) и содержать хотя бы одну числовую карту для старта
  (иначе `ArgumentError` с понятным сообщением). Для полной 108-карточной колоды
  оба условия выполняются всегда.
  """
  @spec deal(State.t(), [Deck.card()]) :: State.t()
  def deal(%State{players: [first | _] = players} = state, deck)
      when is_list(deck) and length(deck) > length(players) * @hand_size do
    {hands, rest} = deal_hands(players, deck)
    {start_card, draw_pile} = draw_starting_card(rest)

    %{
      state
      | phase: :playing,
        hands: hands,
        draw_pile: draw_pile,
        discard_pile: [start_card],
        current_player: first.id,
        current_color: start_card.color,
        direction: :cw,
        pending: nil,
        winner: nil
    }
  end

  # Берём по @hand_size карт с верха колоды каждому игроку по порядку.
  defp deal_hands(players, deck) do
    Enum.reduce(players, {%{}, deck}, fn %{id: id}, {hands, pile} ->
      {cards, rest} = Deck.take(pile, @hand_size)
      {Map.put(hands, id, cards), rest}
    end)
  end

  # Снимаем верх до первой числовой карты; не-числовые уходят в низ колоды,
  # сохраняя свой относительный порядок. Возвращает {числовая_карта, остаток_колоды}.
  defp draw_starting_card(deck), do: draw_starting_card(deck, [])

  defp draw_starting_card([%{type: {:number, _}} = card | rest], skipped) do
    {card, rest ++ Enum.reverse(skipped)}
  end

  defp draw_starting_card([card | rest], skipped) do
    draw_starting_card(rest, [card | skipped])
  end

  defp draw_starting_card([], _skipped) do
    raise ArgumentError, "колода не содержит числовой карты для стартового сброса"
  end

  @doc """
  Id игрока, который ходит следующим — один шаг в текущем `direction`.

  Учитывает направление (`:cw` — вперёд по списку посадки, `:ccw` — назад) и
  заворачивание по кругу. Это примитив: эффекты Skip/Draw Two (пропуск) и
  Reverse надстраиваются над ним в применении хода (PR-B), здесь их нет.
  """
  @spec next_player(State.t()) :: State.player_id()
  def next_player(%State{players: players, current_player: current, direction: direction}) do
    ids = Enum.map(players, & &1.id)
    index = Enum.find_index(ids, &(&1 == current))
    step = if direction == :cw, do: 1, else: -1

    Enum.at(ids, Integer.mod(index + step, length(ids)))
  end

  @doc """
  Проекция состояния для игрока `player_id` — то, что отдаём в его LiveView.

  Своя рука уходит целиком; у соперников — только число карт (`card_count`),
  сами карты в проекцию не попадают. Это и есть инвариант скрытого состояния:
  полные `State.hands` никогда не покидают домен.

  Соперники перечислены в порядке посадки (без самого игрока). Работает в любой
  фазе, включая `:lobby` (тогда `discard_top` — `nil`, руки пустые).
  """
  @spec project(State.t(), State.player_id()) :: projection
  def project(%State{} = state, player_id) do
    %{
      my_hand: Map.get(state.hands, player_id, []),
      others: others(state, player_id),
      discard_top: List.first(state.discard_pile),
      current_color: state.current_color,
      whose_turn: state.current_player,
      direction: state.direction,
      phase: state.phase,
      pending: state.pending,
      turn_deadline: state.turn_deadline,
      winner: state.winner
    }
  end

  defp others(%State{players: players, hands: hands}, player_id) do
    for %{id: id, name: name} <- players, id != player_id do
      %{id: id, name: name, card_count: length(Map.get(hands, id, []))}
    end
  end

  @typedoc "Причина отказа применить ход или выбор цвета."
  @type reason ::
          :not_playing
          | :not_your_turn
          | :card_not_in_hand
          | :illegal_card
          | :not_choosing_color
          | :not_your_choice
          | :invalid_color

  @doc """
  Можно ли сыграть карту `card` поверх верхней карты сброса `top` при активном
  цвете `current_color` (§5).

  Совпадение — по **цвету** (`card.color == current_color`), по **числу** или
  **типу акшна** (равенство `:type` с `top`), либо карта — **Wild / Wild Draw
  Four** (играются всегда). Цвет сравнивается с `current_color`, а НЕ с цветом
  верхней карты: после Wild верх сброса чёрный (`color: nil`), а активный цвет
  хранится отдельно.
  """
  @spec playable?(Deck.card(), Deck.card(), Deck.color() | nil) :: boolean
  def playable?(%{type: :wild}, _top, _current_color), do: true
  def playable?(%{type: :wild_draw_four}, _top, _current_color), do: true

  def playable?(%{color: color}, _top, current_color)
      when not is_nil(color) and color == current_color,
      do: true

  def playable?(%{type: type}, %{type: type}, _current_color), do: true
  def playable?(_card, _top, _current_color), do: false

  @doc """
  Применяет ход «сыграть карту `card`» игроком `player_id`.

  Проверяет по порядку: партия в фазе `:playing`, сейчас ход этого игрока, карта
  есть в руке, карта играбельна (`playable?/3` относительно верха сброса и
  `current_color`). При нарушении — `{:error, reason}`, состояние не меняется.

  При успехе карта уходит из руки в сброс, обновляется `current_color` и
  применяется эффект (§5):

    * число — ход переходит дальше;
    * **Skip** — следующий игрок пропускается;
    * **Reverse** — меняет направление; **при 2 игроках действует как Skip**
      (сыгравший ходит снова);
    * **Draw Two** — следующий берёт 2 карты и пропускается;
    * **Wild / Wild Draw Four** — партия переходит в `:choosing_color` с
      `pending: {:choose_color, player_id}`; ход НЕ передаётся, цвет пока не
      меняется. Выбор цвета и (для Wild+4) добор 4 карт со скипом — следующий
      кусок правил.

  **Победа имеет приоритет** (§5: сыгравший последнюю карту побеждает): если
  после хода рука опустела — сразу `winner` и `phase: :finished`, без эффектов и
  без перехода в `:choosing_color` (даже если последней была Wild/Wild+4).

  `shuffler` инъектируется для детерминизма (нужен, если Draw Two вынуждает
  перетасовать сброс при пустой колоде); по умолчанию — `Deck.shuffle/1`.
  """
  @spec apply_play(State.t(), State.player_id(), Deck.card(), Deck.shuffler()) ::
          {:ok, State.t()} | {:error, reason}
  def apply_play(state, player_id, card, shuffler \\ &Deck.shuffle/1)

  def apply_play(
        %State{phase: :playing, current_player: player_id} = state,
        player_id,
        card,
        shuffler
      ) do
    with :ok <- check_in_hand(state, player_id, card),
         :ok <- check_playable(state, card) do
      {:ok, do_apply_play(state, player_id, card, shuffler)}
    end
  end

  def apply_play(%State{phase: :playing}, _player_id, _card, _shuffler),
    do: {:error, :not_your_turn}

  def apply_play(%State{}, _player_id, _card, _shuffler), do: {:error, :not_playing}

  @doc """
  Применяет ход «взять карту» игроком `player_id` в его ход.

  Тянет 1 карту (с перетасовкой сброса при пустой колоде — `Deck.draw/4`). По §5
  добор НЕ передаёт ход автоматически: добранную карту игрок волен сыграть сразу
  (`apply_play/3`) или оставить и спасовать, поэтому ход остаётся за ним.
  Исключение: если тянуть нечего даже после перетасовки (колода и сброс
  исчерпаны) — ход просто переходит дальше (§5 «колода закончилась»).

  Проверяет фазу `:playing` и что сейчас ход игрока; иначе `{:error, reason}`.
  `shuffler` инъектируется для детерминизма (по умолчанию `Deck.shuffle/1`).
  """
  @spec apply_draw(State.t(), State.player_id(), Deck.shuffler()) ::
          {:ok, State.t()} | {:error, reason}
  def apply_draw(state, player_id, shuffler \\ &Deck.shuffle/1)

  def apply_draw(%State{phase: :playing, current_player: player_id} = state, player_id, shuffler) do
    {drawn, draw_pile, discard_pile} = Deck.draw(state.draw_pile, state.discard_pile, 1, shuffler)
    hand = Map.get(state.hands, player_id, []) ++ drawn
    current = if drawn == [], do: next_player(state), else: player_id

    {:ok,
     %{
       state
       | draw_pile: draw_pile,
         discard_pile: discard_pile,
         hands: Map.put(state.hands, player_id, hand),
         current_player: current
     }}
  end

  def apply_draw(%State{phase: :playing}, _player_id, _shuffler), do: {:error, :not_your_turn}
  def apply_draw(%State{}, _player_id, _shuffler), do: {:error, :not_playing}

  @doc """
  Резолвит выбор цвета игроком `player_id` после сыгранной Wild / Wild Draw Four.

  Допустимо только в фазе `:choosing_color`, когда ждём выбор именно этого игрока
  (`pending == {:choose_color, player_id}`), а `color` — один из
  `:red | :yellow | :green | :blue`. Иначе `{:error, reason}`
  (`:not_choosing_color | :not_your_choice | :invalid_color`).

  Устанавливает `current_color`, возвращает партию в `:playing` (`pending: nil`)
  и применяет отложенный эффект чёрной карты (по верху сброса):

    * **Wild** — ход переходит следующему игроку;
    * **Wild Draw Four** — следующий берёт 4 карты и пропускается.

  `shuffler` инъектируется для детерминизма (нужен для добора 4 при пустой
  колоде); по умолчанию `Deck.shuffle/1`.
  """
  @spec choose_color(State.t(), State.player_id(), Deck.color(), Deck.shuffler()) ::
          {:ok, State.t()} | {:error, reason}
  def choose_color(state, player_id, color, shuffler \\ &Deck.shuffle/1)

  def choose_color(
        %State{phase: :choosing_color, pending: {:choose_color, player_id}} = state,
        player_id,
        color,
        shuffler
      )
      when color in @colors do
    resolved = %{state | current_color: color, phase: :playing, pending: nil}
    {:ok, resolve_wild(resolved, shuffler)}
  end

  def choose_color(
        %State{phase: :choosing_color, pending: {:choose_color, player_id}},
        player_id,
        _color,
        _shuffler
      ),
      do: {:error, :invalid_color}

  def choose_color(%State{phase: :choosing_color}, _player_id, _color, _shuffler),
    do: {:error, :not_your_choice}

  def choose_color(%State{}, _player_id, _color, _shuffler), do: {:error, :not_choosing_color}

  defp check_in_hand(%State{hands: hands}, player_id, card) do
    if card in Map.get(hands, player_id, []), do: :ok, else: {:error, :card_not_in_hand}
  end

  defp check_playable(%State{discard_pile: [top | _], current_color: color}, card) do
    if playable?(card, top, color), do: :ok, else: {:error, :illegal_card}
  end

  defp do_apply_play(state, player_id, card, shuffler) do
    hand = Map.get(state.hands, player_id, []) -- [card]

    base = %{
      state
      | hands: Map.put(state.hands, player_id, hand),
        discard_pile: [card | state.discard_pile]
    }

    if hand == [] do
      %{base | phase: :finished, winner: player_id, pending: nil}
    else
      apply_effect(base, card, shuffler)
    end
  end

  defp apply_effect(state, %{type: {:number, _}, color: color}, _shuffler) do
    %{state | current_color: color, current_player: next_player(state)}
  end

  defp apply_effect(state, %{type: :skip, color: color}, _shuffler) do
    %{state | current_color: color, current_player: skip_next(state)}
  end

  defp apply_effect(state, %{type: :reverse, color: color}, _shuffler) do
    reversed = %{state | direction: flip(state.direction)}

    # При 2 игроках Reverse = Skip: ход возвращается к сыгравшему.
    current = if two_players?(state), do: state.current_player, else: next_player(reversed)
    %{reversed | current_color: color, current_player: current}
  end

  defp apply_effect(state, %{type: :draw_two, color: color}, shuffler) do
    victim = next_player(state)
    {drawn, draw_pile, discard_pile} = Deck.draw(state.draw_pile, state.discard_pile, 2, shuffler)
    victim_hand = Map.get(state.hands, victim, []) ++ drawn

    %{
      state
      | current_color: color,
        draw_pile: draw_pile,
        discard_pile: discard_pile,
        hands: Map.put(state.hands, victim, victim_hand),
        current_player: skip_next(state)
    }
  end

  defp apply_effect(state, %{type: type}, _shuffler) when type in [:wild, :wild_draw_four] do
    %{state | phase: :choosing_color, pending: {:choose_color, state.current_player}}
  end

  # Отложенный эффект чёрной карты после выбора цвета (верх сброса — сама Wild).
  defp resolve_wild(%State{discard_pile: [%{type: :wild_draw_four} | _]} = state, shuffler) do
    victim = next_player(state)
    {drawn, draw_pile, discard_pile} = Deck.draw(state.draw_pile, state.discard_pile, 4, shuffler)
    victim_hand = Map.get(state.hands, victim, []) ++ drawn

    %{
      state
      | draw_pile: draw_pile,
        discard_pile: discard_pile,
        hands: Map.put(state.hands, victim, victim_hand),
        current_player: skip_next(state)
    }
  end

  defp resolve_wild(%State{discard_pile: [%{type: :wild} | _]} = state, _shuffler) do
    %{state | current_player: next_player(state)}
  end

  # На один шаг дальше следующего — пропуск одного игрока (Skip / скип после Draw Two).
  defp skip_next(state), do: next_player(%{state | current_player: next_player(state)})

  defp flip(:cw), do: :ccw
  defp flip(:ccw), do: :cw

  defp two_players?(%State{players: players}), do: length(players) == 2
end
