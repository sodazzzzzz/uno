defmodule UnoWeb.GameLiveTest do
  use UnoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Uno.Game.{Manager, Server}

  defp unique_code, do: "T#{System.unique_integer([:positive])}"
  defp player(id, name, is_bot \\ false), do: %{id: id, name: name, is_bot: is_bot}

  # conn с известным player_id в сессии + созданная комната с этим игроком.
  defp room(players) do
    code = unique_code()
    {:ok, _pid} = Manager.create(code, players: players)
    on_exit(fn -> Manager.stop(code) end)
    code
  end

  defp conn_as(conn, player_id) do
    Plug.Test.init_test_session(conn, %{"player_id" => player_id})
  end

  test "комната ожидания показывает игроков, код и хоста", %{conn: conn} do
    code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
    conn = conn_as(conn, "me")

    {:ok, _view, html} = live(conn, ~p"/game/#{code}")

    assert html =~ "Алиса"
    assert html =~ "Лео"
    assert html =~ code
    assert html =~ "хост"
    assert html =~ "бот"
  end

  test "добавить бота — появляется в комнате", %{conn: conn} do
    code = room([player("me", "Алиса")])
    conn = conn_as(conn, "me")
    {:ok, view, _html} = live(conn, ~p"/game/#{code}")

    html = view |> element("button", "+ бот") |> render_click()

    assert html =~ "бот"
    assert server_players(code) == 2
  end

  test "старт с двумя игроками переводит партию в игру", %{conn: conn} do
    code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
    conn = conn_as(conn, "me")
    {:ok, view, _html} = live(conn, ~p"/game/#{code}")

    html = view |> element("button", "Начать партию") |> render_click()

    assert html =~ "Партия идёт"
  end

  test "несуществующая комната редиректит в лобби", %{conn: conn} do
    conn = conn_as(conn, "p-x")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/game/ZZZZ")
  end

  test "не-участник редиректит в лобби", %{conn: conn} do
    code = room([player("other", "Кто-то")])
    conn = conn_as(conn, "p-stranger")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/game/#{code}")
  end

  defp server_players(code), do: length(Server.state(code).players)
end
