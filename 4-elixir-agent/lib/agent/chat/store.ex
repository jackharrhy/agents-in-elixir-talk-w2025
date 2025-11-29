defmodule Agent.Chat.Store do
  @moduledoc """
  DETS-backed persistence for chat data.
  Stores chat metadata and messages, survives server restarts.
  """
  use GenServer

  @table :chats

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Client API

  def list_chats do
    GenServer.call(__MODULE__, :list_chats)
  end

  def get_chat(id) do
    GenServer.call(__MODULE__, {:get_chat, id})
  end

  def create_chat(id, title) do
    GenServer.call(__MODULE__, {:create_chat, id, title})
  end

  def save_messages(id, messages) do
    GenServer.cast(__MODULE__, {:save_messages, id, messages})
  end

  def update_title(id, title) do
    GenServer.cast(__MODULE__, {:update_title, id, title})
  end

  def delete_chat(id) do
    GenServer.call(__MODULE__, {:delete_chat, id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    dets_path = Application.get_env(:agent, :dets_path, "priv/data/chats.dets")
    File.mkdir_p!(Path.dirname(dets_path))

    {:ok, @table} = :dets.open_file(@table, file: String.to_charlist(dets_path), type: :set)

    {:ok, %{table: @table}}
  end

  @impl true
  def handle_call(:list_chats, _from, state) do
    chats =
      :dets.foldl(
        fn {id, data}, acc ->
          [%{id: id, title: data.title, created_at: data.created_at} | acc]
        end,
        [],
        @table
      )
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:reply, chats, state}
  end

  @impl true
  def handle_call({:get_chat, id}, _from, state) do
    result =
      case :dets.lookup(@table, id) do
        [{^id, data}] -> {:ok, data}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_chat, id, title}, _from, state) do
    data = %{
      title: title,
      messages: [],
      created_at: DateTime.utc_now()
    }

    :ok = :dets.insert(@table, {id, data})
    :dets.sync(@table)

    {:reply, {:ok, data}, state}
  end

  @impl true
  def handle_call({:delete_chat, id}, _from, state) do
    :ok = :dets.delete(@table, id)
    :dets.sync(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:save_messages, id, messages}, state) do
    case :dets.lookup(@table, id) do
      [{^id, data}] ->
        updated = %{data | messages: messages}
        :dets.insert(@table, {id, updated})
        :dets.sync(@table)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_title, id, title}, state) do
    case :dets.lookup(@table, id) do
      [{^id, data}] ->
        updated = %{data | title: title}
        :dets.insert(@table, {id, updated})
        :dets.sync(@table)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
  end
end
