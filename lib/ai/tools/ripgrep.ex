defmodule AI.Tools.Ripgrep do
  @doc """
  This tool requires that ripgrep (rg) is installed and available in the PATH.
  """
  def is_available?() do
    System.find_executable("rg") |> is_nil() |> Kernel.not()
  end

  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args) do
    {"Searching project files", Jason.encode!(args)}
  end

  @impl AI.Tools
  def ui_note_on_result(args, result) do
    {"Searched project files",
     """
     Searched with: #{Jason.encode!(args)}
     Result:
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "ripgrep_search",
        description: "Searches the project directory using ripgrep.",
        parameters: %{
          type: "object",
          required: ["pattern"],
          properties: %{
            pattern: %{
              type: "string",
              description:
                "The pattern to search for (regex by default, or literal with fixed_strings)."
            },
            fixed_strings: %{
              type: "boolean",
              description:
                "Treat the pattern as a literal string instead of a regular expression.",
              default: false
            },
            ignore_case: %{
              type: "boolean",
              description: "Perform case-insensitive matching.",
              default: false
            },
            invert_match: %{
              type: "boolean",
              description: "Select non-matching lines.",
              default: false
            },
            glob: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Include or exclude files using glob patterns (e.g., '*.rs', '!Cargo.lock')."
            },
            hidden: %{
              type: "boolean",
              description: "Search hidden files and directories.",
              default: false
            },
            no_ignore: %{
              type: "boolean",
              description: "Don't respect .gitignore and other ignore files.",
              default: false
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_completion, args) do
    root = Store.get_project() |> Map.get(:source_root)
    args = atomize_keys(args)
    cmd = build_ripgrep_cmd(args)

    try do
      System.cmd("rg", cmd ++ [root], stderr_to_stdout: true)
      |> case do
        {output, 0} -> {:ok, output}
        {_output, 1} -> {:ok, "No files were matched"}
        {output, code} -> {:error, "ripgrep failed with exit code #{code}:\n#{output}"}
      end
    rescue
      e in ErlangError ->
        case e.original do
          :enoent ->
            {
              :error,
              """
              `rg` (ripgrep) is not installed or not in PATH.
              In your final response, instruct the user to install it to enhance your search capabilities.
              """
            }

          other ->
            {:error, "ripgrep execution error: #{inspect(other)}"}
        end
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp build_ripgrep_cmd(%{pattern: pattern} = args) do
    []
    |> append_flag(args[:fixed_strings], "--fixed-strings")
    |> append_flag(args[:ignore_case], "--ignore-case")
    |> append_flag(args[:invert_match], "--invert-match")
    |> append_flag(args[:hidden], "--hidden")
    |> append_flag(args[:no_ignore], "--no-ignore")
    |> append_list("--glob", args[:glob])
    |> Kernel.++([pattern])
  end

  defp append_flag(cmd, true, flag), do: cmd ++ [flag]
  defp append_flag(cmd, _, _), do: cmd

  defp append_list(cmd, _flag, nil), do: cmd

  defp append_list(cmd, flag, list) when is_binary(list) do
    cmd ++ [flag, list]
  end

  defp append_list(cmd, flag, list) when is_list(list) do
    Enum.reduce(list, cmd, fn item, acc -> acc ++ [flag, item] end)
  end
end
