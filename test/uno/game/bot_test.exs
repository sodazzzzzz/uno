defmodule Uno.Game.BotTest do
  use ExUnit.Case, async: true

  alias Uno.Game.Bot

  defp num(color, n), do: %{color: color, type: {:number, n}}
  defp wild, do: %{color: nil, type: :wild}
  defp wild4, do: %{color: nil, type: :wild_draw_four}

  # Проекция в фазе :playing; overrides переопределяют поля.
  defp playing_view(overrides) do
    Map.merge(
      %{
        phase: :playing,
        my_hand: [],
        discard_top: num(:red, 3),
        current_color: :red,
        pending: nil
      },
      overrides
    )
  end

  describe "decide/1 — фаза :playing" do
    test "играет цветную/числовую раньше Wild (бережёт чёрные карты)" do
      view = playing_view(%{my_hand: [wild(), num(:red, 5)]})
      assert Bot.decide(view) == {:play, num(:red, 5)}
    end

    test "играет первую играбельную цветную из нескольких" do
      # blue 9 не подходит (цвет blue, число 9 != 3); играбельны red 5 и red 7.
      view = playing_view(%{my_hand: [num(:blue, 9), num(:red, 5), num(:red, 7)]})
      assert Bot.decide(view) == {:play, num(:red, 5)}
    end

    test "играет Wild, когда подходит только он" do
      view = playing_view(%{my_hand: [wild(), num(:blue, 9)]})
      assert Bot.decide(view) == {:play, wild()}
    end

    test "нет играбельной карты и добора ещё не было — берёт карту" do
      view = playing_view(%{my_hand: [num(:blue, 9)], pending: nil})
      assert Bot.decide(view) == :draw
    end

    test "нет играбельной карты, но карту уже брали — пасует" do
      view = playing_view(%{my_hand: [num(:blue, 9)], pending: {:drew, "bot"}})
      assert Bot.decide(view) == :pass
    end

    test "добрал и появилась играбельная карта — играет её" do
      view = playing_view(%{my_hand: [num(:red, 5)], pending: {:drew, "bot"}})
      assert Bot.decide(view) == {:play, num(:red, 5)}
    end
  end

  describe "decide/1 — фаза :choosing_color" do
    test "выбирает цвет, которого в руке больше всего" do
      view = %{phase: :choosing_color, my_hand: [num(:red, 1), num(:red, 2), num(:blue, 3)]}
      assert Bot.decide(view) == {:choose_color, :red}
    end

    test "только Wild в руке — всё равно выбирает валидный цвет" do
      view = %{phase: :choosing_color, my_hand: [wild(), wild4()]}
      assert {:choose_color, color} = Bot.decide(view)
      assert color in [:red, :yellow, :green, :blue]
    end
  end
end
