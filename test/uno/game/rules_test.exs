defmodule Uno.Game.RulesTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Deck, Rules, State}

  defp player(id, name \\ nil, is_bot \\ false),
    do: %{id: id, name: name || id, is_bot: is_bot}

  describe "deal/2 — старт партии" do
    test "раздаёт по 7 карт каждому, верх сброса — числовая карта, ходит первый игрок" do
      players = [player("p1"), player("p2"), player("p3")]
      deck = Deck.shuffle(Deck.new(), 123)

      state = "ROOM" |> State.new(players) |> Rules.deal(deck)

      assert state.phase == :playing
      assert state.current_player == "p1"
      assert state.direction == :cw
      assert state.pending == nil
      assert state.winner == nil

      for id <- ["p1", "p2", "p3"] do
        assert length(state.hands[id]) == 7
      end

      assert [%{type: {:number, _}, color: color}] = state.discard_pile
      assert color != nil
      assert state.current_color == color
    end

    test "сохраняет всё мультимножество карт (ничего не теряется и не дублируется)" do
      players = [player("p1"), player("p2"), player("p3")]
      deck = Deck.shuffle(Deck.new(), 7)

      state = "ROOM" |> State.new(players) |> Rules.deal(deck)

      dealt = Enum.flat_map(state.hands, fn {_id, cards} -> cards end)
      all = dealt ++ state.draw_pile ++ state.discard_pile

      assert length(all) == 108
      # 108 - 21 в руках - 1 в сбросе.
      assert length(state.draw_pile) == 86
      assert Enum.sort(all) == Enum.sort(deck)
    end

    test "не-числовой верх колоды прокручивается в низ, пока не выпадет числовая" do
      players = [player("p1"), player("p2")]

      # 14 карт в руки (red 0..6, затем blue 0..6), затем хвост колоды.
      hand_cards = for color <- [:red, :blue], n <- 0..6, do: %{color: color, type: {:number, n}}

      tail = [
        %{color: nil, type: :wild},
        %{color: :yellow, type: :skip},
        %{color: :green, type: {:number, 7}},
        %{color: :red, type: {:number, 8}},
        %{color: :blue, type: {:number, 9}}
      ]

      state = "ROOM" |> State.new(players) |> Rules.deal(hand_cards ++ tail)

      # Руки — ровно первые 7 и следующие 7 карт колоды.
      assert state.hands["p1"] == Enum.take(hand_cards, 7)
      assert state.hands["p2"] == Enum.drop(hand_cards, 7)

      # Стартовая карта — первая числовая в хвосте (green 7), Wild и Skip пропущены.
      assert state.discard_pile == [%{color: :green, type: {:number, 7}}]
      assert state.current_color == :green

      # Остаток колоды: то, что после стартовой, а пропущенные не-числовые — в низ
      # с сохранением их порядка.
      assert state.draw_pile == [
               %{color: :red, type: {:number, 8}},
               %{color: :blue, type: {:number, 9}},
               %{color: nil, type: :wild},
               %{color: :yellow, type: :skip}
             ]
    end

    test "падает с понятным сообщением, если в колоде нет числовой карты для старта" do
      players = [player("p1"), player("p2")]
      hand_cards = for color <- [:red, :blue], n <- 0..6, do: %{color: color, type: {:number, n}}

      # После раздачи в остатке только акшн-карты — стартовой числовой нет.
      deck = hand_cards ++ [%{color: :red, type: :skip}, %{color: :blue, type: :reverse}]

      assert_raise ArgumentError, ~r/числовой карты/, fn ->
        "ROOM" |> State.new(players) |> Rules.deal(deck)
      end
    end

    test "не матчит колоду, которой не хватает на полную раздачу + старт" do
      players = [player("p1"), player("p2")]

      # Нужно > 2*7 = 14 карт; даём ровно 14 — на стартовую не остаётся.
      deck = for color <- [:red, :blue], n <- 0..6, do: %{color: color, type: {:number, n}}

      assert_raise FunctionClauseError, fn ->
        "ROOM" |> State.new(players) |> Rules.deal(deck)
      end
    end
  end

  describe "next_player/1 — следующий игрок по направлению" do
    setup do
      %{players: [player("p1"), player("p2"), player("p3")]}
    end

    test "cw — шаг вперёд по списку посадки", %{players: players} do
      assert Rules.next_player(state(players, "p1", :cw)) == "p2"
      assert Rules.next_player(state(players, "p2", :cw)) == "p3"
    end

    test "cw — заворачивает с последнего на первого", %{players: players} do
      assert Rules.next_player(state(players, "p3", :cw)) == "p1"
    end

    test "ccw — шаг назад по списку посадки", %{players: players} do
      assert Rules.next_player(state(players, "p2", :ccw)) == "p1"
      assert Rules.next_player(state(players, "p3", :ccw)) == "p2"
    end

    test "ccw — заворачивает с первого на последнего", %{players: players} do
      assert Rules.next_player(state(players, "p1", :ccw)) == "p3"
    end

    test "при двух игроках следующий — всегда соперник, независимо от направления" do
      players = [player("p1"), player("p2")]

      assert Rules.next_player(state(players, "p1", :cw)) == "p2"
      assert Rules.next_player(state(players, "p1", :ccw)) == "p2"
      assert Rules.next_player(state(players, "p2", :cw)) == "p1"
    end

    defp state(players, current, direction) do
      %State{players: players, current_player: current, direction: direction}
    end
  end

  describe "project/2 — проекция со скрытием чужих рук" do
    setup do
      players = [player("p1", "Алиса"), player("p2", "Боб"), player("p3", "Влад")]

      state = %State{
        room_code: "ROOM",
        phase: :playing,
        players: players,
        hands: %{
          "p1" => [%{color: :red, type: {:number, 1}}, %{color: :blue, type: :skip}],
          "p2" => [%{color: :green, type: {:number, 2}}, %{color: :yellow, type: :reverse}],
          "p3" => [%{color: nil, type: :wild}]
        },
        draw_pile: [%{color: :red, type: {:number, 9}}],
        discard_pile: [%{color: :red, type: {:number, 5}}, %{color: :blue, type: {:number, 3}}],
        current_player: "p2",
        direction: :ccw,
        current_color: :red,
        pending: {:choose_color, "p2"},
        turn_deadline: 123_456,
        winner: nil
      }

      %{state: state}
    end

    test "своя рука уходит целиком", %{state: state} do
      proj = Rules.project(state, "p1")
      assert proj.my_hand == [%{color: :red, type: {:number, 1}}, %{color: :blue, type: :skip}]
    end

    test "у соперников видно только число карт — сами карты не утекают", %{state: state} do
      proj = Rules.project(state, "p1")

      assert proj.others == [
               %{id: "p2", name: "Боб", card_count: 2},
               %{id: "p3", name: "Влад", card_count: 1}
             ]

      # Инвариант скрытого состояния: у записей соперников нет ничего, кроме
      # id/name/card_count — никаких списков карт.
      assert Enum.all?(proj.others, fn o ->
               Enum.sort(Map.keys(o)) == [:card_count, :id, :name]
             end)
    end

    test "отдаёт верх сброса, активный цвет, чей ход, направление, фазу, pending, дедлайн",
         %{state: state} do
      proj = Rules.project(state, "p1")

      assert proj.discard_top == %{color: :red, type: {:number, 5}}
      assert proj.current_color == :red
      assert proj.whose_turn == "p2"
      assert proj.direction == :ccw
      assert proj.phase == :playing
      assert proj.pending == {:choose_color, "p2"}
      assert proj.turn_deadline == 123_456
      assert proj.winner == nil
    end

    test "в лобби (карт ещё нет) проекция не падает: верх сброса nil, руки пустые" do
      players = [player("p1"), player("p2")]
      state = State.new("ROOM", players)

      proj = Rules.project(state, "p1")

      assert proj.my_hand == []
      assert proj.others == [%{id: "p2", name: "p2", card_count: 0}]
      assert proj.discard_top == nil
      assert proj.phase == :lobby
    end

    test "для неизвестного игрока своя рука пуста, но соперники видны" do
      players = [player("p1"), player("p2")]
      state = %State{players: players, hands: %{"p1" => [%{color: :red, type: {:number, 0}}]}}

      proj = Rules.project(state, "stranger")

      assert proj.my_hand == []

      assert proj.others == [
               %{id: "p1", name: "p1", card_count: 1},
               %{id: "p2", name: "p2", card_count: 0}
             ]
    end
  end
end
