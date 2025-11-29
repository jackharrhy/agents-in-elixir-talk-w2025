defmodule AgentWeb.Router do
  use Phoenix.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # No accepts restriction for SSE endpoints
  pipeline :sse do
  end

  scope "/", AgentWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
  end

  scope "/api", AgentWeb do
    pipe_through(:api)

    get("/chats", ChatController, :index)
    post("/chats", ChatController, :create)
    get("/chats/:id", ChatController, :show)
    delete("/chats/:id", ChatController, :delete)
    post("/chats/:id/messages", ChatController, :message)
    post("/chats/:id/files", FileController, :upload)
  end

  # SSE streaming endpoints - no content type restriction
  scope "/api", AgentWeb do
    pipe_through(:sse)

    get("/chats/:id/subscribe", ChatController, :subscribe)
  end
end
