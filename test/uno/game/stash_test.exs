defmodule Uno.Game.StashTest do
  use ExUnit.Case, async: true

  alias Uno.Game.{Stash, State}

  defp unique_code, do: "stash-#{System.unique_integer([:positive])}"

  test "put/get round-trip отдаёт тот же State" do
    code = unique_code()
    game = State.new(code, [%{id: "p1", name: "Алиса", is_bot: false}])

    assert :ok = Stash.put(game)
    assert {:ok, ^game} = Stash.get(code)
  end

  test "get несуществующего кода — :error" do
    assert Stash.get(unique_code()) == :error
  end

  test "повторный put перезаписывает снапшот" do
    code = unique_code()
    game = State.new(code)

    :ok = Stash.put(game)
    :ok = Stash.put(%{game | phase: :playing})

    assert {:ok, %State{phase: :playing}} = Stash.get(code)
  end

  test "delete удаляет снапшот (и идемпотентен)" do
    code = unique_code()
    :ok = Stash.put(State.new(code))

    assert :ok = Stash.delete(code)
    assert Stash.get(code) == :error
    assert :ok = Stash.delete(code)
  end
end
