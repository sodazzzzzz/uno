defmodule UnoWeb.Presence do
  @moduledoc """
  Presence по топику партии (`Uno.Game.Server.topic/1`): кто из игроков
  сейчас реально подключён (открыта вкладка с комнатой/столом).

  Чисто web-слой: `GameLive` трекает себя после connect и показывает
  офлайн-бейджи; `Uno.Game.*` про presence не знает. Единственный мост —
  `handle_metas/4` ниже: полный уход/возврат игрока транслируется процессу
  партии нейтральными уведомлениями (`Server.player_left/returned`), а уж
  «что это значит» (grace-удаление из лобби) решает сам `Server`.
  """
  use Phoenix.Presence, otp_app: :uno, pubsub_server: Uno.PubSub

  alias Uno.Game.Server

  @impl true
  def init(_opts), do: {:ok, %{}}

  # `presences` — состояние топика УЖЕ после диффа: игрок «совсем ушёл», только
  # если его нет среди presences (закрыта последняя вкладка, а не одна из).
  @impl true
  def handle_metas("game:" <> room_code, %{joins: joins, leaves: leaves}, presences, state) do
    for {player_id, _meta} <- leaves, not Map.has_key?(presences, player_id) do
      Server.player_left(room_code, player_id)
    end

    for {player_id, _meta} <- joins do
      Server.player_returned(room_code, player_id)
    end

    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}
end
