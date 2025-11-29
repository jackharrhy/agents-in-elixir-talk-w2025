# Pipe operator, string operations, list operations, map operations, etc.

"Elixir"
|> String.graphemes()
|> Enum.frequencies()

%{"E" => 1, "i" => 2, "l" => 1, "r" => 1, "x" => 1}

# ---

# Conditional logic in Elixir

num = 7

if rem(num, 2) == 0 do
  IO.puts("#{num} is even")
else
  IO.puts("#{num} is odd")
end

# ---

# Using cond for multiple conditions
grade = 85

result =
  cond do
    grade >= 90 -> "A"
    grade >= 80 -> "B"
    grade >= 70 -> "C"
    true -> "F"
  end

IO.puts("Grade: #{result}")

# ---

# Case statement in Elixir

value = {:ok, 42}

case value do
  {:ok, v} -> IO.puts("Value is #{v}")
  {:error, reason} -> IO.puts("Error: #{reason}")
  _ -> IO.puts("Unknown result")
end

# ---

# Raw Erlang processes

results =
  1..10
  |> Enum.map(fn n ->
    parent = self()

    # Spawn a raw Erlang process that sends back a computed result
    spawn(fn ->
      # Simulate some work, e.g., square the number and send result back
      result = n * n
      send(parent, {:done, n, result})
    end)
  end)

# Collect the results from the spawned processes
results =
  for _ <- 1..10 do
    receive do
      {:done, n, result} ->
        {n, result}
    end
  end

IO.inspect(Enum.sort(results))
# Output: [{1, 1}, {2, 4}, ..., {10, 100}]

# ---

defmodule SimpleStore do
  use GenServer

  def start_link(init \\ %{}), do: GenServer.start_link(__MODULE__, init, [])
  def put(pid, k, v), do: GenServer.cast(pid, {:put, k, v})
  def get(pid, k), do: GenServer.call(pid, {:get, k})
  def state(pid), do: GenServer.call(pid, :state)
  def clear(pid), do: GenServer.cast(pid, :clear)

  def init(s), do: {:ok, s}
  def handle_cast({:put, k, v}, s), do: {:noreply, Map.put(s, k, v)}
  def handle_cast(:clear, _), do: {:noreply, %{}}
  def handle_call({:get, k}, _, s), do: {:reply, Map.get(s, k), s}
  def handle_call(:state, _, s), do: {:reply, s, s}
end

# Usage
{:ok, s1} = SimpleStore.start_link()
{:ok, s2} = SimpleStore.start_link(%{demo: 1})

SimpleStore.put(s1, :a, 10)
SimpleStore.put(s2, :b, 20)

IO.inspect(SimpleStore.get(s1, :a))
IO.inspect(SimpleStore.get(s2, :b))

IO.inspect(SimpleStore.state(s1))
IO.inspect(SimpleStore.state(s2))

SimpleStore.clear(s1)
IO.inspect(SimpleStore.state(s1))

# ---

# Flaky GenServer

defmodule FlakyGenServer do
  use GenServer

  # Client API
  def start_link(name) do
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  def do_work(pid) do
    GenServer.cast(pid, :do_work)
  end

  # Server Callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_cast(:do_work, state) do
    # Randomly crash the process
    if :rand.uniform(10) == 1 do
      IO.puts("[#{inspect(self())}] Crashing randomly!")
      raise "Random failure!"
    else
      IO.puts("[#{inspect(self())}] Did the work successfully.")
      {:noreply, state}
    end
  end
end

defmodule DemoSupervisor do
  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    children = [
      %{
        id: :flaky1,
        start: {FlakyGenServer, :start_link, [:flaky1]},
        restart: :permanent
      },
      %{
        id: :flaky2,
        start: {FlakyGenServer, :start_link, [:flaky2]},
        restart: :permanent
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# Start the supervisor tree
{:ok, _sup_pid} = DemoSupervisor.start_link(nil)

# Send work to the flakey genservers, and observe random failures & restarts
flaky1 = Process.whereis(:flaky1)
flaky2 = Process.whereis(:flaky2)

for _ <- 1..15 do
  FlakyGenServer.do_work(flaky1)
  FlakyGenServer.do_work(flaky2)
  Process.sleep(200)
end

# ---

# Shell Chat GenServer

defmodule ShellChatGenServer do
  use GenServer

  @model "gpt-5-nano"
  @api "https://api.openai.com/v1/responses"

  def start_link(init_arg \\ %{}) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(state) do
    {:ok, Map.put(state, :prev_id, nil)}
  end

  # Public API
  def chat(input) do
    GenServer.call(__MODULE__, {:chat, input})
  end

  # GenServer callbacks
  def handle_call({:chat, user_msg}, _from, state) do
    prev_id = state[:prev_id]
    payload = chat_payload(user_msg, prev_id)

    headers = [
      {"Authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"},
      {"Content-Type", "application/json"}
    ]

    # Do the HTTP request
    {:ok, resp} = http_post(@api, payload, headers)
    %{"output" => output_list, "id" => new_id} = resp

    reply =
      output_list
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(& &1["content"])
      |> Enum.map(& &1["text"])
      |> Enum.join("\n\n")

    {:reply, reply, %{state | prev_id: new_id}}
  end

  # Helper to build request payload as a map
  defp chat_payload(user_msg, nil) do
    %{
      model: @model,
      input: user_msg
    }
  end

  defp chat_payload(user_msg, prev_id) do
    %{
      model: @model,
      input: user_msg,
      previous_response_id: prev_id
    }
  end

  # Use HTTPoison or Finch or Mint for HTTP, but use :httpc for no external deps
  defp http_post(url, payload, headers) do
    body = Jason.encode!(payload)
    http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    # :httpc.request returns {:ok, {{'HTTP/1.1', 200, 'OK'}, headers, body}}
    case :httpc.request(
           :post,
           {
             to_charlist(url),
             http_headers,
             "application/json",
             to_charlist(body)
           },
           [],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:error, "HTTP error #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Example usage loop (like the shell-interactive):
defmodule ShellChatREPL do
  def start do
    ShellChatGenServer.start_link()
    loop()
  end

  defp loop do
    user_msg = IO.gets("> ") |> to_string() |> String.trim()

    cond do
      user_msg in ["exit", "quit", ""] ->
        :ok

      true ->
        reply = ShellChatGenServer.chat(user_msg)
        IO.puts("\n" <> reply <> "\n")
        loop()
    end
  end
end

# To run interactively, uncomment:
# ShellChatREPL.start()
