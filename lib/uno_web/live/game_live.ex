defmodule UnoWeb.GameLive do
  @moduledoc """
  Экран партии. В этом куске (PR-UI-1) — комната ожидания (фаза `:lobby`):
  код комнаты, список игроков, добавить бота, старт. Стол игры (фазы
  `:playing`/`:choosing_color`/`:finished`) — следующий кусок UI.

  Состояние на клиент уходит ТОЛЬКО проекцией (`Rules.project/2` через
  `Server.project/2`) — полный `State` сюда не тянем. Обновления — по PubSub
  (`{:game_update, code}`), на которые перепроецируемся.
  """
  use UnoWeb, :live_view

  alias Uno.Game.{Manager, Server}

  @bot_names ~w(Лео Ада Рекс Кай Ника Макс Юна Тимо)

  @impl true
  def mount(%{"code" => code}, session, socket) do
    player_id = session["player_id"]

    with {:ok, _pid} <- Manager.find(code),
         view = Server.project(code, player_id),
         true <- member?(view, player_id) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Uno.PubSub, Server.topic(code))
      {:ok, assign(socket, code: code, player_id: player_id, view: view)}
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

  @impl true
  def handle_event("add_bot", _params, socket) do
    bot = %{id: "bot-" <> rand_id(), name: bot_name(socket.assigns.view.players), is_bot: true}
    Manager.join(socket.assigns.code, bot)
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle_ready", _params, socket) do
    %{code: code, player_id: player_id, view: view} = socket.assigns

    # Партия стартует автоматически на стороне Server, когда все реальные готовы.
    Server.set_ready(code, player_id, not my_ready?(view, player_id))
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    assign(socket, :view, Server.project(socket.assigns.code, socket.assigns.player_id))
  end

  defp member?(view, player_id), do: Enum.any?(view.players, &(&1.id == player_id))

  defp my_ready?(view, player_id) do
    case Enum.find(view.players, &(&1.id == player_id)) do
      nil -> false
      me -> me.ready
    end
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="uno-room">
      <div class="uno-room__panel">
        <%= if @view.phase == :lobby do %>
          <.link navigate={~p"/"} class="uno-room__back">← выход</.link>
          <h1 class="uno-room__logo">UNO</h1>

          <div class="uno-room__code">
            <span>Код комнаты</span>
            <strong>{@code}</strong>
          </div>

          <ul class="uno-room__players">
            <li
              :for={{player, idx} <- Enum.with_index(@view.players)}
              class={["uno-player", player.id == @player_id && "is-me"]}
            >
              <span class="uno-player__avatar">{avatar(player.name)}</span>
              <span class="uno-player__name">{player.name}</span>
              <span :if={idx == 0} class="uno-tag">хост</span>
              <span :if={player.is_bot} class="uno-tag uno-tag--bot">бот</span>
              <span :if={not player.is_bot and player.ready} class="uno-tag uno-tag--ready">
                ✓ готов
              </span>
              <span :if={not player.is_bot and not player.ready} class="uno-tag uno-tag--wait">
                ждём…
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
        <% else %>
          <h1 class="uno-room__logo">Партия идёт</h1>
          <p class="uno-room__hint">Игровой стол появится в следующем обновлении интерфейса.</p>
          <p class="uno-room__hint">
            Фаза: <strong>{@view.phase}</strong>, сейчас ходит: <strong>{@view.whose_turn}</strong>
          </p>
          <.link navigate={~p"/"} class="uno-btn uno-btn--ghost">← выход</.link>
        <% end %>
      </div>
    </main>
    """
  end
end
