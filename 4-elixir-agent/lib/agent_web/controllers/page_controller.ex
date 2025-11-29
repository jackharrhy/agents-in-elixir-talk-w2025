defmodule AgentWeb.PageController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    html = File.read!(Application.app_dir(:agent, "priv/static/index.html"))
    html(conn, html)
  end
end
