defmodule Agent.Files.Processor do
  @moduledoc """
  File upload processing with pandoc conversion.
  Converts various document formats to plain text for chat context.
  """

  @uploads_dir "priv/uploads"
  @timeout 60_000

  @doc """
  Process an uploaded file and extract text content.
  Uses pandoc to convert supported formats to plain text.
  """
  def process_upload(%Plug.Upload{} = upload) do
    File.mkdir_p!(@uploads_dir)

    # Save file temporarily
    dest_path = Path.join(@uploads_dir, "#{:erlang.unique_integer([:positive])}_#{upload.filename}")
    File.cp!(upload.path, dest_path)

    try do
      result = extract_text(dest_path, upload.filename)
      File.rm(dest_path)
      result
    rescue
      e ->
        File.rm(dest_path)
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Extract text from a file using pandoc or direct read.
  """
  def extract_text(file_path, filename) do
    ext = Path.extname(filename) |> String.downcase()

    cond do
      ext in ~w(.txt .md .markdown .json .csv .xml .html .css .js .ts .ex .exs .py .rb .go .rs .c .h .cpp .java) ->
        # Plain text files - read directly
        case File.read(file_path) do
          {:ok, content} -> {:ok, filename, content}
          {:error, reason} -> {:error, "Failed to read file: #{reason}"}
        end

      ext in ~w(.pdf .docx .doc .odt .rtf .epub .rst .tex .org) ->
        # Use pandoc for conversion
        convert_with_pandoc(file_path, filename)

      true ->
        {:error, "Unsupported file type: #{ext}"}
    end
  end

  defp convert_with_pandoc(file_path, filename) do
    task =
      Task.async(fn ->
        case System.cmd("pandoc", ["-t", "plain", "--wrap=none", file_path],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            {:ok, filename, output}

          {error, _code} ->
            {:error, "Pandoc conversion failed: #{error}"}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, "File conversion timed out"}
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        {:error, "Pandoc is not installed. Please install pandoc to process this file type."}
      else
        {:error, "Conversion error: #{inspect(e)}"}
      end
  end
end
