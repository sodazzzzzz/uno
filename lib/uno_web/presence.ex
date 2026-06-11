defmodule UnoWeb.Presence do
  @moduledoc """
  Presence по топику партии (`Uno.Game.Server.topic/1`): кто из игроков
  сейчас реально подключён (открыта вкладка с комнатой/столом).

  Чисто web-слой: игрового состояния не касается. `GameLive` трекает себя
  после connect и показывает офлайн-бейджи; `Uno.Game.*` про presence не знает.
  """
  use Phoenix.Presence, otp_app: :uno, pubsub_server: Uno.PubSub
end
