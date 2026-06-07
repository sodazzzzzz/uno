defmodule UnoWeb.Plugs.PlayerSession do
  @moduledoc """
  Гарантирует стабильный анонимный `player_id` в сессии браузера.

  Игроки в этом MVP без логина/паролей: на первом запросе генерируем
  случайный `player_id` и кладём в сессию. Дальше LiveView (`LobbyLive`,
  `GameLive`) читает его из `session` и использует как id игрока в партии.
  """
  import Plug.Conn

  @session_key "player_id"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil -> put_session(conn, @session_key, generate_id())
      _id -> conn
    end
  end

  defp generate_id, do: "p-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
end
