defmodule Scanner do
  @moduledoc """
  The `Scanner` module traverses a directory recursively, skipping hidden files
  and files that should be ignored based on a `.gitignore` file. It also skips
  binary files and files with a size of 0 bytes.
  """
  defstruct [:root, :callback]

  @doc """
  Create a new `Scanner` struct.
  """
  def new(root, callback) do
    # Ensure root is full, absolute path
    root = Path.expand(root)

    %Scanner{
      root: root,
      callback: callback
    }
  end

  @doc """
  Recursively scan the directory and call the callback function for each file.
  """
  def scan(scanner, dir \\ nil) do
    dir =
      if is_nil(dir) do
        scanner.root
      else
        dir
      end

    if not File.exists?(dir) do
      {:error, "directory '#{dir}' does not exist"}
    else
      case File.ls(dir) do
        {:error, reason} ->
          {:error, "error accessing directory '#{dir}': #{reason}"}

        {:ok, files} ->
          Enum.each(files, fn file ->
            full_path = Path.join(dir, file)

            unless is_hidden_file?(full_path) or Git.is_ignored?(full_path, scanner.root) do
              case File.stat(full_path) do
                {:ok, %File.Stat{type: :directory}} ->
                  scan(scanner, full_path)

                {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
                  unless is_binary_file?(full_path) do
                    scanner.callback.(full_path)
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
