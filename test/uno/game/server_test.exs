defmodule Uno.Game.ServerTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Manager, Server}

  defp unique_code, do: "room-#{System.unique_integer([:positive])}"
  defp player(id, is_bot \\ false), do: %{id: id, name: id, is_bot: is_bot}

  # Партия в лобби с заданными игроками; гасится по завершении теста.
  # opts прокидываются в Server (напр. turn_ms для таймера).
  defp lobby(players, opts \\ []) do
    code = unique_code()
    {:ok, _pid} = Manager.create(code, Keyword.put(opts, :players, players))
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
    test "вход игрока (add_player) шлёт broadcast — комната ожидания обновляется" do
      code = lobby([player("p1")])
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert {:ok, _roster} = Server.add_player(code, player("p2"))
      assert_receive {:game_update, ^code}
    end

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

  describe "таймер хода (turn_ref-схема §4.3)" do
    test "успешное действие взводит таймер: turn_ref >= 1 и выставлен turn_deadline" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)

      state = Server.state(code)
      assert state.turn_ref >= 1
      assert is_integer(state.turn_deadline)
    end

    test "ТЕСТ ГОНКИ: протухший {:turn_timeout, old_ref} безвреден" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      {:ok, pid} = Manager.find(code)
      before = Server.state(code)

      # ref 0 — стартовый, до первого взвода; заведомо протухший.
      send(pid, {:turn_timeout, 0})

      # Следующий call обработается ПОСЛЕ info (мейлбокс FIFO) — значит info отработал.
      after_state = Server.state(code)

      assert after_state.turn_ref == before.turn_ref
      assert after_state.current_player == before.current_player
      assert after_state.hands == before.hands
    end

    test "таймаут с текущим ref применяет авто-действие: добор 1 + передача хода" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      {:ok, pid} = Manager.find(code)
      before = Server.state(code)

      send(pid, {:turn_timeout, before.turn_ref})
      after_state = Server.state(code)

      assert length(after_state.hands["p1"]) == 8
      assert after_state.current_player == "p2"
      assert after_state.turn_ref == before.turn_ref + 1
    end

    test "таймаут ПОСЛЕ добора не роняет сервер — ход просто переходит" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      {:ok, pid} = Manager.find(code)

      # p1 добрал → pending {:drew, p1}, таймер перевзведён под актуальный ref.
      :ok = Server.draw(code, "p1")
      ref = Server.state(code).turn_ref

      send(pid, {:turn_timeout, ref})
      after_state = Server.state(code)

      assert Process.alive?(pid)
      assert after_state.current_player == "p2"
      assert after_state.pending == nil
    end

    test "живой таймаут реально срабатывает (send_after end-to-end)" do
      code = lobby([player("p1"), player("p2")], turn_ms: 40)
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.start_game(code)
      assert_receive {:game_update, ^code}

      # Никто не ходит → таймер хода срабатывает → авто-действие шлёт ещё broadcast.
      assert_receive {:game_update, ^code}, 1000
    end
  end

  describe "автоход ботов" do
    test "бот ходит сам и в итоге передаёт ход человеку" do
      code = lobby([player("bot", true), player("human", false)], bot_delay: 5)
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      # Раздача → ходит бот (первый посаженный) → автоход без участия клиента.
      assert :ok = Server.start_game(code)
      assert_receive {:game_update, ^code}

      await_current(code, "human")
      assert Server.state(code).current_player == "human"
    end

    test "ход человека НЕ запускает автоход" do
      code = lobby([player("human", false), player("bot", true)], bot_delay: 5)
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.start_game(code)
      assert_receive {:game_update, ^code}

      # Ходит человек — сервер сам ничего не двигает.
      refute_receive {:game_update, ^code}, 100
      assert Server.state(code).current_player == "human"
    end
  end

  describe "готовность (set_ready) и авто-старт" do
    test "партия стартует, когда все реальные игроки готовы (бот всегда готов)" do
      code = lobby([player("p1"), player("bot1", true)])
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.set_ready(code, "p1", true)

      assert_receive {:game_update, ^code}
      assert Server.state(code).phase == :playing
    end

    test "пока не все реальные готовы — лобби; готовность ставится и снимается" do
      code = lobby([player("p1"), player("p2")])

      assert :ok = Server.set_ready(code, "p1", true)
      state = Server.state(code)
      assert state.phase == :lobby
      assert "p1" in state.ready

      assert :ok = Server.set_ready(code, "p1", false)
      refute "p1" in Server.state(code).ready
    end

    test "готов соло-хост, затем добавлен бот → авто-старт (находка ревью)" do
      code = lobby([player("p1")])

      assert :ok = Server.set_ready(code, "p1", true)
      # Один игрок < 2 — партия ещё в лобби.
      assert Server.state(code).phase == :lobby

      assert {:ok, _roster} = Server.add_player(code, player("bot1", true))

      # Добор бота завершил готовность (хост готов, бот всегда) + 2 игрока → старт.
      assert Server.state(code).phase == :playing
    end
  end

  # Ждёт, пока ход дойдёт до игрока `id` (получая broadcast'ы шагов бота).
  defp await_current(code, id) do
    receive do
      {:game_update, ^code} ->
        unless Server.state(code).current_player == id, do: await_current(code, id)
    after
      2000 -> flunk("ход не дошёл до #{id} за 2с")
    end
  end
end
