defmodule Uno.Game.Deck do
  @moduledoc """
  Чистый модуль колоды UNO.

  Отвечает за: генерацию полной колоды (108 карт), тасование (с инъекцией seed
  для воспроизводимости в тестах), добор карт и перетасовку сброса обратно в
  колоду при её опустошении.

  Здесь НЕТ правил игры (валидность хода, эффекты карт — это `Uno.Game.Rules`)
  и НЕТ процессов (`GenServer`/`send`/`PubSub` — это процессный слой). Все
  функции чистые: данные на входе, данные на выходе.

  ## Представление карты

  Карта — это map `%{color: color | nil, type: type}`:

    * `color` — `:red | :yellow | :green | :blue` для цветных карт, `nil` для
      Wild и Wild Draw Four (активный цвет хранится отдельно, в состоянии партии).
    * `type` — один из:
      * `{:number, 0..9}` — числовая карта;
      * `:skip`, `:reverse`, `:draw_two` — цветные «акшн»-карты;
      * `:wild`, `:wild_draw_four` — чёрные карты.

  Такое представление делает проверку «совпадения» в правилах простой: для двух
  карт одного цвета сравниваются `:color`, а «то же число / тот же акшн» — это
  просто равенство `:type` (`{:number, 7} == {:number, 7}`, `:skip == :skip`).
  """

  @colors [:red, :yellow, :green, :blue]

  @type color :: :red | :yellow | :green | :blue
  @type type ::
          {:number, 0..9}
          | :skip
          | :reverse
          | :draw_two
          | :wild
          | :wild_draw_four
  @type card :: %{color: color | nil, type: type}

  @typedoc """
  Seed для детерминированного тасования. Целое число удобно в тестах; кортеж —
  «сырое» состояние генератора `:rand` (см. `:rand.seed/2`).
  """
  @type seed :: integer | {integer, integer, integer}

  @typedoc "Функция-шафлер, инъекция которой делает добор детерминированным в тестах."
  @type shuffler :: ([card] -> [card])

  @doc """
  Полная упорядоченная колода из 108 карт (без тасования).

  Порядок детерминирован, поэтому функция удобна как стабильная основа для
  тестов и для последующего тасования с конкретным seed.
  """
  @spec new() :: [card]
  def new do
    colored =
      for color <- @colors, type <- color_types() do
        %{color: color, type: type}
      end

    wilds =
      List.duplicate(%{color: nil, type: :wild}, 4) ++
        List.duplicate(%{color: nil, type: :wild_draw_four}, 4)

    colored ++ wilds
  end

  # Типы карт одного цвета: одна 0, по две 1..9, по две Skip/Reverse/Draw Two.
  # Итого 19 числовых + 6 акшн = 25 карт на цвет.
  defp color_types do
    numbers = [{:number, 0}] ++ for(n <- 1..9, _ <- 1..2, do: {:number, n})
    actions = for(type <- [:skip, :reverse, :draw_two], _ <- 1..2, do: type)
    numbers ++ actions
  end

  @doc """
  Тасование без seed — для продакшна. Недетерминировано; в тестах используй
  `shuffle/2` или инъекцию шафлера, не эту функцию.
  """
  @spec shuffle([card]) :: [card]
  def shuffle(deck), do: Enum.shuffle(deck)

  @doc """
  Детерминированное тасование по заданному `seed`.

  Чистая функция: НЕ трогает глобальное состояние генератора процесса. Каждой
  карте присваивается случайный ключ из явно прокинутого состояния `:rand`,
  затем колода сортируется по ключам — это даёт равномерную перестановку,
  воспроизводимую для одного и того же seed.
  """
  @spec shuffle([card], seed) :: [card]
  def shuffle(deck, seed) do
    state = seed_state(seed)

    {keyed, _state} =
      Enum.map_reduce(deck, state, fn card, st ->
        {key, st2} = :rand.uniform_s(st)
        {{key, card}, st2}
      end)

    keyed
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp seed_state(seed) when is_integer(seed), do: :rand.seed_s(:exsss, {seed, seed, seed})
  defp seed_state({_, _, _} = seed), do: :rand.seed_s(:exsss, seed)

  @doc """
  Примитив добора: снимает с верха колоды `pile` до `n` карт.

  Возвращает `{taken, rest}`. Если в колоде меньше `n` карт — берёт сколько есть
  (без перетасовки сброса; перетасовку делает `draw/4`).
  """
  @spec take([card], non_neg_integer) :: {[card], [card]}
  def take(pile, n) when is_integer(n) and n >= 0 do
    {Enum.take(pile, n), Enum.drop(pile, n)}
  end

  @doc """
  Добор `n` карт с автоматической перетасовкой сброса при опустошении колоды.

  Сначала берём с верха `draw_pile`. Если карт не хватило — берём `discard_pile`
  **кроме верхней карты** (она остаётся видимой), тасуем `shuffler`-ом, делаем
  новой колодой и добираем остаток (CLAUDE.md §5, «Колода закончилась»).

  Если и после перетасовки тянуть нечего — возвращаем сколько набралось (может
  быть меньше `n` или вовсе `0`); вызывающий код просто передаст ход без добора.

  `shuffler` инъектируется для детерминизма в тестах (по умолчанию — `shuffle/1`,
  недетерминированный продакшн-вариант). Гарантируется сохранение количества
  карт: `drawn ++ new_draw_pile ++ new_discard_pile` — перестановка исходных
  `draw_pile ++ discard_pile`.

  Возвращает `{drawn, new_draw_pile, new_discard_pile}`.
  """
  @spec draw([card], [card], non_neg_integer, shuffler) :: {[card], [card], [card]}
  def draw(draw_pile, discard_pile, n, shuffler \\ &shuffle/1)
      when is_integer(n) and n >= 0 and is_function(shuffler, 1) do
    {taken, rest} = take(draw_pile, n)
    remaining = n - length(taken)

    if remaining == 0 do
      {taken, rest, discard_pile}
    else
      refill_and_take(taken, remaining, discard_pile, shuffler)
    end
  end

  # Колода опустела до того, как набрали n карт: перетасовываем сброс (кроме его
  # верхней карты) в новую колоду и добираем остаток. Перетасовка происходит не
  # более одного раза — для добора 1/2/4 карт этого всегда достаточно.
  defp refill_and_take(taken, remaining, discard_pile, shuffler) do
    case discard_pile do
      [] ->
        {taken, [], []}

      [top] ->
        # В сбросе только видимая карта — тасовать нечего, добор невозможен.
        {taken, [], [top]}

      [top | rest_discard] ->
        new_draw = shuffler.(rest_discard)
        {more, leftover} = take(new_draw, remaining)
        {taken ++ more, leftover, [top]}
    end
  end
end
