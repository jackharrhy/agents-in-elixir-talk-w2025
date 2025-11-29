defmodule Agent.Chat.Server do
  @moduledoc """
  GenServer for individual chat sessions.
  Manages conversation state and coordinates with AI client.
  """
  use GenServer, restart: :temporary

  alias Agent.Chat.Store
  alias Agent.AI.Client
  alias Agent.Command.Executor

  @idle_timeout :timer.minutes(30)

  defstruct [
    :id,
    :title,
    :messages,
    :created_at,
    :work_dir,
    subscribers: [],
    stream_buffer: [],
    streaming: false
  ]

  # Client API

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  def via(id) do
    {:via, Registry, {Agent.Chat.Registry, id}}
  end

  def get_or_start(id) do
    case Registry.lookup(Agent.Chat.Registry, id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(Agent.Chat.Supervisor, {__MODULE__, id})
    end
  end

  def exists?(id) do
    case Registry.lookup(Agent.Chat.Registry, id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def get_state(id) do
    GenServer.call(via(id), :get_state)
  end

  def get_work_dir(id) do
    GenServer.call(via(id), :get_work_dir)
  end

  def send_message(id, content, stream_to) do
    GenServer.cast(via(id), {:send_message, content, stream_to})
  end

  def subscribe(id, subscriber_pid) do
    GenServer.call(via(id), {:subscribe, subscriber_pid})
  end

  def unsubscribe(id, subscriber_pid) do
    GenServer.cast(via(id), {:unsubscribe, subscriber_pid})
  end

  def add_file_context(id, filename) do
    GenServer.cast(via(id), {:add_file_context, filename})
  end

  # Server callbacks

  @impl true
  def init(id) do
    # Create a unique working directory for this chat
    work_dir =
      Path.join(System.tmp_dir!(), "agent_chat_#{id}_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(work_dir)

    state =
      case Store.get_chat(id) do
        {:ok, data} ->
          %__MODULE__{
            id: id,
            title: data.title,
            messages: data.messages,
            created_at: data.created_at,
            work_dir: work_dir
          }

        {:error, :not_found} ->
          # This shouldn't happen if we create via ChatController
          title = "Chat #{id}"
          {:ok, data} = Store.create_chat(id, title)

          %__MODULE__{
            id: id,
            title: title,
            messages: [],
            created_at: data.created_at,
            work_dir: work_dir
          }
      end

    {:ok, state, @idle_timeout}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up the working directory
    if state.work_dir && File.exists?(state.work_dir) do
      File.rm_rf(state.work_dir)
    end

    :ok
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state, @idle_timeout}
  end

  @impl true
  def handle_call(:get_work_dir, _from, state) do
    {:reply, state.work_dir, state, @idle_timeout}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Monitor the subscriber process
    ref = Process.monitor(pid)
    subscribers = [{pid, ref} | state.subscribers]
    state = %{state | subscribers: subscribers}

    # Replay buffered events if streaming is in progress
    if state.streaming do
      Enum.each(state.stream_buffer, fn event ->
        send(pid, event)
      end)
    end

    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {to_remove, remaining} = Enum.split_with(state.subscribers, fn {p, _ref} -> p == pid end)

    Enum.each(to_remove, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)

    {:noreply, %{state | subscribers: remaining}, @idle_timeout}
  end

  @impl true
  def handle_cast({:send_message, content, stream_to}, state) do
    # Add subscriber if not already subscribed
    state =
      if Enum.any?(state.subscribers, fn {p, _} -> p == stream_to end) do
        state
      else
        ref = Process.monitor(stream_to)
        %{state | subscribers: [{stream_to, ref} | state.subscribers]}
      end

    # Add user message
    user_msg = %{role: "user", content: content}
    messages = state.messages ++ [user_msg]

    # Update title from first message if needed
    state =
      if state.title == "New Chat" and length(state.messages) == 0 do
        title = String.slice(content, 0, 50)
        Store.update_title(state.id, title)
        %{state | title: title}
      else
        state
      end

    # Clear buffer and mark as streaming, broadcast user message to all subscribers
    user_event = {:user_message, content}
    state = %{state | messages: messages, stream_buffer: [user_event], streaming: true}
    Store.save_messages(state.id, messages)

    # Broadcast user message to all subscribers
    Enum.each(state.subscribers, fn {pid, _ref} ->
      send(pid, user_event)
    end)

    # Stream AI response - sends events back to this GenServer
    work_dir = state.work_dir
    server_pid = self()

    spawn_link(fn ->
      stream_ai_response(messages, server_pid, state.id, work_dir)
    end)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:stream_event, event}, state) do
    # Buffer the event and broadcast to all subscribers
    state = %{state | stream_buffer: state.stream_buffer ++ [event]}

    Enum.each(state.subscribers, fn {pid, _ref} ->
      send(pid, event)
    end)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_cast(:stream_done, state) do
    # Mark streaming as complete, keep buffer for late subscribers
    {:noreply, %{state | streaming: false}, @idle_timeout}
  end

  @impl true
  def handle_cast({:add_file_context, filename}, state) do
    system_msg = %{
      role: "user",
      content:
        "[File uploaded to working directory: #{filename}] - You can use commands like `cat`, `head`, or `ls` to inspect it."
    }

    messages = state.messages ++ [system_msg]
    state = %{state | messages: messages}
    Store.save_messages(state.id, messages)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:append_assistant_message, content}, state) do
    assistant_msg = %{role: "assistant", content: content}
    messages = state.messages ++ [assistant_msg]
    state = %{state | messages: messages}
    Store.save_messages(state.id, messages)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:save_messages, messages}, state) do
    state = %{state | messages: messages}
    Store.save_messages(state.id, messages)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    # Gracefully shutdown after idle timeout
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Remove dead subscriber
    subscribers = Enum.reject(state.subscribers, fn {p, r} -> p == pid or r == ref end)
    {:noreply, %{state | subscribers: subscribers}, @idle_timeout}
  end

  # Private

  defp stream_ai_response(messages, stream_to, chat_id, work_dir) do
    # Define the tool for command execution
    tools = [
      %{
        type: "function",
        name: "execute_command",
        description:
          "Execute a shell command. Only whitelisted commands allowed: ls, pwd, whoami, cat, id, uname, hostname, date, uptime, dig, curl, head, tail, wc, grep, echo",
        parameters: %{
          type: "object",
          properties: %{
            command: %{
              type: "string",
              description:
                "Full command with arguments, e.g. 'ls -la' or 'curl -s https://example.com'"
            }
          },
          required: ["command"]
        }
      }
    ]

    system_prompt = """
    You are a helpful assistant that can execute shell commands on the user's system.
    You are currently working in directory: #{work_dir}

    When the user asks about files, directories, system info, or network queries:
    - Use the execute_command tool to run appropriate commands
    - You can pass arguments to commands (e.g., "ls -la", "curl -s https://example.com", "dig google.com")
    - After seeing command output, explain the results to the user

    For network queries:
    - Use "dig" for DNS lookups
    - Use "curl" for HTTP requests

    Be concise and helpful. Only execute commands when needed.
    """

    run_agent_loop(messages, tools, system_prompt, stream_to, chat_id, work_dir, 0)
  end

  defp run_agent_loop(messages, tools, system_prompt, stream_to, chat_id, work_dir, step)
       when step < 10 do
    case Client.stream_completion(messages, tools, system_prompt) do
      {:ok, stream} ->
        {text, tool_calls} = process_stream(stream, stream_to)

        if tool_calls != [] do
          # Execute tool calls and continue loop
          tool_results =
            Enum.map(tool_calls, fn tool_call ->
              result = execute_tool(tool_call, stream_to, work_dir)
              %{role: "tool", tool_call_id: tool_call.id, content: Jason.encode!(result)}
            end)

          # Add assistant message with tool calls and tool results
          assistant_msg = %{
            role: "assistant",
            content: text,
            tool_calls:
              Enum.map(tool_calls, fn tc ->
                %{
                  id: tc.id,
                  type: "function",
                  function: %{name: tc.name, arguments: tc.arguments}
                }
              end)
          }

          new_messages = messages ++ [assistant_msg] ++ tool_results

          # Save intermediate messages (tool calls + results)
          GenServer.cast(via(chat_id), {:save_messages, new_messages})

          run_agent_loop(
            new_messages,
            tools,
            system_prompt,
            stream_to,
            chat_id,
            work_dir,
            step + 1
          )
        else
          # No tool calls, we're done
          GenServer.cast(stream_to, {:stream_event, {:done, text}})
          GenServer.cast(stream_to, :stream_done)

          # Save final assistant message
          final_messages = messages ++ [%{role: "assistant", content: text}]
          GenServer.cast(via(chat_id), {:save_messages, final_messages})
        end

      {:error, reason} ->
        GenServer.cast(stream_to, {:stream_event, {:error, reason}})
        GenServer.cast(stream_to, :stream_done)
    end
  end

  defp run_agent_loop(_messages, _tools, _system_prompt, stream_to, _chat_id, _work_dir, _step) do
    GenServer.cast(stream_to, {:stream_event, {:error, "Max steps reached"}})
    GenServer.cast(stream_to, :stream_done)
  end

  defp process_stream(stream, stream_to) do
    # Accumulate tool calls with their arguments
    # tool_calls_map: %{index => %{id, name, arguments}}
    {text, tool_calls_map} =
      Enum.reduce(stream, {"", %{}}, fn event, {text_acc, tc_map} ->
        case event do
          {:text, delta} ->
            GenServer.cast(stream_to, {:stream_event, {:text_delta, delta}})
            {text_acc <> delta, tc_map}

          {:tool_call, tool_call} ->
            # Store initial tool call, we'll send it when arguments are complete
            index = map_size(tc_map)
            tc_map = Map.put(tc_map, index, tool_call)
            {text_acc, tc_map}

          {:tool_call_delta, index, delta} ->
            # Accumulate arguments
            tc_map =
              Map.update(tc_map, index, %{arguments: delta}, fn tc ->
                %{tc | arguments: (tc.arguments || "") <> delta}
              end)

            {text_acc, tc_map}

          _ ->
            {text_acc, tc_map}
        end
      end)

    # Now send complete tool calls to the controller
    tool_calls =
      tool_calls_map
      |> Map.values()
      |> Enum.filter(&(&1.id != nil))

    Enum.each(tool_calls, fn tc ->
      GenServer.cast(stream_to, {:stream_event, {:tool_call, tc}})
    end)

    {text, tool_calls}
  end

  defp execute_tool(
         %{name: "execute_command", arguments: args_json} = tool_call,
         stream_to,
         work_dir
       ) do
    case Jason.decode(args_json) do
      {:ok, %{"command" => command}} ->
        result = Executor.execute(command, work_dir: work_dir)
        GenServer.cast(stream_to, {:stream_event, {:tool_result, tool_call.id, result}})
        result

      _ ->
        %{success: false, error: "Invalid arguments"}
    end
  end

  defp execute_tool(tool_call, stream_to, _work_dir) do
    result = %{success: false, error: "Unknown tool: #{tool_call.name}"}
    GenServer.cast(stream_to, {:stream_event, {:tool_result, tool_call.id, result}})
    result
  end
end
