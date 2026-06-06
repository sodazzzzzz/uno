defmodule Uno.Game.StateTest do
  use ExUnit.Case, async: true

  alias Uno.Game.State

  describe "%State{} — дефолты структуры" do
    test "пустая структура имеет канонические значения по умолчанию" do
      assert %State{
               room_code: nil,
               phase: :lobby,
               players: [],
               hands: %{},
               draw_pile: [],
               discard_pile: [],
               current_player: nil,
               direction: :cw,
               current_color: nil,
               pending: nil,
               turn_ref: 0,
               turn_deadline: nil,
               winner: nil
             } = %State{}
    end

    test "набор полей точно соответствует канону §4.1" do
      expected =
        MapSet.new([
          :room_code,
          :phase,
          :players,
          :hands,
          :draw_pile,
          :discard_pile,
          :current_player,
          :direction,
          :current_color,
          :pending,
          :turn_ref,
          :turn_deadline,
          :winner
        ])

      actual = %State{} |> Map.from_struct() |> Map.keys() |> MapSet.new()

      assert actual == expected
    end
  end

  describe "new/2" do
    test "new/1 создаёт лобби с кодом комнаты и дефолтами" do
      state = State.new("ABCD")

      assert state.room_code == "ABCD"
      assert state.phase == :lobby
      assert state.players == []
      assert state.hands == %{}
      assert state.turn_ref == 0
      assert state.direction == :cw
      assert state.winner == nil
    end

    test "сажает игроков в порядке и заводит каждому пустую руку" do
      players = [
        %{id: "p1", name: "Алиса", is_bot: false},
        %{id: "p2", name: "Бот", is_bot: true}
      ]

      state = State.new("ROOM", players)

      assert state.players == players
      assert state.hands == %{"p1" => [], "p2" => []}
      assert state.phase == :lobby
    end
  end

  describe "add_player/2" do
    test "добавляет игрока в конец и заводит пустую руку" do
      state =
        "ROOM"
        |> State.new()
        |> State.add_player(%{id: "p1", name: "Алиса", is_bot: false})
        |> State.add_player(%{id: "p2", name: "Боб", is_bot: false})

      assert Enum.map(state.players, & &1.id) == ["p1", "p2"]
      assert state.hands == %{"p1" => [], "p2" => []}
    end

    test "не затирает уже существующую руку игрока с тем же id" do
      card = %{color: :red, type: {:number, 5}}

      state =
        %State{
          room_code: "ROOM",
          players: [%{id: "p1", name: "Алиса", is_bot: false}],
          hands: %{"p1" => [card]}
        }
        |> State.add_player(%{id: "p1", name: "Алиса", is_bot: false})

      assert state.hands == %{"p1" => [card]}
    end

    test "сохраняет остальные поля состояния без изменений" do
      base = State.new("ROOM")
      next = State.add_player(base, %{id: "p1", name: "Алиса", is_bot: false})

      assert next.room_code == base.room_code
      assert next.phase == base.phase
      assert next.turn_ref == base.turn_ref
      assert next.direction == base.direction
    end
  end
end
