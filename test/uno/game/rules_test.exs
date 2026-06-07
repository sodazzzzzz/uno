defmodule Uno.Game.RulesTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Deck, Rules, State}

  defp player(id, name \\ nil, is_bot \\ false),
    do: %{id: id, name: name || id, is_bot: is_bot}

  defp num(color, n), do: %{color: color, type: {:number, n}}
  defp action(color, type), do: %{color: color, type: type}
  defp wild, do: %{color: nil, type: :wild}
  defp wild4, do: %{color: nil, type: :wild_draw_four}

  # Identity-шафлер: фиксирует порядок перетасовки сброса для детерминизма.
  @identity &Function.identity/1

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

    test "включает публичный ростер (id/имя/бот, в порядке посадки, без рук)" do
      players = [player("p1", "Алиса"), player("bot1", "Лео", true)]
      state = State.new("ROOM", players)

      proj = Rules.project(state, "p1")

      assert proj.players == [
               %{id: "p1", name: "Алиса", is_bot: false},
               %{id: "bot1", name: "Лео", is_bot: true}
             ]
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

  describe "playable?/3 — что можно сыграть" do
    test "по цвету: совпадает с активным цветом" do
      assert Rules.playable?(num(:red, 7), num(:red, 5), :red)
    end

    test "по числу: то же число другого цвета" do
      assert Rules.playable?(num(:blue, 5), num(:red, 5), :red)
    end

    test "по типу акшна: тот же акшн другого цвета" do
      assert Rules.playable?(action(:blue, :skip), action(:red, :skip), :red)
    end

    test "Wild и Wild Draw Four играются всегда" do
      assert Rules.playable?(wild(), num(:red, 5), :red)
      assert Rules.playable?(wild4(), action(:green, :reverse), :green)
    end

    test "не совпало ни по цвету, ни по числу/акшну — нельзя" do
      refute Rules.playable?(num(:blue, 7), num(:red, 5), :red)
      refute Rules.playable?(action(:blue, :skip), num(:red, 5), :red)
    end

    test "цвет сравнивается с current_color, а не с цветом верхней карты (после Wild)" do
      top = wild()
      assert Rules.playable?(num(:green, 3), top, :green)
      refute Rules.playable?(num(:red, 3), top, :green)
    end
  end

  describe "apply_play/3 — применение хода" do
    test "нельзя сыграть не в свой ход" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7)], "p2" => [num(:red, 8)], "p3" => []}
        })

      assert Rules.apply_play(state, "p2", num(:red, 8)) == {:error, :not_your_turn}
    end

    test "нельзя играть вне фазы :playing" do
      state = three_player_state(%{phase: :lobby})
      assert Rules.apply_play(state, "p1", num(:red, 7)) == {:error, :not_playing}
    end

    test "нельзя сыграть карту не из руки" do
      state = three_player_state(%{hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []}})
      assert Rules.apply_play(state, "p1", num(:red, 8)) == {:error, :card_not_in_hand}
    end

    test "нельзя сыграть неподходящую карту" do
      state = three_player_state(%{hands: %{"p1" => [num(:blue, 7)], "p2" => [], "p3" => []}})
      assert Rules.apply_play(state, "p1", num(:blue, 7)) == {:error, :illegal_card}
    end

    test "число: карта в сброс, рука уменьшается, ход к следующему" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7), num(:blue, 1)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_play(state, "p1", num(:red, 7))

      assert s.discard_pile == [num(:red, 7), num(:red, 5)]
      assert s.hands["p1"] == [num(:blue, 1)]
      assert s.current_color == :red
      assert s.current_player == "p2"
      assert s.phase == :playing
    end

    test "Skip: следующий игрок пропускается" do
      state =
        three_player_state(%{
          hands: %{"p1" => [action(:red, :skip), num(:blue, 1)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_play(state, "p1", action(:red, :skip))
      assert s.current_player == "p3"
    end

    test "Reverse при 3 игроках меняет направление" do
      state =
        three_player_state(%{
          hands: %{"p1" => [action(:red, :reverse), num(:blue, 1)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_play(state, "p1", action(:red, :reverse))
      assert s.direction == :ccw
      assert s.current_player == "p3"
    end

    test "Reverse при 2 игроках действует как Skip — ход возвращается к сыгравшему" do
      state =
        struct!(State, %{
          phase: :playing,
          players: [player("p1"), player("p2")],
          hands: %{"p1" => [action(:red, :reverse), num(:blue, 1)], "p2" => []},
          discard_pile: [num(:red, 5)],
          current_player: "p1",
          direction: :cw,
          current_color: :red
        })

      {:ok, s} = Rules.apply_play(state, "p1", action(:red, :reverse))
      assert s.current_player == "p1"
      assert s.direction == :ccw
    end

    test "Draw Two: следующий берёт 2 карты и пропускается" do
      state =
        three_player_state(%{
          hands: %{"p1" => [action(:red, :draw_two), num(:blue, 1)], "p2" => [], "p3" => []},
          draw_pile: [num(:green, 1), num(:green, 2), num(:green, 3)]
        })

      {:ok, s} = Rules.apply_play(state, "p1", action(:red, :draw_two), @identity)

      assert s.hands["p2"] == [num(:green, 1), num(:green, 2)]
      assert s.draw_pile == [num(:green, 3)]
      assert s.current_player == "p3"
    end

    test "Wild: переход в :choosing_color, ход не передаётся, цвет пока прежний" do
      state =
        three_player_state(%{hands: %{"p1" => [wild(), num(:blue, 1)], "p2" => [], "p3" => []}})

      {:ok, s} = Rules.apply_play(state, "p1", wild())

      assert s.phase == :choosing_color
      assert s.pending == {:choose_color, "p1"}
      assert s.current_player == "p1"
      assert s.current_color == :red
      assert s.discard_pile == [wild(), num(:red, 5)]
    end

    test "Wild Draw Four: тоже переход в :choosing_color (добор 4 — позже)" do
      state =
        three_player_state(%{hands: %{"p1" => [wild4(), num(:blue, 1)], "p2" => [], "p3" => []}})

      {:ok, s} = Rules.apply_play(state, "p1", wild4())

      assert s.phase == :choosing_color
      assert s.pending == {:choose_color, "p1"}
      assert s.current_player == "p1"
    end

    test "победа: пустая рука после хода → winner и :finished" do
      state = three_player_state(%{hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []}})

      {:ok, s} = Rules.apply_play(state, "p1", num(:red, 7))

      assert s.phase == :finished
      assert s.winner == "p1"
      assert s.hands["p1"] == []
    end

    test "победа имеет приоритет: Wild последней картой → :finished, а не :choosing_color" do
      state = three_player_state(%{hands: %{"p1" => [wild()], "p2" => [], "p3" => []}})

      {:ok, s} = Rules.apply_play(state, "p1", wild())

      assert s.phase == :finished
      assert s.winner == "p1"
      assert s.pending == nil
    end
  end

  describe "apply_draw/2 — добор карты" do
    test "нельзя добирать не в свой ход" do
      state = three_player_state(%{draw_pile: [num(:green, 1)]})
      assert Rules.apply_draw(state, "p2") == {:error, :not_your_turn}
    end

    test "нельзя добирать вне фазы :playing" do
      state = three_player_state(%{phase: :finished, draw_pile: [num(:green, 1)]})
      assert Rules.apply_draw(state, "p1") == {:error, :not_playing}
    end

    test "добор 1 карты: рука растёт, ход остаётся за игроком" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []},
          draw_pile: [num(:green, 1), num(:green, 2)]
        })

      {:ok, s} = Rules.apply_draw(state, "p1", @identity)

      assert s.hands["p1"] == [num(:red, 7), num(:green, 1)]
      assert s.draw_pile == [num(:green, 2)]
      assert s.current_player == "p1"
    end

    test "добор при пустой колоде перетасовывает сброс (кроме верха)" do
      state =
        three_player_state(%{
          hands: %{"p1" => [], "p2" => [], "p3" => []},
          draw_pile: [],
          discard_pile: [num(:red, 5), num(:blue, 2), num(:green, 3)]
        })

      {:ok, s} = Rules.apply_draw(state, "p1", @identity)

      assert s.hands["p1"] == [num(:blue, 2)]
      assert s.discard_pile == [num(:red, 5)]
      assert s.draw_pile == [num(:green, 3)]
      assert s.current_player == "p1"
    end

    test "тянуть нечего даже после перетасовки — ход переходит без добора, метки нет" do
      state =
        three_player_state(%{
          hands: %{"p1" => [], "p2" => [], "p3" => []},
          draw_pile: [],
          discard_pile: [num(:red, 5)]
        })

      {:ok, s} = Rules.apply_draw(state, "p1", @identity)

      assert s.hands["p1"] == []
      assert s.current_player == "p2"
      assert s.pending == nil
    end

    test "добор ставит метку {:drew}; второй добор за ход запрещён" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []},
          draw_pile: [num(:green, 1), num(:green, 2)]
        })

      {:ok, s} = Rules.apply_draw(state, "p1", @identity)
      assert s.pending == {:drew, "p1"}
      assert s.current_player == "p1"

      assert Rules.apply_draw(s, "p1", @identity) == {:error, :already_drew}
    end
  end

  describe "pass/2 — пас после добора" do
    test "после добора пас передаёт ход и снимает метку" do
      state =
        three_player_state(%{
          pending: {:drew, "p1"},
          hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.pass(state, "p1")

      assert s.current_player == "p2"
      assert s.pending == nil
    end

    test "пас без добора нельзя" do
      assert Rules.pass(three_player_state(%{}), "p1") == {:error, :nothing_to_pass}
    end

    test "нельзя пасовать в чужой ход" do
      assert Rules.pass(three_player_state(%{}), "p2") == {:error, :not_your_turn}
    end

    test "нельзя пасовать вне фазы :playing" do
      assert Rules.pass(three_player_state(%{phase: :finished}), "p1") == {:error, :not_playing}
    end

    test "после добора можно сыграть любую подходящую карту — розыгрыш снимает метку" do
      state =
        three_player_state(%{
          pending: {:drew, "p1"},
          hands: %{"p1" => [num(:red, 7), num(:blue, 1)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_play(state, "p1", num(:red, 7))

      assert s.pending == nil
      assert s.current_player == "p2"
    end
  end

  describe "choose_color/3 — выбор цвета после Wild/Wild+4" do
    test "Wild меняет current_color и передаёт ход следующему" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)]
        })

      {:ok, s} = Rules.choose_color(state, "p1", :blue)

      assert s.current_color == :blue
      assert s.phase == :playing
      assert s.pending == nil
      assert s.current_player == "p2"
    end

    test "полный флоу: apply_play(Wild) → choose_color" do
      state =
        three_player_state(%{hands: %{"p1" => [wild(), num(:blue, 1)], "p2" => [], "p3" => []}})

      {:ok, mid} = Rules.apply_play(state, "p1", wild())
      assert mid.phase == :choosing_color

      {:ok, s} = Rules.choose_color(mid, "p1", :green)
      assert s.current_color == :green
      assert s.phase == :playing
      assert s.current_player == "p2"
    end

    test "Wild Draw Four: следующий берёт 4 карты и пропускается" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild4(), num(:red, 5)],
          draw_pile: [
            num(:green, 1),
            num(:green, 2),
            num(:green, 3),
            num(:green, 4),
            num(:green, 5)
          ]
        })

      {:ok, s} = Rules.choose_color(state, "p1", :yellow, @identity)

      assert s.current_color == :yellow
      assert s.phase == :playing
      assert s.hands["p2"] == [num(:green, 1), num(:green, 2), num(:green, 3), num(:green, 4)]
      assert s.draw_pile == [num(:green, 5)]
      assert s.current_player == "p3"
    end

    test "нельзя выбирать цвет не за того игрока" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)]
        })

      assert Rules.choose_color(state, "p2", :blue) == {:error, :not_your_choice}
    end

    test "нельзя выбрать недопустимый цвет" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)]
        })

      assert Rules.choose_color(state, "p1", :rainbow) == {:error, :invalid_color}
    end

    test "нельзя выбирать цвет вне фазы :choosing_color" do
      state = three_player_state(%{})
      assert Rules.choose_color(state, "p1", :blue) == {:error, :not_choosing_color}
    end
  end

  describe "auto_color/2 — цвет по большинству для таймаута" do
    test "выбирает цвет большинства в руке" do
      assert Rules.auto_color([num(:red, 1), num(:red, 2), num(:blue, 3)]) == :red
    end

    test "Wild и Wild Draw Four не учитываются" do
      assert Rules.auto_color([num(:red, 1), wild(), wild4()]) == :red
    end

    test "при равенстве выбирает из лидеров (детерминированно через инъекцию)" do
      hand = [num(:red, 1), num(:blue, 2)]
      # Лидеры отсортированы: [:blue, :red].
      assert Rules.auto_color(hand, &hd/1) == :blue
      assert Rules.auto_color(hand, &List.last/1) == :red
    end

    test "нет цветных карт — случайный из всех четырёх цветов" do
      chooser = fn candidates ->
        assert Enum.sort(candidates) == [:blue, :green, :red, :yellow]
        :green
      end

      assert Rules.auto_color([wild(), wild4()], chooser) == :green
    end
  end

  describe "auto_choose_color/3 — резолв таймаута :choosing_color" do
    test "выбирает большинство и применяет как обычный выбор (Wild → ход следующему)" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)],
          hands: %{"p1" => [num(:red, 1), num(:red, 2), num(:blue, 3)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.auto_choose_color(state)

      assert s.current_color == :red
      assert s.phase == :playing
      assert s.current_player == "p2"
    end

    test "Wild Draw Four: авто-цвет + следующий берёт 4 и пропускается" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild4(), num(:red, 5)],
          hands: %{"p1" => [num(:green, 1), num(:green, 2)], "p2" => [], "p3" => []},
          draw_pile: [num(:red, 1), num(:red, 2), num(:red, 3), num(:red, 4), num(:red, 5)]
        })

      {:ok, s} = Rules.auto_choose_color(state, &hd/1, @identity)

      assert s.current_color == :green
      assert length(s.hands["p2"]) == 4
      assert s.current_player == "p3"
    end

    test "вне фазы :choosing_color — ошибка" do
      assert Rules.auto_choose_color(three_player_state(%{})) == {:error, :not_choosing_color}
    end
  end

  describe "apply_timeout/3 — авто-действие при таймауте" do
    test ":playing — текущий игрок добирает 1 карту и ход переходит дальше" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []},
          draw_pile: [num(:green, 1), num(:green, 2)]
        })

      {:ok, s} = Rules.apply_timeout(state, &hd/1, @identity)

      assert s.hands["p1"] == [num(:red, 7), num(:green, 1)]
      assert s.current_player == "p2"
      assert s.pending == nil
    end

    test ":playing — если игрок уже добрал в этот ход, таймаут просто пасует (без второго добора)" do
      state =
        three_player_state(%{
          current_player: "p1",
          pending: {:drew, "p1"},
          hands: %{"p1" => [num(:red, 7)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_timeout(state, &hd/1, @identity)

      assert s.current_player == "p2"
      assert s.pending == nil
      # Рука не растёт — второго добора за ход нет.
      assert s.hands["p1"] == [num(:red, 7)]
    end

    test ":choosing_color — цвет выбирается по большинству, ход переходит" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)],
          hands: %{"p1" => [num(:blue, 1), num(:blue, 2)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_timeout(state, &hd/1, @identity)

      assert s.current_color == :blue
      assert s.phase == :playing
      assert s.current_player == "p2"
    end
  end

  describe "apply_decision/4 — диспетчер решения хода" do
    test "{:play, card} играет карту" do
      state =
        three_player_state(%{
          hands: %{"p1" => [num(:red, 7), num(:blue, 1)], "p2" => [], "p3" => []}
        })

      {:ok, s} = Rules.apply_decision(state, "p1", {:play, num(:red, 7)})

      assert s.discard_pile == [num(:red, 7), num(:red, 5)]
      assert s.current_player == "p2"
    end

    test ":draw добирает карту" do
      state =
        three_player_state(%{
          hands: %{"p1" => [], "p2" => [], "p3" => []},
          draw_pile: [num(:green, 1)]
        })

      {:ok, s} = Rules.apply_decision(state, "p1", :draw, @identity)

      assert s.hands["p1"] == [num(:green, 1)]
      assert s.pending == {:drew, "p1"}
    end

    test ":pass пасует после добора" do
      state = three_player_state(%{pending: {:drew, "p1"}})
      {:ok, s} = Rules.apply_decision(state, "p1", :pass)
      assert s.current_player == "p2"
    end

    test "{:choose_color, color} выбирает цвет" do
      state =
        three_player_state(%{
          phase: :choosing_color,
          pending: {:choose_color, "p1"},
          discard_pile: [wild(), num(:red, 5)]
        })

      {:ok, s} = Rules.apply_decision(state, "p1", {:choose_color, :blue})

      assert s.current_color == :blue
      assert s.phase == :playing
    end

    test "ошибка правила прокидывается (нелегальный ход)" do
      state =
        three_player_state(%{hands: %{"p1" => [num(:blue, 9)], "p2" => [], "p3" => []}})

      assert Rules.apply_decision(state, "p1", {:play, num(:blue, 9)}) == {:error, :illegal_card}
    end
  end

  # 3-игроковое состояние партии в фазе :playing; overrides переопределяют поля.
  defp three_player_state(overrides) do
    defaults = %{
      phase: :playing,
      players: [player("p1"), player("p2"), player("p3")],
      hands: %{"p1" => [], "p2" => [], "p3" => []},
      draw_pile: [],
      discard_pile: [num(:red, 5)],
      current_player: "p1",
      direction: :cw,
      current_color: :red
    }

    struct!(State, Map.merge(defaults, Map.new(overrides)))
  end
end
