defmodule UnoWeb.GameLiveTest do
  use UnoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Uno.Game.{Manager, Server, State}

  defp unique_code, do: "T#{System.unique_integer([:positive])}"
  defp player(id, name, is_bot \\ false), do: %{id: id, name: name, is_bot: is_bot}

  # conn с известным player_id в сессии + созданная комната с этим игроком.
  # opts прокидываются в Server (напр. leave_grace_ms для grace-тестов).
  defp room(players, opts \\ []) do
    code = unique_code()
    {:ok, _pid} = Manager.create(code, Keyword.put(opts, :players, players))
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

    test "экран победы показывает «Ещё раз»; клик возвращает в комнату ожидания", %{conn: conn} do
      players = [player("me", "Алиса"), player("bot-1", "Лео", true)]
      code = finished_room(players, "me")
      conn = conn_as(conn, "me")
      {:ok, view, html} = live(conn, ~p"/game/#{code}")

      assert html =~ "Алиса победил"
      assert html =~ "Ещё раз"

      html = view |> element("button", "Ещё раз") |> render_click()

      # Возврат в комнату ожидания (ready-флоу), экран победы исчез.
      assert html =~ "Код комнаты"
      assert html =~ "Готов"
      refute html =~ "победил"
    end
  end

  describe "выход из комнаты ожидания" do
    test "кнопка «выход» удаляет из ростера и уводит в лобби", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")])
      conn = conn_as(conn, "me")
      {:ok, view, _html} = live(conn, ~p"/game/#{code}")

      view |> element("button", "← выход") |> render_click()

      assert_redirect(view, "/")
      assert Enum.map(Server.state(code).players, & &1.id) == ["her"]
    end

    test "последний реальный вышел — комната гаснет", %{conn: conn} do
      code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
      conn = conn_as(conn, "me")
      {:ok, view, _html} = live(conn, ~p"/game/#{code}")

      view |> element("button", "← выход") |> render_click()

      assert_redirect(view, "/")

      # Registry чистится асинхронно после смерти процесса — поллим.
      eventually(fn -> Manager.find(code) == :error end)
    end

    test "закрыл вкладку — спустя grace игрок удалён (presence-мост)", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")], leave_grace_ms: 50)
      conn = conn_as(conn, "me")
      {:ok, view, _html} = live(conn, ~p"/game/#{code}")

      # Смерть LiveView-процесса = закрытие вкладки: presence шлёт leave.
      GenServer.stop(view.pid)

      eventually(fn -> Enum.map(Server.state(code).players, & &1.id) == ["her"] end)
    end

    test "F5 не выкидывает: быстрый возврат гасит grace-таймер", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")], leave_grace_ms: 300)
      conn = conn_as(conn, "me")
      {:ok, view, _html} = live(conn, ~p"/game/#{code}")

      GenServer.stop(view.pid)
      {:ok, _view2, _html} = live(conn, ~p"/game/#{code}")

      # Спим дольше grace: таймер удаления должен быть погашен возвратом.
      Process.sleep(600)
      assert length(Server.state(code).players) == 2
    end
  end

  describe "presence (онлайн/офлайн)" do
    # Presence-диффы приходят асинхронно — даём им долететь.
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

    test "после подключения игрок трекается на топике партии", %{conn: conn} do
      code = room([player("me", "Алиса")])
      {:ok, _view, _html} = live(conn_as(conn, "me"), ~p"/game/#{code}")

      assert Map.has_key?(UnoWeb.Presence.list(Server.topic(code)), "me")
    end

    test "реальный игрок без подключения показан офлайн (и без «ждём…»)", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")])
      {:ok, view, _html} = live(conn_as(conn, "me"), ~p"/game/#{code}")
      html = render(view)

      assert html =~ "офлайн"
      assert html =~ "is-offline"

      # «ждём…» уступает место «офлайн», но остаётся у подключённых неготовых.
      refute view |> element("li.is-offline") |> render() =~ "ждём…"
    end

    test "бот офлайн-бейджа не получает", %{conn: conn} do
      code = room([player("me", "Алиса"), player("bot-1", "Лео", true)])
      {:ok, _view, html} = live(conn_as(conn, "me"), ~p"/game/#{code}")

      refute html =~ "офлайн"
    end

    test "подключение второго игрока убирает его офлайн-бейдж у первого", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")])
      {:ok, view, _html} = live(conn_as(conn, "me"), ~p"/game/#{code}")
      assert render(view) =~ "офлайн"

      {:ok, _view2, _html} = live(conn_as(build_conn(), "her"), ~p"/game/#{code}")

      eventually(fn -> not (render(view) =~ "офлайн") end)
    end

    test "за столом офлайн-соперник приглушён и со статус-лункой", %{conn: conn} do
      code = room([player("me", "Алиса"), player("her", "Вера")])

      # Вера готова, но так и не подключилась; я готовлюсь кликом — авто-старт.
      Server.set_ready(code, "her", true)
      {:ok, view, _html} = live(conn_as(conn, "me"), ~p"/game/#{code}")
      html = view |> element("button", "Готов") |> render_click()

      assert html =~ "uno-hand"
      assert view |> element("div.uno-pod.is-offline") |> render() =~ "Вера"
      assert html =~ "uno-pod__status"
    end
  end

  defp server_players(code), do: length(Server.state(code).players)
end
