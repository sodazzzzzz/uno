defmodule UnoWeb.GameLive do
  @moduledoc """
  Экран партии: комната ожидания (`:lobby`) и игровой стол (`:playing` /
  `:choosing_color` / `:finished`) в стиле Warm Table.

  Состояние на клиент уходит ТОЛЬКО проекцией (`Server.project/2`) — полный
  `State` сюда не тянем. Изменения партии — через `Manager`/`Server`; `Rules`
  здесь дёргается лишь как чистый ЗАПРОС (`playable?/3` для подсветки), не для
  мутаций. Обновления приходят по PubSub (`{:game_update, code}`).
  """
  use UnoWeb, :live_view

  alias Uno.Game.{Manager, Rules, Server}
  alias UnoWeb.Presence

  @bot_names ~w(Лео Ада Рекс Кай Ника Макс Юна Тимо)

  @impl true
  def mount(%{"code" => code}, session, socket) do
    player_id = session["player_id"]

    with {:ok, _pid} <- Manager.find(code),
         view = Server.project(code, player_id),
         true <- member?(view, player_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))
        {:ok, _ref} = Presence.track(self(), Server.topic(code), player_id, %{})
      end

      {:ok,
       assign(socket,
         code: code,
         player_id: player_id,
         view: view,
         online: online_ids(code, player_id),
         # true только на рендере «лобби → стол» — включает stagger-раздачу;
         # на mount в идущую партию (F5/reconnect) раздачу не проигрываем.
         just_dealt: false
       )}
    else
      :error -> {:ok, to_lobby(socket, "Комната #{code} не найдена")}
      false -> {:ok, to_lobby(socket, "Войдите в комнату #{code} по коду")}
    end
  end

  defp to_lobby(socket, message) do
    socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")
  end

  @impl true
  def handle_info({:game_update, _code}, socket), do: {:noreply, refresh(socket)}

  # Кто-то подключился/отвалился — пересчитываем онлайн-набор из Presence.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    %{code: code, player_id: player_id} = socket.assigns
    {:noreply, assign(socket, :online, online_ids(code, player_id))}
  end

  # Stagger раздачи доигран — снимаем класс (см. refresh/1).
  def handle_info(:deal_done, socket), do: {:noreply, assign(socket, :just_dealt, false)}

  # --- Лобби ---

  @impl true
  def handle_event("add_bot", _params, socket) do
    bot = %{id: "bot-" <> rand_id(), name: bot_name(socket.assigns.view.players), is_bot: true}
    Manager.join(socket.assigns.code, bot)
    {:noreply, refresh(socket)}
  end

  def handle_event("leave", _params, socket) do
    %{code: code, player_id: player_id} = socket.assigns

    # Сначала отписка: если мы — последний реальный игрок, комната погаснет и
    # пришлёт прощальный broadcast; ловить его и проецировать мёртвый процесс
    # уже не надо. Удаление мгновенное (без ожидания presence-grace).
    Phoenix.PubSub.unsubscribe(Uno.PubSub, Server.topic(code))
    Server.remove_player(code, player_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("toggle_ready", _params, socket) do
    %{code: code, player_id: player_id, view: view} = socket.assigns

    # Партия стартует автоматически на стороне Server, когда все реальные готовы.
    Server.set_ready(code, player_id, not my_ready?(view, player_id))
    {:noreply, refresh(socket)}
  end

  # --- Стол ---

  def handle_event("play", %{"index" => index}, socket) do
    %{code: code, player_id: player_id, view: view} = socket.assigns

    # index приходит по сокету — может быть произвольным; не доверяем.
    with {i, ""} <- Integer.parse(to_string(index)),
         card when not is_nil(card) <- Enum.at(view.my_hand, i) do
      Server.play(code, player_id, card)
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("draw", _params, socket) do
    Server.draw(socket.assigns.code, socket.assigns.player_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("pass", _params, socket) do
    Server.pass(socket.assigns.code, socket.assigns.player_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("choose_color", %{"color" => color}, socket) do
    Server.choose_color(socket.assigns.code, socket.assigns.player_id, color_to_atom(color))
    {:noreply, refresh(socket)}
  end

  def handle_event("restart", _params, socket) do
    # «Ещё раз» — Server сбрасывает партию в комнату ожидания тем же составом;
    # дальше новую партию запускает обычный ready-флоу.
    Server.restart(socket.assigns.code)
    {:noreply, refresh(socket)}
  end

  # --- Помощники ---

  defp refresh(socket) do
    # Комната могла погаснуть между broadcast'ом и нашей перерисовкой
    # (последний реальный игрок вышел) — тогда просто уходим в лобби.
    case Manager.find(socket.assigns.code) do
      {:ok, _pid} ->
        new_view = Server.project(socket.assigns.code, socket.assigns.player_id)

        # Переход «лобби → стол» = раздача со stagger-анимацией. Флаг ЛИПКИЙ:
        # broadcast самой раздачи приходит следом и не должен смыть класс,
        # пока stagger играет; гасим отложенным :deal_done (косметика, не
        # игровое время — серверной логики на этом таймере нет). 1300мс — с
        # запасом больше полного stagger-а (6·60мс + 520мс ≈ 880мс): снятие
        # класса под бегущим keyframe-ом сдвинуло бы его прогресс.
        dealt_now = socket.assigns.view.phase == :lobby and new_view.phase == :playing
        if dealt_now, do: Process.send_after(self(), :deal_done, 1300)

        assign(socket, view: new_view, just_dealt: socket.assigns.just_dealt or dealt_now)

      :error ->
        push_navigate(socket, to: ~p"/")
    end
  end

  defp member?(view, player_id), do: Enum.any?(view.players, &(&1.id == player_id))

  # Кто сейчас подключён (по Presence на топике партии). Себя считаем онлайн
  # всегда: на dead render track ещё не сработал, мигать «офлайн» не надо.
  defp online_ids(code, me) do
    code |> Server.topic() |> Presence.list() |> Map.keys() |> MapSet.new() |> MapSet.put(me)
  end

  # Офлайн-индикация — только для реальных игроков; боты живут на сервере.
  defp offline?(player, online), do: not player.is_bot and not MapSet.member?(online, player.id)

  # То же по id (для `others` проекции — ботность берём из ростера).
  defp offline_id?(view, online, id) do
    case Enum.find(view.players, &(&1.id == id)) do
      nil -> false
      player -> offline?(player, online)
    end
  end

  defp my_ready?(view, player_id) do
    case Enum.find(view.players, &(&1.id == player_id)) do
      nil -> false
      me -> me.ready
    end
  end

  defp my_turn?(view, player_id), do: view.phase == :playing and view.whose_turn == player_id
  defp drew?(view, player_id), do: view.pending == {:drew, player_id}
  defp can_draw?(view, player_id), do: my_turn?(view, player_id) and not drew?(view, player_id)

  defp playable_now?(view, player_id, card) do
    my_turn?(view, player_id) and Rules.playable?(card, view.discard_top, view.current_color)
  end

  defp choosing_me?(view, player_id), do: view.pending == {:choose_color, player_id}

  defp choosing_id(view) do
    case view.pending do
      {:choose_color, id} -> id
      _ -> nil
    end
  end

  defp name_of(view, id) do
    case Enum.find(view.players, &(&1.id == id)) do
      nil -> ""
      player -> player.name
    end
  end

  defp turn_label(view, player_id) do
    if view.whose_turn == player_id,
      do: "Ваш ход",
      else: "Ходит #{name_of(view, view.whose_turn)}"
  end

  defp direction_arrow(:cw), do: "↻"
  defp direction_arrow(:ccw), do: "↺"

  defp color_to_atom("red"), do: :red
  defp color_to_atom("yellow"), do: :yellow
  defp color_to_atom("green"), do: :green
  defp color_to_atom("blue"), do: :blue

  defp bot_name(players) do
    taken = MapSet.new(players, & &1.name)
    Enum.find(@bot_names, "Бот", &(&1 not in taken))
  end

  defp rand_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6))

  defp avatar(name) do
    case String.first(name) do
      nil -> "?"
      ch -> String.upcase(ch)
    end
  end

  defp suit_class(%{type: type}) when type in [:wild, :wild_draw_four], do: "uno-card--wild"
  defp suit_class(%{color: color}), do: "uno-card--#{color}"

  # Детерминированный «разброс» конфетти из номера: без :rand (воспроизводимо),
  # значения уходят в CSS-переменные keyframe-а падения.
  defp confetti_style(i) do
    x = rem(i * 61, 100)
    delay = rem(i * 137, 600)
    duration = 1600 + rem(i * 211, 900)
    spin = 180 + rem(i * 97, 420)
    drift = rem(i * 53, 80) - 40
    "--x:#{x}%;--delay:#{delay}ms;--dur:#{duration}ms;--spin:#{spin}deg;--drift:#{drift}px"
  end

  # --- Карта (функц-компонент) ---

  def card(assigns) do
    ~H"""
    <div class={["uno-card", suit_class(@card)]}>
      <%= case @card.type do %>
        <% {:number, n} -> %>
          <span class="uno-card__big">{n}</span>
          <span class="uno-card__pip uno-card__pip--tl">{n}</span>
          <span class="uno-card__pip uno-card__pip--br">{n}</span>
        <% :skip -> %>
          <svg
            class="uno-card__ico uno-card__ico--skip"
            viewBox="0 0 40 40"
            fill="none"
            stroke="currentColor"
            stroke-width="3.2"
          >
            <circle cx="20" cy="20" r="13" />
            <line x1="11" y1="11" x2="29" y2="29" stroke-linecap="round" />
          </svg>
        <% :reverse -> %>
          <svg
            class="uno-card__ico uno-card__ico--rev"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <polyline points="23 6 23 10 19 10" />
            <polyline points="1 18 1 14 5 14" />
            <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
          </svg>
        <% :draw_two -> %>
          <span class="uno-card__plus">+2</span>
        <% :wild -> %>
          <div class="uno-card__wheel"></div>
        <% :wild_draw_four -> %>
          <span class="uno-card__corner4">+4</span>
          <div class="uno-card__wheel"></div>
      <% end %>
    </div>
    """
  end

  # --- Рендер ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <%= if @view.phase == :lobby do %>
      {render_waiting_room(assigns)}
    <% else %>
      {render_table(assigns)}
    <% end %>
    """
  end

  defp render_waiting_room(assigns) do
    ~H"""
    <main class="uno-room">
      <div class="uno-room__panel">
        <button phx-click="leave" class="uno-room__back">← выход</button>
        <h1 class="uno-room__logo">UNO</h1>

        <div class="uno-room__code">
          <span>Код комнаты</span>
          <strong>{@code}</strong>
        </div>

        <ul class="uno-room__players">
          <li
            :for={{player, idx} <- Enum.with_index(@view.players)}
            class={[
              "uno-player",
              player.id == @player_id && "is-me",
              offline?(player, @online) && "is-offline"
            ]}
            style={"--i:#{idx}"}
          >
            <span class="uno-player__avatar">{avatar(player.name)}</span>
            <span class="uno-player__name">{player.name}</span>
            <span :if={idx == 0} class="uno-tag">хост</span>
            <span :if={player.is_bot} class="uno-tag uno-tag--bot">бот</span>
            <span :if={not player.is_bot and player.ready} class="uno-tag uno-tag--ready">
              ✓ готов
            </span>
            <span
              :if={not player.is_bot and not player.ready and not offline?(player, @online)}
              class="uno-tag uno-tag--wait"
            >
              ждём…
            </span>
            <span :if={offline?(player, @online)} class="uno-tag uno-tag--offline">
              офлайн
            </span>
          </li>
        </ul>

        <div class="uno-room__actions">
          <button
            phx-click="add_bot"
            class="uno-btn uno-btn--ghost"
            disabled={length(@view.players) >= 4}
          >
            + бот
          </button>
          <button
            :if={my_ready?(@view, @player_id)}
            phx-click="toggle_ready"
            class="uno-btn uno-btn--ghost"
          >
            Отменить готовность
          </button>
          <button
            :if={not my_ready?(@view, @player_id)}
            phx-click="toggle_ready"
            class="uno-btn uno-btn--primary"
          >
            Готов
          </button>
        </div>

        <p class="uno-room__hint">
          <%= if length(@view.players) < 2 do %>
            Нужно минимум 2 игрока — позови друга по коду <strong>{@code}</strong> или добавь бота.
          <% else %>
            Партия начнётся автоматически, когда все игроки нажмут «Готов».
          <% end %>
        </p>
      </div>
    </main>
    """
  end

  defp render_table(assigns) do
    ~H"""
    <main class={["uno-table", @just_dealt && "is-dealing"]}>
      <header class="uno-table__hud">
        <span class="uno-table__room">Комната {@code}</span>
        <span :if={@view.phase == :playing} class="uno-table__turn">
          {turn_label(@view, @player_id)}
        </span>
        <.link navigate={~p"/"} class="uno-table__exit">выход</.link>
      </header>

      <section class={["uno-opponents", length(@view.others) >= 3 && "uno-opponents--arc"]}>
        <div
          :for={{opp, idx} <- Enum.with_index(@view.others)}
          class={[
            "uno-pod",
            opp.id == @view.whose_turn && "is-active",
            offline_id?(@view, @online, opp.id) && "is-offline"
          ]}
          style={"--i:#{idx}"}
        >
          <div class="uno-avwrap">
            <div
              :if={opp.id == @view.whose_turn and @view.turn_deadline}
              id={"ring-#{opp.id}"}
              class="uno-ring"
              phx-hook=".TurnTimer"
              data-deadline={@view.turn_deadline}
              data-duration={@view.turn_ms}
            >
            </div>
            <div class="uno-pod__avatar">{avatar(opp.name)}</div>
            <span
              :if={offline_id?(@view, @online, opp.id)}
              class="uno-pod__status"
              title="офлайн"
            >
            </span>
          </div>
          <div class="uno-pod__name">{opp.name}</div>
          <div class="uno-pod__fan">
            <i :for={_ <- 1..min(opp.card_count, 7)//1} class="uno-back"></i>
          </div>
          <div class="uno-pod__count">{opp.card_count} карт</div>
        </div>
      </section>

      <section class="uno-center">
        <button class="uno-deck" phx-click="draw" disabled={not can_draw?(@view, @player_id)}>
          <span class="uno-deck__badge">UNO</span>
        </button>
        <%!-- id от discard_count: morphdom пересоздаёт узел на каждый розыгрыш —
        entrance-анимация «прилёта» играет ровно один раз на новую карту. --%>
        <div class="uno-discard" id={"discard-#{@view.discard_count}"}>
          <.card :if={@view.discard_top} card={@view.discard_top} />
        </div>
        <div class="uno-colorchip">
          <span class={["uno-dot", @view.current_color && "uno-dot--#{@view.current_color}"]}></span>
          <small>цвет</small>
          <%!-- id от direction: пересоздание узла при реверсе запускает разворот. --%>
          <span class="uno-dir" id={"dir-#{@view.direction}"}>
            {direction_arrow(@view.direction)}
          </span>
        </div>
      </section>

      <section class="uno-hand">
        <button
          :for={{card, i} <- Enum.with_index(@view.my_hand)}
          class={["uno-cardbtn", playable_now?(@view, @player_id, card) && "is-playable"]}
          style={"--i:#{i};--n:#{length(@view.my_hand)}"}
          phx-click="play"
          phx-value-index={i}
          disabled={not playable_now?(@view, @player_id, card)}
        >
          <.card card={card} />
        </button>
        <p :if={@view.my_hand == []} class="uno-hand__empty">— рука пуста —</p>
      </section>

      <footer class="uno-footer">
        <div class="uno-you">
          <div class="uno-avwrap">
            <div
              :if={@view.whose_turn == @player_id and @view.turn_deadline}
              id="ring-me"
              class="uno-ring"
              phx-hook=".TurnTimer"
              data-deadline={@view.turn_deadline}
              data-duration={@view.turn_ms}
            >
            </div>
            <div class="uno-you__avatar">{avatar(name_of(@view, @player_id))}</div>
          </div>
          <div class="uno-you__meta">
            <span class="uno-you__name">{name_of(@view, @player_id)}</span>
            <span class="uno-you__count">{length(@view.my_hand)} карт</span>
          </div>
        </div>
        <button
          :if={drew?(@view, @player_id)}
          phx-click="pass"
          class="uno-btn uno-btn--primary uno-footer__pass"
        >
          Пас
        </button>
      </footer>
    </main>

    <div :if={@view.phase == :choosing_color} class="uno-overlay">
      <div class="uno-overlay__card">
        <%= if choosing_me?(@view, @player_id) do %>
          <h2 class="uno-overlay__title">Выберите цвет</h2>
          <div class="uno-colors">
            <button
              :for={c <- ~w(red yellow green blue)}
              class={"uno-colorbtn uno-colorbtn--#{c}"}
              phx-click="choose_color"
              phx-value-color={c}
              aria-label={c}
            >
            </button>
          </div>
        <% else %>
          <h2 class="uno-overlay__title">{name_of(@view, choosing_id(@view))} выбирает цвет…</h2>
        <% end %>
      </div>
    </div>

    <div :if={@view.phase == :finished} class="uno-overlay">
      <%!-- Салют карт-конфетти: чистый CSS, pointer-events нет — кнопки живые. --%>
      <div class="uno-confetti" aria-hidden="true">
        <i :for={i <- 1..16} class="uno-confetti__bit" style={confetti_style(i)}></i>
      </div>
      <div class="uno-overlay__card uno-overlay__card--win">
        <div class="uno-overlay__emoji">🎉</div>
        <h2 class="uno-overlay__title">{name_of(@view, @view.winner)} победил!</h2>
        <div class="uno-overlay__actions">
          <button phx-click="restart" class="uno-btn uno-btn--primary">Ещё раз</button>
          <.link navigate={~p"/"} class="uno-btn uno-btn--ghost">В лобби</.link>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".TurnTimer">
      // Косметический отсчёт кольца от серверного turn_deadline (§4.4).
      // Реальное авто-действие наступает по серверному таймеру, не здесь.
      export default {
        mounted() { this.run() },
        updated() { this.run() },
        destroyed() { cancelAnimationFrame(this.raf) },
        run() {
          cancelAnimationFrame(this.raf)
          const deadline = Number(this.el.dataset.deadline)
          const duration = Number(this.el.dataset.duration) || 30000
          if (!deadline) { this.el.style.setProperty("--p", 1); return }
          const tick = () => {
            const p = Math.max(0, Math.min(1, (deadline - Date.now()) / duration))
            this.el.style.setProperty("--p", p)
            if (p > 0) this.raf = requestAnimationFrame(tick)
          }
          tick()
        }
      }
    </script>
    """
  end
end
