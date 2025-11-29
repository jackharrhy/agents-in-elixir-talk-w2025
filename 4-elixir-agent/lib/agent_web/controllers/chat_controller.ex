defmodule AgentWeb.ChatController do
  use Phoenix.Controller, formats: [:json]

  alias Agent.Chat.{Server, Store}

  def index(conn, _params) do
    chats = Store.list_chats()

    # Add online status
    chats_with_status =
      Enum.map(chats, fn chat ->
        Map.put(chat, :online, Server.exists?(chat.id))
      end)

    json(conn, %{chats: chats_with_status})
  end

  def create(conn, params) do
    id = generate_id()
    title = params["title"] || "New Chat"

    {:ok, _data} = Store.create_chat(id, title)
    {:ok, _pid} = Server.get_or_start(id)

    json(conn, %{id: id, title: title})
  end

  def show(conn, %{"id" => id}) do
    case Store.get_chat(id) do
      {:ok, data} ->
        online = Server.exists?(id)
        json(conn, %{id: id, title: data.title, messages: data.messages, online: online})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Chat not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    # Stop the GenServer if running
    if Server.exists?(id) do
      pid = GenServer.whereis(Server.via(id))
      if pid, do: GenServer.stop(pid, :normal)
    end

    # Delete from store
    Store.delete_chat(id)

    json(conn, %{ok: true})
  end

  def message(conn, %{"id" => id, "content" => content}) do
    case Server.get_or_start(id) do
      {:ok, _pid} ->
        # Set up SSE streaming
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Send message and stream response
        Server.send_message(id, content, self())
        stream_loop(conn, id)

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "Failed to start chat: #{inspect(reason)}"})
    end
  end

  def subscribe(conn, %{"id" => id}) do
    case Server.get_or_start(id) do
      {:ok, _pid} ->
        # Set up SSE streaming
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Send initial connected event
        {:ok, conn} = chunk(conn, "data: {\"type\":\"connected\"}\n\n")

        # Subscribe to receive stream events (will replay buffer if streaming)
        Server.subscribe(id, self())
        subscription_loop(conn, id)

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "Failed to start chat: #{inspect(reason)}"})
    end
  end

  defp stream_loop(conn, chat_id) do
    receive do
      {:user_message, content} ->
        event = %{type: "user-message", content: content}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        stream_loop(conn, chat_id)

      {:text_delta, delta} ->
        event = %{type: "text-delta", text: delta}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        stream_loop(conn, chat_id)

      {:tool_call, tool_call} ->
        input =
          case Jason.decode(tool_call.arguments || "{}") do
            {:ok, parsed} -> parsed
            {:error, _} -> %{"raw" => tool_call.arguments}
          end

        event = %{
          type: "tool-call",
          toolCallId: tool_call.id,
          toolName: tool_call.name,
          input: input
        }

        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        stream_loop(conn, chat_id)

      {:tool_call_delta, _id, _delta} ->
        # Skip deltas, we send complete tool calls
        stream_loop(conn, chat_id)

      {:tool_result, tool_call_id, result} ->
        event = %{type: "tool-result", toolCallId: tool_call_id, output: result}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        stream_loop(conn, chat_id)

      {:done, _text} ->
        Server.unsubscribe(chat_id, self())
        chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason} ->
        Server.unsubscribe(chat_id, self())
        event = %{type: "error", message: inspect(reason)}
        chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        conn
    after
      60_000 ->
        Server.unsubscribe(chat_id, self())
        conn
    end
  end

  # Subscription loop stays open indefinitely, doesn't exit on {:done}
  defp subscription_loop(conn, chat_id) do
    receive do
      {:user_message, content} ->
        event = %{type: "user-message", content: content}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        subscription_loop(conn, chat_id)

      {:text_delta, delta} ->
        event = %{type: "text-delta", text: delta}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        subscription_loop(conn, chat_id)

      {:tool_call, tool_call} ->
        input =
          case Jason.decode(tool_call.arguments || "{}") do
            {:ok, parsed} -> parsed
            {:error, _} -> %{"raw" => tool_call.arguments}
          end

        event = %{
          type: "tool-call",
          toolCallId: tool_call.id,
          toolName: tool_call.name,
          input: input
        }

        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        subscription_loop(conn, chat_id)

      {:tool_call_delta, _id, _delta} ->
        subscription_loop(conn, chat_id)

      {:tool_result, tool_call_id, result} ->
        event = %{type: "tool-result", toolCallId: tool_call_id, output: result}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        subscription_loop(conn, chat_id)

      {:done, _text} ->
        # Don't exit, just send done and keep listening for more messages
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        subscription_loop(conn, chat_id)

      {:error, reason} ->
        event = %{type: "error", message: inspect(reason)}
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        subscription_loop(conn, chat_id)
    after
      # Send heartbeat every 30 seconds to keep connection alive
      30_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> subscription_loop(conn, chat_id)
          {:error, _} ->
            Server.unsubscribe(chat_id, self())
            conn
        end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
