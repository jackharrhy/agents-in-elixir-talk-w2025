defmodule AgentWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent

  plug(Plug.Static,
    at: "/",
    from: :agent,
    gzip: false,
    only: ~w(index.html assets)
  )

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(CORSPlug)
  plug(AgentWeb.Router)
end
