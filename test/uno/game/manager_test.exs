defmodule Uno.Game.ManagerTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Manager, Server}

  defp unique_code, do: "room-#{System.unique_integer([:positive])}"
  defp player(id, is_bot \\ false), do: %{id: id, name: id, is_bot: is_bot}

  # Создаёт партию с уникальным кодом и гасит её по завершении теста.
  defp new_game(players \\ []) do
    code = unique_code()
    {:ok, pid} = Manager.create(code, players: players)
    on_exit(fn -> Manager.stop(code) end)
    {code, pid}
  end

  describe "create/2 и find/1" do
    test "создаёт партию и находит её по коду" do
      {code, pid} = new_game()
      assert {:ok, ^pid} = Manager.find(code)
    end

    test "дублирующийся room_code — ошибка" do
      {code, _pid} = new_game()
      assert Manager.create(code) == {:error, :already_exists}
    end

    test "find несуществующей партии — :error" do
      assert Manager.find(unique_code()) == :error
    end
  end

  describe "join/2 и project/2" do
    test "добавляет игрока в лобби (возвращает ростер, не полный State)" do
      {code, _} = new_game()
      assert {:ok, players} = Manager.join(code, player("p1"))
      assert Enum.map(players, & &1.id) == ["p1"]
    end

    test "проекция отдаёт свою руку, у соперников только число карт" do
      {code, _} = new_game([player("p1"), player("p2")])

      proj = Manager.project(code, "p1")

      assert proj.my_hand == []
      assert proj.others == [%{id: "p2", name: "p2", card_count: 0}]
      assert proj.phase == :lobby
    end

    test "нельзя войти сверх лимита игроков" do
      {code, _} = new_game([player("p1"), player("p2"), player("p3"), player("p4")])
      assert Manager.join(code, player("p5")) == {:error, :full}
    end

    test "нельзя войти дважды с тем же id" do
      {code, _} = new_game([player("p1")])
      assert Manager.join(code, player("p1")) == {:error, :already_joined}
    end
  end

  describe "изоляция партий" do
    test "падение одной партии не трогает другую" do
      {code_a, _pid_a} = new_game([player("a")])
      {_code_b, pid_b} = new_game([player("b")])

      ref = Process.monitor(pid_b)
      Process.exit(pid_b, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_b, _reason}

      # Партия A по-прежнему жива и отвечает своим состоянием.
      assert Server.state(code_a).room_code == code_a
    end
  end
end
