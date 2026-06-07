defmodule Uno.Game.Bot do
  @moduledoc """
  Чистый выбор хода ботом — **из проекции игрока**, не из полного состояния.

  Бот получает ровно то же, что видит человек: `Uno.Game.Rules.project/2` (своя
  рука целиком, у соперников — только число карт, верх сброса, активный цвет,
  фаза). Подсматривать чужие руки он физически не может — на вход приходит
  проекция, а не `State`. Это и есть смысл «бот из проекции» (§3).

  Здесь только РЕШЕНИЕ хода — данные на входе, решение на выходе. Применение
  решения (`Rules.apply_play/3`, `apply_draw/2`, `pass/2`, `choose_color/3`),
  таймеры и циклы «сходи за бота» — процессный слой (`Game.Server`), не здесь.

  `decide/1` вызывается, когда ходить/выбирать должен именно этот бот (это
  гарантирует вызывающий по `whose_turn`/`pending`).

  ## Стратегия (намеренно простая для MVP)

    * есть играбельная карта — играем её, но **бережём чёрные карты**: цветную
      или числовую предпочитаем Wild / Wild Draw Four;
    * играбельной карты нет и добора в этот ход ещё не было — берём карту;
    * играбельной карты нет, но карту уже брали — пасуем;
    * при выборе цвета — берём цвет, которого в руке больше всего.

  Более умная игра (стэкинг, придерживание Draw-карт, счёт карт соперников) — это
  фаза полировки, не MVP.
  """

  alias Uno.Game.Rules

  @doc """
  Решение бота по проекции `view` (`Rules.project/2`).

  В фазе `:playing` возвращает `{:play, card}` / `:draw` / `:pass`, в фазе
  `:choosing_color` — `{:choose_color, color}` (форма — `Rules.decision/0`,
  применяется через `Rules.apply_decision/4`). Вызывается только когда сейчас
  очередь этого бота действовать.
  """
  @spec decide(Rules.projection()) :: Rules.decision()
  def decide(%{phase: :choosing_color, my_hand: hand}) do
    {:choose_color, Rules.auto_color(hand, &hd/1)}
  end

  def decide(%{
        phase: :playing,
        my_hand: hand,
        discard_top: top,
        current_color: color,
        pending: pending
      }) do
    case Enum.filter(hand, &Rules.playable?(&1, top, color)) do
      [] -> if match?({:drew, _}, pending), do: :pass, else: :draw
      playable -> {:play, pick_card(playable)}
    end
  end

  # Бережём чёрные карты: играем цветную/числовую, если есть; Wild/Wild+4 — только
  # когда другого играбельного варианта нет.
  defp pick_card(playable) do
    case Enum.split_with(playable, &wild?/1) do
      {_wilds, [card | _]} -> card
      {[wild | _], []} -> wild
    end
  end

  defp wild?(%{type: type}), do: type in [:wild, :wild_draw_four]
end
