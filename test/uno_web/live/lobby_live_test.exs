defmodule UnoWeb.LobbyLiveTest do
  use UnoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Uno.Game.Manager

  test "лобби рендерится", %{conn: conn} do
    {:ok, _lobby, html} = live(conn, ~p"/")
    assert html =~ "UNO"
    assert html =~ "Создать комнату"
    assert html =~ "Войти по коду"
  end

  test "создание комнаты редиректит в игру", %{conn: conn} do
    {:ok, lobby, _html} = live(conn, ~p"/")

    assert {:error, {:live_redirect, %{to: path}}} =
             lobby
             |> form("form", lobby: %{name: "Алиса"})
             |> render_submit(%{action: "create"})

    assert path =~ ~r"\A/game/[A-HJ-NP-Z2-9]{4}\z"
    on_exit(fn -> Manager.stop(String.trim_leading(path, "/game/")) end)
  end

  test "создание без имени — ошибка", %{conn: conn} do
    {:ok, lobby, _html} = live(conn, ~p"/")

    html =
      lobby
      |> form("form", lobby: %{name: "  "})
      |> render_submit(%{action: "create"})

    assert html =~ "Введите имя"
  end

  test "вход в несуществующую комнату — ошибка", %{conn: conn} do
    {:ok, lobby, _html} = live(conn, ~p"/")

    html =
      lobby
      |> form("form", lobby: %{name: "Боб", code: "ZZZZ"})
      |> render_submit(%{action: "join"})

    assert html =~ "не найдена"
  end
end
