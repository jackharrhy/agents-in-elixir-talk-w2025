defmodule Agent.Command.Executor do
  @moduledoc """
  Safe command execution GenServer.
  Runs whitelisted shell commands with timeout protection.
  """
  use GenServer

  @allowed_commands ~w(
    ls pwd whoami cat id uname hostname date uptime dig curl head tail wc grep echo env
    pandoc mkdir mktemp
  )
  @timeout 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Execute a shell command if it's in the whitelist.
  Returns %{success: true/false, stdout: ..., stderr: ..., error: ...}

  Options:
    - :work_dir - directory to run the command from (default: current dir)
  """
  def execute(command, opts \\ []) do
    work_dir = Keyword.get(opts, :work_dir)
    GenServer.call(__MODULE__, {:execute, command, work_dir}, @timeout + 5_000)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:execute, command, work_dir}, _from, state) do
    result = do_execute(command, work_dir)
    {:reply, result, state}
  end

  # Private

  defp do_execute(command, work_dir) do
    base_command =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()

    if base_command in @allowed_commands do
      run_command(command, work_dir)
    else
      %{
        success: false,
        error:
          "Command '#{base_command}' is not allowed. Allowed: #{Enum.join(@allowed_commands, ", ")}"
      }
    end
  end

  defp run_command(command, work_dir) do
    task =
      Task.async(fn ->
        opts = [stderr_to_stdout: false]
        opts = if work_dir, do: Keyword.put(opts, :cd, work_dir), else: opts

        case System.cmd("sh", ["-c", command], opts) do
          {stdout, 0} ->
            %{success: true, stdout: stdout}

          {stdout, exit_code} ->
            %{success: false, stdout: stdout, error: "Exit code: #{exit_code}"}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        %{success: false, error: "Command timed out after #{div(@timeout, 1000)} seconds"}
    end
  rescue
    e ->
      %{success: false, error: Exception.message(e)}
  end
end
