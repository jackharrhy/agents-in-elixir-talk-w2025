defmodule Agent.AI.Client do
  @moduledoc """
  OpenAI API client with streaming support.
  Uses the Responses API with tool calling.
  """

  @model "gpt-5-chat-latest"

  def stream_completion(messages, tools, system_prompt) do
    api_key = System.get_env("OPENAI_API_KEY") || Application.get_env(:agent, :openai_api_key)

    unless api_key do
      {:error, "OPENAI_API_KEY not set"}
    else
      do_stream(messages, tools, system_prompt, api_key)
    end
  end

  defp do_stream(messages, tools, system_prompt, api_key) do
    # Format messages for OpenAI API
    formatted_messages = format_messages(messages, system_prompt)

    body =
      %{
        model: @model,
        messages: formatted_messages,
        tools: Enum.map(tools, &format_tool/1),
        stream: true
      }
      |> Jason.encode!()

    # Stream the response
    stream =
      Stream.resource(
        fn -> start_stream(body, api_key) end,
        &next_chunk/1,
        &close_stream/1
      )
      |> Stream.flat_map(&parse_sse_line/1)

    {:ok, stream}
  end

  defp format_messages(messages, system_prompt) do
    system_msg = %{role: "system", content: system_prompt}

    formatted =
      Enum.map(messages, fn msg ->
        case msg do
          %{role: "tool", tool_call_id: id, content: content} ->
            %{role: "tool", tool_call_id: id, content: content}

          %{role: "assistant", tool_calls: tool_calls} = m ->
            base = %{role: "assistant", content: m[:content] || ""}

            if tool_calls && tool_calls != [] do
              Map.put(base, :tool_calls, tool_calls)
            else
              base
            end

          %{role: role, content: content} ->
            %{role: role, content: content}

          # Handle atom keys
          %{} = m ->
            %{role: to_string(m[:role] || m["role"]), content: m[:content] || m["content"] || ""}
        end
      end)

    [system_msg | formatted]
  end

  defp format_tool(tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    }
  end

  defp start_stream(body, api_key) do
    {:ok, conn} = Mint.HTTP.connect(:https, "api.openai.com", 443)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    {:ok, conn, request_ref} =
      Mint.HTTP.request(conn, "POST", "/v1/chat/completions", headers, body)

    %{
      conn: conn,
      request_ref: request_ref,
      buffer: "",
      done: false,
      tool_calls: %{}
    }
  end

  defp next_chunk(%{done: true} = state) do
    {:halt, state}
  end

  defp next_chunk(state) do
    receive do
      message ->
        case Mint.HTTP.stream(state.conn, message) do
          {:ok, conn, responses} ->
            state = %{state | conn: conn}
            process_responses(responses, state)

          {:error, _conn, _reason, _responses} ->
            {:halt, state}
        end
    after
      30_000 ->
        {:halt, state}
    end
  end

  defp process_responses(responses, state) do
    {events, state} =
      Enum.reduce(responses, {[], state}, fn response, {events_acc, state_acc} ->
        case response do
          {:data, _ref, data} ->
            {new_events, new_state} = parse_data(data, state_acc)
            {events_acc ++ new_events, new_state}

          {:done, _ref} ->
            {events_acc, %{state_acc | done: true}}

          _ ->
            {events_acc, state_acc}
        end
      end)

    {events, state}
  end

  defp parse_data(data, state) do
    buffer = state.buffer <> data
    lines = String.split(buffer, "\n")
    {complete_lines, [remaining]} = Enum.split(lines, -1)

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))
      |> Enum.filter(&(&1 != "[DONE]" and &1 != ""))

    {events, %{state | buffer: remaining}}
  end

  defp close_stream(state) do
    Mint.HTTP.close(state.conn)
  end

  defp parse_sse_line(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"choices" => [%{"delta" => delta} | _]}} ->
        parse_delta(delta)

      _ ->
        []
    end
  end

  defp parse_delta(%{"content" => content}) when is_binary(content) and content != "" do
    [{:text, content}]
  end

  defp parse_delta(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.flat_map(tool_calls, fn tc ->
      index = tc["index"]

      cond do
        # New tool call
        tc["id"] != nil ->
          [
            {:tool_call,
             %{
               id: tc["id"],
               name: tc["function"]["name"],
               arguments: tc["function"]["arguments"] || ""
             }}
          ]

        # Tool call argument delta
        tc["function"]["arguments"] != nil ->
          [{:tool_call_delta, index, tc["function"]["arguments"]}]

        true ->
          []
      end
    end)
  end

  defp parse_delta(_), do: []
end
