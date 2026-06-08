defmodule Uno.Game.State do
  @moduledoc """
  Структура состояния одной партии UNO.

  Это **только данные**: набор полей партии и тривиальная их
  инициализация. Здесь НЕТ игровых правил (валидность хода, раздача, эффекты
  карт, следующий игрок — всё это `Uno.Game.Rules`) и НЕТ процессного слоя
  (`GenServer`/`send`/`Process`/`PubSub` — это `Uno.Game.Server`).

  `new/2` и `add_player/2` — чистые операции над структурой (создание лобби,
  добавление игрока). Они не проверяют правила и фазу: контроль «можно ли
  войти» — забота вызывающего (`Manager`/`Server`).

  Имена полей фиксированы каноном проекта — на них завязаны проекция (`Rules.project/2`)
  и тесты, поэтому переименование полей ломает контракт.
  """

  alias Uno.Game.Deck

  @typedoc "Активный цвет / цвет карты."
  @type color :: Deck.color()

  @typedoc "Карта — представление из `Uno.Game.Deck`."
  @type card :: Deck.card()

  @type player_id :: String.t()

  @typedoc "Игрок в порядке посадки."
  @type player :: %{id: player_id, name: String.t(), is_bot: boolean}

  @type phase :: :lobby | :playing | :choosing_color | :finished

  @type direction :: :cw | :ccw

  @typedoc """
  Ожидаемое под-действие партии:

    * `nil` — ничего не ждём;
    * `{:choose_color, player_id}` — игрок должен выбрать цвет после Wild;
    * `{:drew, player_id}` — игрок уже добрал карту в этот ход (значит, второй
      добор запрещён, а спасовать теперь можно);
    * `{:draw_penalty, player_id, count}` — игрок должен взять `count` карт.
  """
  @type pending ::
          nil
          | {:choose_color, player_id}
          | {:drew, player_id}
          | {:draw_penalty, player_id, pos_integer}

  @type t :: %__MODULE__{
          room_code: String.t() | nil,
          phase: phase,
          players: [player],
          hands: %{optional(player_id) => [card]},
          draw_pile: [card],
          discard_pile: [card],
          current_player: player_id | nil,
          direction: direction,
          current_color: color | nil,
          pending: pending,
          turn_ref: non_neg_integer,
          turn_deadline: integer | nil,
          winner: player_id | nil,
          ready: [player_id]
        }

  defstruct room_code: nil,
            phase: :lobby,
            players: [],
            hands: %{},
            draw_pile: [],
            discard_pile: [],
            current_player: nil,
            direction: :cw,
            current_color: nil,
            pending: nil,
            turn_ref: 0,
            turn_deadline: nil,
            winner: nil,
            ready: []

  @doc """
  Создаёт начальное состояние лобби для комнаты `room_code`.

  Опционально принимает уже посаженных игроков (в порядке посадки) и заводит
  каждому пустую руку. Чистая инициализация — раздачу карт и старт партии делает
  `Rules`, не здесь.
  """
  @spec new(String.t(), [player]) :: t
  def new(room_code, players \\ []) when is_binary(room_code) and is_list(players) do
    %__MODULE__{
      room_code: room_code,
      players: players,
      hands: Map.new(players, fn %{id: id} -> {id, []} end)
    }
  end

  @doc """
  Добавляет игрока в конец списка `players` и заводит ему пустую руку.

  Чистая операция над данными: не проверяет фазу, дубликаты или лимит игроков —
  это ответственность вызывающего. Существующую руку игрока с тем же `id` не
  затирает (`Map.put_new/3`).
  """
  @spec add_player(t, player) :: t
  def add_player(%__MODULE__{} = state, %{id: id} = player) do
    %{
      state
      | players: state.players ++ [player],
        hands: Map.put_new(state.hands, id, [])
    }
  end

  @doc """
  Отмечает игрока готовым/не готовым к старту (лобби). Чистая операция над
  данными, дубликаты не плодит. Готовность ботов отдельно не хранится — боты
  «готовы» всегда (это учитывают проекция и `Game.Server`).
  """
  @spec set_ready(t, player_id, boolean) :: t
  def set_ready(%__MODULE__{} = state, player_id, true),
    do: %{state | ready: Enum.uniq([player_id | state.ready])}

  def set_ready(%__MODULE__{} = state, player_id, false),
    do: %{state | ready: List.delete(state.ready, player_id)}
end
