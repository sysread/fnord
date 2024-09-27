defmodule Scanner do
  @moduledoc """
  The `Scanner` module traverses a directory recursively, skipping hidden files
  and files that should be ignored based on a `.gitignore` file. It also skips
  binary files and files with a size of 0 bytes.
  """
  defstruct [:root, :callback]

  def new(root, callback) do
    %Scanner{
      root: root,
      callback: callback
    }
  end

  # Recursive function to traverse directories
  def scan(dir, callback) do
    if not File.exists?(dir) do
      {:error, "directory '#{dir}' does not exist"}
    else
      case File.ls(dir) do
        {:error, reason} ->
          {:error, "error accessing directory '#{dir}': #{reason}"}

        {:ok, files} ->
          Enum.each(files, fn file ->
            full_path = Path.join(dir, file)

            unless is_hidden_file?(full_path) or Git.is_ignored?(full_path) do
              case File.stat(full_path) do
                {:ok, %File.Stat{type: :directory}} ->
                  scan(full_path, callback)

                {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
                  unless is_binary_file?(full_path) do
                    callback.(full_path)
                  end

                {:ok, _} ->
                  :ok

                _ ->
                  :ok
              end
            end
          end)
      end
    end

    :ok
  end

  # Check if the file is hidden
  defp is_hidden_file?(file) do
    file |> Path.basename() |> String.starts_with?(".")
  end

  # Check if a file is binary by reading a portion of it
  defp is_binary_file?(file) do
    case File.read(file) do
      {:ok, content} -> String.contains?(content, <<0>>)
      _ -> false
    end
  end
end
