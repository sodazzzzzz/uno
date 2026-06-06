defmodule Uno.Game.DeckTest do
  use ExUnit.Case, async: true

  alias Uno.Game.Deck

  describe "new/0 — состав колоды" do
    setup do
      %{deck: Deck.new()}
    end

    test "ровно 108 карт", %{deck: deck} do
      assert length(deck) == 108
    end

    test "100 цветных и 8 чёрных (wild)", %{deck: deck} do
      colored = Enum.filter(deck, &(&1.color != nil))
      black = Enum.filter(deck, &(&1.color == nil))

      assert length(colored) == 100
      assert length(black) == 8
    end

    test "4 Wild и 4 Wild Draw Four", %{deck: deck} do
      assert count(deck, %{color: nil, type: :wild}) == 4
      assert count(deck, %{color: nil, type: :wild_draw_four}) == 4
    end

    test "в каждом цвете: одна 0, по две 1..9, по две Skip/Reverse/Draw Two", %{deck: deck} do
      for color <- [:red, :yellow, :green, :blue] do
        assert count(deck, %{color: color, type: {:number, 0}}) == 1

        for n <- 1..9 do
          assert count(deck, %{color: color, type: {:number, n}}) == 2
        end

        for type <- [:skip, :reverse, :draw_two] do
          assert count(deck, %{color: color, type: type}) == 2
        end
      end
    end

    test "по 25 карт каждого цвета", %{deck: deck} do
      for color <- [:red, :yellow, :green, :blue] do
        assert Enum.count(deck, &(&1.color == color)) == 25
      end
    end

    test "детерминирована — два вызова дают одинаковый порядок" do
      assert Deck.new() == Deck.new()
    end
  end

  describe "shuffle/2 — детерминированное тасование по seed" do
    test "один seed → один и тот же порядок" do
      deck = Deck.new()
      assert Deck.shuffle(deck, 42) == Deck.shuffle(deck, 42)
    end

    test "разные seed → разный порядок" do
      deck = Deck.new()
      refute Deck.shuffle(deck, 1) == Deck.shuffle(deck, 2)
    end

    test "тасование переставляет, но сохраняет мультимножество карт" do
      deck = Deck.new()
      shuffled = Deck.shuffle(deck, 7)

      assert length(shuffled) == 108
      assert Enum.sort(shuffled) == Enum.sort(deck)

      # На практике перестановка 108 карт почти наверняка отличается от исходной.
      refute shuffled == deck
    end

    test "принимает кортеж-seed для :rand" do
      deck = Deck.new()
      assert Deck.shuffle(deck, {1, 2, 3}) == Deck.shuffle(deck, {1, 2, 3})
    end
  end

  describe "shuffle/1 — продакшн-тасование" do
    test "сохраняет мультимножество карт" do
      deck = Deck.new()
      shuffled = Deck.shuffle(deck)

      assert length(shuffled) == 108
      assert Enum.sort(shuffled) == Enum.sort(deck)
    end
  end

  describe "take/2 — примитив добора" do
    test "снимает n карт с верха и возвращает остаток" do
      pile = [:a, :b, :c, :d]
      assert Deck.take(pile, 2) == {[:a, :b], [:c, :d]}
    end

    test "take 0 — ничего не берёт" do
      assert Deck.take([:a, :b], 0) == {[], [:a, :b]}
    end

    test "просьба больше, чем есть — берёт всё, остаток пуст" do
      assert Deck.take([:a, :b], 5) == {[:a, :b], []}
    end

    test "из пустой колоды — пусто" do
      assert Deck.take([], 3) == {[], []}
    end
  end

  describe "draw/4 — добор с перетасовкой сброса" do
    # Детерминизм: инъектируем шафлер-identity, чтобы знать точный порядок.
    @identity &Function.identity/1

    test "обычный добор — хватает колоды, сброс не трогаем" do
      draw_pile = [:a, :b, :c]
      discard = [:top, :x, :y]

      assert Deck.draw(draw_pile, discard, 2, @identity) == {[:a, :b], [:c], [:top, :x, :y]}
    end

    test "колода опустела — перетасовываем сброс (кроме верхней карты) и добираем" do
      draw_pile = [:a]
      discard = [:top, :x, :y, :z]

      {drawn, new_draw, new_discard} = Deck.draw(draw_pile, discard, 3, @identity)

      # Берём :a из колоды, затем из перетасованного [:x,:y,:z] (identity → тот же порядок).
      assert drawn == [:a, :x, :y]
      assert new_draw == [:z]
      # Верхняя карта сброса остаётся видимой.
      assert new_discard == [:top]
    end

    test "колода пуста, в сбросе только верхняя карта — тянуть нечего" do
      assert Deck.draw([], [:top], 2, @identity) == {[], [], [:top]}
    end

    test "колода и сброс пусты — добора нет" do
      assert Deck.draw([], [], 1, @identity) == {[], [], []}
    end

    test "после перетасовки всё равно не хватает — отдаём сколько есть" do
      # В колоде 0, в сбросе кроме верха только 1 карта, просим 3.
      assert Deck.draw([], [:top, :only], 3, @identity) == {[:only], [], [:top]}
    end

    test "сохраняет общее число карт (ничего не теряется и не создаётся)" do
      draw_pile = [:a, :b]
      discard = [:top, :x, :y, :z, :w]

      {drawn, new_draw, new_discard} = Deck.draw(draw_pile, discard, 4, @identity)

      before = MapSet.new(draw_pile ++ discard)
      after_all = MapSet.new(drawn ++ new_draw ++ new_discard)

      assert length(drawn ++ new_draw ++ new_discard) == length(draw_pile ++ discard)
      assert before == after_all
    end

    test "добор 0 карт — ничего не меняет" do
      assert Deck.draw([:a, :b], [:top], 0, @identity) == {[], [:a, :b], [:top]}
    end
  end

  # Считает, сколько раз карта `card` встречается в колоде `deck`.
  defp count(deck, card), do: Enum.count(deck, &(&1 == card))
end
