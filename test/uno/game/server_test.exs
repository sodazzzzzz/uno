defmodule Uno.Game.ServerTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Manager, Server, State}

  defp unique_code, do: "room-#{System.unique_integer([:positive])}"
  defp player(id, is_bot \\ false), do: %{id: id, name: id, is_bot: is_bot}
  defp num(color, n), do: %{color: color, type: {:number, n}}

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

  describe "restart/1 — переигровка" do
    # Засеваем готовую :finished-партию через опцию :game (turn_ref ненулевой —
    # проверяем его сохранение при сбросе).
    defp finished_room(players, winner) do
      code = unique_code()

      game = %State{
        room_code: code,
        phase: :finished,
        players: players,
        hands: Map.new(players, &{&1.id, [num(:red, 1)]}),
        discard_pile: [num(:red, 5)],
        current_color: :red,
        turn_ref: 7,
        winner: winner
      }

      {:ok, _pid} = Manager.create(code, players: players, game: game)
      on_exit(fn -> Manager.stop(code) end)
      code
    end

    test "из :finished сбрасывает в комнату ожидания тем же составом и шлёт broadcast" do
      players = [player("p1"), player("p2")]
      code = finished_room(players, "p1")
      Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.restart(code)

      assert_receive {:game_update, ^code}
      state = Server.state(code)
      assert state.phase == :lobby
      assert state.players == players
      assert state.winner == nil
      assert state.ready == []
      assert state.hands == %{"p1" => [], "p2" => []}
      assert state.discard_pile == []

      # turn_ref сохранён монотонным (§4.3) — протухшие таймауты не совпадут.
      assert state.turn_ref == 7
    end

    test "вне :finished — без изменений ({:error, :not_finished})" do
      code = lobby([player("p1"), player("p2")])

      assert {:error, :not_finished} = Server.restart(code)
      assert Server.state(code).phase == :lobby
    end
  end

  describe "выход из комнаты: remove_player/2 и grace отвала" do
    # Поллинг для асинхронных grace-эффектов (таймеры удаления).
    defp eventually(fun, tries \\ 50) do
      cond do
        fun.() ->
          :ok

        tries == 0 ->
          flunk("условие так и не выполнилось")

        true ->
          Process.sleep(20)
          eventually(fun, tries - 1)
      end
    end

    test "удаляет из ростера и шлёт broadcast" do
      code = lobby([player("p1"), player("p2")])
      :ok = Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))

      assert :ok = Server.remove_player(code, "p2")

      assert Enum.map(Server.state(code).players, & &1.id) == ["p1"]
      assert_receive {:game_update, ^code}
    end

    test "во время партии — {:error, :game_started}, место держится" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)

      assert {:error, :game_started} = Server.remove_player(code, "p2")
      assert length(Server.state(code).players) == 2
    end

    test "удаление неготового завершает готовность — партия авто-стартует" do
      code = lobby([player("p1"), player("p2"), player("p3")])
      :ok = Server.set_ready(code, "p1", true)
      :ok = Server.set_ready(code, "p2", true)

      # p3 не готов и уходит — оставшиеся двое готовы, авто-старт.
      assert :ok = Server.remove_player(code, "p3")
      assert Server.state(code).phase == :playing
    end

    test "последний реальный игрок ушёл — комната гаснет (и с ботами тоже)" do
      code = lobby([player("p1"), player("bot", true)])
      {:ok, pid} = Manager.find(code)
      ref = Process.monitor(pid)

      assert :ok = Server.remove_player(code, "p1")

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # Registry снимает регистрацию асинхронно (по своему DOWN-монитору) —
      # наш DOWN может прийти раньше; поллим, а не проверяем мгновенно.
      eventually(fn -> Manager.find(code) == :error end)
    end

    test "отвал: player_left удаляет спустя grace" do
      code = lobby([player("p1"), player("p2")], leave_grace_ms: 30)

      :ok = Server.player_left(code, "p2")

      eventually(fn -> Enum.map(Server.state(code).players, & &1.id) == ["p1"] end)
    end

    test "возврат до истечения grace гасит удаление (F5 безопасен)" do
      code = lobby([player("p1"), player("p2")], leave_grace_ms: 30)

      :ok = Server.player_left(code, "p2")
      :ok = Server.player_returned(code, "p2")

      Process.sleep(100)
      assert length(Server.state(code).players) == 2
    end

    test "отвал бота/чужака не взводит таймер (no-op)" do
      code = lobby([player("p1"), player("bot", true)], leave_grace_ms: 30)

      :ok = Server.player_left(code, "bot")
      :ok = Server.player_left(code, "ghost")

      Process.sleep(100)
      assert length(Server.state(code).players) == 2
    end

    test "уведомления в несуществующую комнату безвредны" do
      assert :ok = Server.player_left("no-such-room", "p1")
      assert :ok = Server.player_returned("no-such-room", "p1")
    end

    test "отвал во время партии не удаляет; после «Ещё раз» мёртвая душа вычищается" do
      # Засеянная завершённая партия: p1 победил, p2 так и не вернётся.
      code = unique_code()
      players = [player("p1"), player("p2")]

      game = %State{
        room_code: code,
        phase: :finished,
        players: players,
        hands: %{"p1" => [], "p2" => [num(:red, 3)]},
        discard_pile: [num(:red, 5)],
        current_color: :red,
        winner: "p1"
      }

      {:ok, _pid} = Manager.create(code, players: players, game: game, leave_grace_ms: 30)
      on_exit(fn -> Manager.stop(code) end)

      :ok = Server.player_left(code, "p2")

      # Вне лобби grace-таймер перевзводится, но НЕ удаляет.
      Process.sleep(100)
      assert length(Server.state(code).players) == 2

      # «Ещё раз» → комната ожидания → цикл дочищает отвалившегося.
      :ok = Server.restart(code)
      eventually(fn -> Enum.map(Server.state(code).players, & &1.id) == ["p1"] end)
    end
  end

  describe "let-it-crash: восстановление из снапшота (issue #61)" do
    alias Uno.Game.Stash

    # Убивает процесс партии и ждёт, пока супервизор поднимет новый.
    defp kill_and_await_restart(code) do
      {:ok, old} = Manager.find(code)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, :killed}

      eventually(fn ->
        case Manager.find(code) do
          {:ok, pid} -> pid != old and Process.alive?(pid)
          :error -> false
        end
      end)
    end

    test "kill посреди партии: состояние восстановлено, партия играбельна" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      :ok = Server.draw(code, "p1")
      before = Server.state(code)

      kill_and_await_restart(code)

      restored = Server.state(code)
      assert restored.phase == :playing
      assert restored.hands == before.hands
      assert restored.discard_pile == before.discard_pile
      assert restored.current_player == before.current_player
      assert restored.direction == before.direction
      assert restored.current_color == before.current_color

      assert restored.pending == before.pending

      # Новая инкарнация перевзводит ход: turn_ref строго растёт (§4.3).
      assert restored.turn_ref > before.turn_ref
      assert restored.turn_deadline != nil

      # Партия живая: текущий игрок может действовать (после добора — пас).
      case restored.pending do
        {:drew, player_id} -> assert :ok = Server.pass(code, player_id)
        _ -> assert :ok = Server.draw(code, restored.current_player)
      end
    end

    test "после восстановления таймер хода работает (авто-действие наступает)" do
      code = lobby([player("p1"), player("p2")], turn_ms: 60)
      :ok = Server.start_game(code)

      kill_and_await_restart(code)
      hand_before = length(Server.state(code).hands["p1"])

      # Таймер новой инкарнации живёт: авто-действие (добор p1) наступает.
      eventually(fn -> length(Server.state(code).hands["p1"]) > hand_before end)
    end

    test "после восстановления боты продолжают доигрывать" do
      code = lobby([player("bot-1", true), player("bot-2", true)], bot_delay: 20)
      :ok = Server.start_game(code)

      kill_and_await_restart(code)

      # Цепочка бот-ходов перевзводится и доводит партию до победителя.
      eventually(fn -> Server.state(code).phase == :finished end, 400)
    end

    test "протухший turn_timeout погибшей инкарнации безвреден" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      stale_ref = Server.state(code).turn_ref

      kill_and_await_restart(code)
      {:ok, pid} = Manager.find(code)
      before = Server.state(code)

      send(pid, {:turn_timeout, stale_ref})
      send(pid, {:bot_move, stale_ref})

      # Состояние не сдвинулось: ходы/руки на месте (deadline тот же).
      assert Server.state(code) == before
    end

    test "Manager.stop чистит снапшот (штатный :shutdown)" do
      code = lobby([player("p1"), player("p2")])
      :ok = Server.start_game(code)
      assert {:ok, _game} = Stash.get(code)

      :ok = Manager.stop(code)

      assert Stash.get(code) == :error
    end

    test "выход последнего реального (штатный :normal) чистит снапшот" do
      code = lobby([player("p1"), player("bot", true)])
      {:ok, pid} = Manager.find(code)
      ref = Process.monitor(pid)

      :ok = Server.remove_player(code, "p1")

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Stash.get(code) == :error
    end

    test "падение одной партии не трогает соседнюю (изоляция)" do
      crashing = lobby([player("p1"), player("p2")])
      bystander = lobby([player("q1"), player("q2")])
      :ok = Server.start_game(crashing)
      :ok = Server.start_game(bystander)
      {:ok, bystander_pid} = Manager.find(bystander)

      kill_and_await_restart(crashing)

      assert {:ok, ^bystander_pid} = Manager.find(bystander)
      assert Server.state(bystander).phase == :playing
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
