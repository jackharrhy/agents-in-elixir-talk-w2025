defmodule AgentWeb.FileController do
  use Phoenix.Controller, formats: [:json]

  alias Agent.Chat.Server

  def upload(conn, %{"id" => id, "file" => upload}) do
    case Server.get_or_start(id) do
      {:ok, _pid} ->
        work_dir = Server.get_work_dir(id)
        dest_path = Path.join(work_dir, upload.filename)

        case File.cp(upload.path, dest_path) do
          :ok ->
            # Notify chat about the uploaded file
            Server.add_file_context(id, upload.filename)

            json(conn, %{
              success: true,
              filename: upload.filename,
              path: dest_path
            })

          {:error, reason} ->
            conn
            |> put_status(500)
            |> json(%{success: false, error: "Failed to save file: #{inspect(reason)}"})
        end

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to start chat: #{inspect(reason)}"})
    end
  end
end
