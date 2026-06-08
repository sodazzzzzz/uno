defmodule UnoWeb.GameLiveTest do
  use UnoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Uno.Game.{Manager, Server, State}

  defp unique_code, do: "T#{System.unique_integer([:positive])}"
  defp player(id, name, is_bot \\ false), do: %{id: id, name: name, is_bot: is_bot}

  # conn с известным player_id в сессии + созданная комната с этим игроком.
  defp room(players) do
    code = unique_code()
    {:ok, _pid} = Manager.create(code, players: players)
    on_exit(fn -> Manager.stop(code) end)
    code
  end

  # Комната с уже завершённой партией (экран победы) — засев через :game.
  defp finished_room(players, winner) do
    code = unique_code()

    game = %State{
      room_code: code,
      phase: :finished,
      players: players,
      hands: Map.new(players, &{&1.id, []}),
      discard_pile: [%{color: :red, type: {:number, 5}}],
      current_color: :red,
      winner: winner
    }

    {:ok, _pid} = Manager.create(code, players: players, game: game)
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

  test "готовность реального игрока авто-стартует партию (бот всегда готов)", %{conn: conn} do
    code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
    conn = conn_as(conn, "me")
    {:ok, view, _html} = live(conn, ~p"/game/#{code}")

    # Жму «Готов» → все реальные готовы (я) + бот всегда готов → авто-старт.
    html = view |> element("button", "Готов") |> render_click()

    # Раздача прошла, рендерится стол: ход первого игрока (меня).
    assert html =~ "Ваш ход"
    assert html =~ "uno-hand"
  end

  test "готовность можно отменить; пока не все готовы — партия не стартует", %{conn: conn} do
    # Два реальных игрока: пока Боб не готов, моё «Готов» не стартует партию.
    code = room([player("me", "Алиса"), player("bob", "Боб")])
    conn = conn_as(conn, "me")
    {:ok, view, _html} = live(conn, ~p"/game/#{code}")

    html = view |> element("button", "Готов") |> render_click()
    assert html =~ "Отменить готовность"
    refute html =~ "Партия идёт"

    html = view |> element("button", "Отменить готовность") |> render_click()
    assert html =~ "Готов"
    refute html =~ "Отменить готовность"
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

  describe "игровой стол" do
    # Доводит партию до :playing (я — первый, мой ход) и возвращает live view.
    defp started(conn) do
      code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
      conn = conn_as(conn, "me")
      {:ok, view, _html} = live(conn, ~p"/game/#{code}")
      view |> element("button", "Готов") |> render_click()
      view
    end

    test "после старта рендерится стол: рука, сброс, соперник", %{conn: conn} do
      html = render(started(conn))

      assert html =~ "uno-hand"
      assert html =~ "uno-card"
      assert html =~ "Лео"
    end

    test "клик по колоде добирает карту и показывает «Пас»", %{conn: conn} do
      view = started(conn)

      html = view |> element("button.uno-deck") |> render_click()

      assert html =~ "Пас"
    end

    test "пас после добора передаёт ход следующему", %{conn: conn} do
      view = started(conn)

      view |> element("button.uno-deck") |> render_click()
      html = view |> element("button", "Пас") |> render_click()

      assert html =~ "Ходит Лео"
    end

    test "на своём ходу рендерится кольцо-таймер с дедлайном", %{conn: conn} do
      html = render(started(conn))

      assert html =~ ~s(id="ring-me")
      assert html =~ "data-deadline"
    end

    test "крафтовый нечисловой index не роняет канал (находка ревью)", %{conn: conn} do
      view = started(conn)

      # Произвольный payload по сокету — игнорируется, стол остаётся живым.
      html = render_click(view, "play", %{"index" => "не-число"})

      assert html =~ "uno-hand"
    end

    test "экран победы показывает «Ещё раз»; клик перезапускает партию", %{conn: conn} do
      players = [player("me", "Алиса"), player("bot-1", "Лео", true)]
      code = finished_room(players, "me")
      conn = conn_as(conn, "me")
      {:ok, view, html} = live(conn, ~p"/game/#{code}")

      assert html =~ "Алиса победил"
      assert html =~ "Ещё раз"

      html = view |> element("button", "Ещё раз") |> render_click()

      # Новая партия: рендерится стол, экран победы исчез.
      assert html =~ "uno-hand"
      refute html =~ "победил"
    end
  end

  defp server_players(code), do: length(Server.state(code).players)
end
