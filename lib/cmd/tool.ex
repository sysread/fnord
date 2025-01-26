defmodule Cmd.Tool do
  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      tool: [
        name: "tool",
        about: "Performs a tool call",
        allow_unknown_args: true,
        subcommands: get_subcommands(),
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name"
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Limits the number of concurrent OpenAI requests",
            parser: :integer,
            default: Cmd.default_workers()
          ],
          tool: [
            value_name: "TOOL",
            long: "--tool",
            short: "-t",
            help: "The name of the tool to call; use --help to list options."
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, unknown) do
    with {:ok, tool} <- Map.fetch(opts, :tool),
         {:ok, tool_args} <- parse_tool_args(tool, unknown),
         _ <- Store.get_project() do
      state = %{ai: AI.new()}

      AI.Tools.perform_tool_call(state, tool, tool_args)
      |> case do
        {:ok, response} -> IO.puts(response)
        {:error, error} -> IO.puts(:stderr, "Error: #{error}")
      end
    end
  end

  defp parse_tool_args(tool, args) do
    with {:ok, spec} <- AI.Tools.tool_spec(tool) do
      build_optimus(tool, spec)
      |> Optimus.parse!(args)
      |> case do
        %{options: args} ->
          args
          |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
          |> Map.new()
          |> then(&{:ok, &1})

        other ->
          other
      end
    end
  end

  defp build_optimus(tool, spec) do
    Optimus.new!(
      name: tool,
      description: spec.function.description,
      options: tool_spec_to_optimus_spec(spec)
    )
  end

  defp tool_spec_to_optimus_spec(spec) do
    %{required: required, properties: args} =
      spec
      |> Map.get(:function)
      |> Map.get(:parameters)

    is_required? =
      required
      |> Enum.map(fn arg -> String.to_atom(arg) end)
      |> Enum.map(fn arg -> {arg, true} end)
      |> Map.new()

    args
    |> Enum.reduce([], fn {arg, arg_spec}, acc ->
      long = "--#{arg}"
      help = arg_spec.description
      required = Map.get(is_required?, arg, false)

      Keyword.put(acc, arg,
        long: long,
        help: help,
        required: required
      )
    end)
  end

  defp get_subcommands() do
    AI.Tools.tools()
    |> Enum.map(fn {tool, _module} ->
      spec = AI.Tools.tool_spec!(tool)

      desc =
        spec.function.description
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.join(" ")

      {String.to_atom(tool),
       [
         name: tool,
         about: desc,
         options: tool_spec_to_optimus_spec(spec)
       ]}
    end)
  end
end