defmodule Ctags do
  @moduledoc """
  TODO:
  - get_callers
  - get_callees
  """

  @typedoc """
  Tag entry structure.

  ## Fields
    - `tagname`: The name of the tag.
    - `filename`: The name of the file where the tag is defined.
    - `ex_command`: The ex command to jump to the tag.
    - `kind`: The kind of the tag.
    - `language`: The language of the tag.
  """
  @type tag_entry :: %{
          tagname: String.t(),
          filename: String.t(),
          ex_command: String.t(),
          kind: String.t(),
          language: String.t()
        }

  @doc """
  Generates a new ctags file for all indexed files in the project.

  ## Parameters
    - `project`: The project name.
    - `output_file`: The path to the output file.

  ## Returns
    - `:ok` on success.
    - `{:error, reason}` on failure.

  ## Example
      iex> Ctags.generate_tags("myproject", "tags")
      :ok
  """
  def generate_tags(project, output_file) do
    ctags_path = find_ctags_binary()
    files = project |> Store.new() |> Store.list_files()
    args = ["--sort=yes", "--fields=+lK", "-f", output_file] ++ files

    case System.cmd(ctags_path, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, code} -> {:error, "ctags failed with exit code #{code}: #{error}"}
    end
  rescue
    e in RuntimeError -> {:error, e.message}
  end

  defp find_ctags_binary do
    case System.find_executable("ctags") do
      nil ->
        raise """
        ctags executable not found in PATH.

        Please install Universal Ctags.

        On macOS:

            brew install --HEAD universal-ctags/universal-ctags/universal-ctags

        On Ubuntu/Debian:

            sudo apt-get install universal-ctags

        """

      ctags_path ->
        ctags_path
    end
  end

  @doc """
  Searches for all tags matching the given tagname in the ctags file.

  ## Parameters
    - `ctags_file`: The path to the ctags file.
    - `tagname`: The name of the tag to search for.

  ## Returns
    - `{:ok, [tag_entry]}` if matching tags are found.
    - `:not_found` if no matching tags are found.
    - `{:error, reason}` if there is an error accessing the file or reading it.

  ## Example
      iex> Ctags.find_tags("tags", "hello")
      {
        :ok,
        [
          %{
            tagname: "hello",
            filename: "sample1.ex",
            ex_command: "/^  def hello do$/;",
            kind: "module",
            language: "Elixir"
          },
          %{
            tagname: "hello",
            filename: "sample2.ex",
            ex_command: "/^  def hello_world do$/;",
            kind: "module",
            language: "Elixir"
          }
        ]
      }
  """
  @spec find_tags(String.t(), String.t()) ::
          {:ok, [tag_entry]}
          | {:error, :tag_not_found}
          | {:error, :tag_file_not_found}
          | {:error, term}

  def find_tags(ctags_file, tagname) do
    try do
      ctags_file
      |> File.stream!(:line)
      # Drop preamble lines
      |> Stream.drop_while(&preamble_line?/1)
      # Drop non-matching lines before the tag
      |> Stream.drop_while(fn line ->
        case parse_tag_line(line) do
          {:ok, %{tagname: current_tagname}} -> current_tagname != tagname
          _ -> true
        end
      end)
      # Collect all matching tags
      |> Stream.transform([], fn line, acc ->
        case parse_tag_line(line) do
          {:ok, entry} when entry.tagname == tagname -> {[entry], acc}
          {:ok, entry} when entry.tagname < tagname -> {:halt, acc}
          _ -> {[], acc}
        end
      end)
      |> Enum.to_list()
      |> case do
        [] -> {:error, :tag_not_found}
        entries -> {:ok, entries}
      end
    rescue
      _ -> {:error, :tag_file_not_found}
    end
  end

  defp preamble_line?(line) do
    String.starts_with?(line, "!")
  end

  defp parse_tag_line(line) do
    # Remove any trailing newline characters
    line = String.trim(line)

    # Split the line into its main components
    case String.split(line, "\t") do
      [tagname, filename, ex_command | rest] ->
        # ex_command may contain patterns like '/^def foo$/'
        # Additional fields are provided after the third tab-separated value
        fields = parse_additional_fields(rest)

        ex_command = String.trim_trailing(ex_command, ";\"")

        # Build the tag entry map
        {:ok,
         Map.merge(
           %{
             tagname: tagname,
             filename: filename,
             ex_command: ex_command
           },
           fields
         )}

      _ ->
        :error
    end
  end

  defp parse_additional_fields(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case String.split(field, ":", parts: 2) do
        [key, value] ->
          Map.put(acc, String.to_atom(key), value)

        _ ->
          acc
      end
    end)
  end
end
