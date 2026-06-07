defmodule UnoWeb.LobbyLive do
  @moduledoc """
  Вход в игру: создать комнату или войти по коду. Делегирует жизненный цикл
  партии в `Uno.Game.Manager`; после успеха `push_navigate` в `GameLive`.
  """
  use UnoWeb, :live_view

  alias Uno.Game.Manager

  # Без похожих символов (0/O, 1/I) — код проще диктовать.
  @code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 4

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, player_id: session["player_id"], name: "")}
  end

  @impl true
  def handle_event("submit", %{"action" => action, "lobby" => params}, socket) do
    name = clean_name(params["name"])
    socket = assign(socket, :name, name)

    cond do
      name == "" -> {:noreply, put_flash(socket, :error, "Введите имя")}
      action == "create" -> create(socket, name)
      action == "join" -> join(socket, name, clean_code(params["code"]))
      true -> {:noreply, socket}
    end
  end

  defp create(socket, name) do
    code = create_room(socket.assigns.player_id, name)
    {:noreply, push_navigate(socket, to: ~p"/game/#{code}")}
  end

  defp join(socket, _name, "") do
    {:noreply, put_flash(socket, :error, "Введите код комнаты")}
  end

  defp join(socket, name, code) do
    player = %{id: socket.assigns.player_id, name: name, is_bot: false}

    case Manager.find(code) do
      :error ->
        {:noreply, put_flash(socket, :error, "Комната #{code} не найдена")}

      {:ok, _pid} ->
        case Manager.join(code, player) do
          {:ok, _roster} -> {:noreply, push_navigate(socket, to: ~p"/game/#{code}")}
          # Уже за столом (вернулись в лобби и снова вошли) — просто заходим.
          {:error, :already_joined} -> {:noreply, push_navigate(socket, to: ~p"/game/#{code}")}
          {:error, :full} -> {:noreply, put_flash(socket, :error, "Комната заполнена")}
          {:error, :game_started} -> {:noreply, put_flash(socket, :error, "Игра уже началась")}
        end
    end
  end

  # Генерируем код, повторяя при редкой коллизии.
  defp create_room(player_id, name, attempts \\ 5) do
    code = gen_code()
    player = %{id: player_id, name: name, is_bot: false}

    case Manager.create(code, players: [player]) do
      {:ok, _pid} -> code
      {:error, :already_exists} when attempts > 0 -> create_room(player_id, name, attempts - 1)
    end
  end

  defp gen_code, do: for(_ <- 1..@code_length, into: "", do: <<Enum.random(@code_alphabet)>>)
  defp clean_name(name), do: name |> to_string() |> String.trim() |> String.slice(0, 20)
  defp clean_code(code), do: code |> to_string() |> String.trim() |> String.upcase()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="uno-lobby">
      <div class="uno-lobby__card">
        <h1 class="uno-lobby__logo">UNO</h1>
        <p class="uno-lobby__tag">Заходи в комнату по коду и играй в реальном времени</p>

        <form phx-submit="submit" class="uno-lobby__form" autocomplete="off">
          <input
            type="text"
            name="lobby[name]"
            value={@name}
            placeholder="Ваше имя"
            maxlength="20"
            class="uno-input"
            phx-debounce="blur"
          />
          <input
            type="text"
            name="lobby[code]"
            placeholder="Код комнаты"
            maxlength="4"
            class="uno-input"
          />

          <div class="uno-lobby__actions">
            <button type="submit" name="action" value="create" class="uno-btn uno-btn--primary">
              Создать комнату
            </button>
            <button type="submit" name="action" value="join" class="uno-btn uno-btn--ghost">
              Войти по коду
            </button>
          </div>
        </form>
      </div>
    </main>
    """
  end
end
