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

  Это **первая часть** правил (старт-раздача, `next_player/1`, `project/2`).
  Валидность хода (`playable?/3`), применение хода с эффектами карт
  (`apply_play/3`, переход в `:choosing_color`) и добор (`apply_draw/2`) —
  отдельный модульный кусок (PR-B). Эффекты Skip/Reverse, включая частный
  случай «Reverse при 2 игроках = Skip», строятся поверх `next_player/1` там,
  а не здесь.
  """

  alias Uno.Game.{Deck, State}

  @hand_size 7

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
end
