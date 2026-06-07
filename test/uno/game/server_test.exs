defmodule Uno.Game.ServerTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Manager, Server}

  defp unique_code, do: "room-#{System.unique_integer([:positive])}"
  defp player(id), do: %{id: id, name: id, is_bot: false}

  # Партия в лобби с заданными игроками; гасится по завершении теста.
  defp lobby(players) do
    code = unique_code()
    {:ok, _pid} = Manager.create(code, players: players)
    on_exit(fn -> Manager.stop(code) end)
    code
  end

  describe "start_game/1" do
    test "раздаёт по 7 карт, кладёт числовой верх и переходит в :playing" do
      code = lobby([player("p1"), player("p2")])

      assert :ok = Server.start_game(code)

      state = Server.state(code)
      assert state.phase == :playing
      assert length(state.hands["p1"]) == 7
      assert length(state.hands["p2"]) == 7
      assert [%{type: {:number, _}}] = state.discard_pile
      assert state.current_player == "p1"
    end

    test "меньше двух игроков — :not_enough_players" do
      code = lobby([player("p1")])
      assert Server.start_game(code) == {:error, :not_enough_players}
    end

    test "повторный старт — :already_started" do
      code = lobby([player("p1"), player("p2")])
      assert :ok = Server.start_game(code)
      assert Server.start_game(code) == {:error, :already_started}
    end
  end

  describe "действия игроков делегируются в Rules" do
    test "ход не своего игрока отклоняется" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)

      # Ходит p1 (первый посаженный).
      assert Server.draw(code, "p2") == {:error, :not_your_turn}

      assert Server.play(code, "p2", %{color: :red, type: {:number, 5}}) ==
               {:error, :not_your_turn}
    end

    test "пас после добора передаёт ход" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)

      assert :ok = Server.draw(code, "p1")
      assert Server.state(code).pending == {:drew, "p1"}

      assert :ok = Server.pass(code, "p1")
      state = Server.state(code)
      assert state.current_player == "p2"
      assert state.pending == nil
    end
  end

  describe "broadcast обновлений" do
    test "успешные изменения шлют {:game_update, room_code} в топик партии" do
      code = lobby([player("p1"), player("p2")])
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.start_game(code)
      assert_receive {:game_update, ^code}

      assert :ok = Server.draw(code, "p1")
      assert_receive {:game_update, ^code}
    end

    test "отказ хода не шлёт broadcast" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert Server.draw(code, "p2") == {:error, :not_your_turn}
      refute_receive {:game_update, ^code}
    end
  end
end
