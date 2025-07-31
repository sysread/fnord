defmodule Cmd.Tool do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec() do
    [
      tool: [
        name: "tool",
        about: "Performs a tool call",
        allow_unknown_args: true,
        subcommands: get_subcommands(),
        options: [
          project: Cmd.project_arg(),
          workers: Cmd.workers_arg(),
          tool: [
            value_name: "TOOL",
            long: "--tool",
            short: "-t",
            help: "The name of the tool to call; use --help to list options.",
            required: true
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, unknown) do
    with {:ok, tool} <- Map.fetch(opts, :tool),
         {:ok, tool_args} <- parse_tool_args(tool, unknown) do
      AI.Tools.perform_tool_call(tool, tool_args, AI.Tools.all_tools())
      |> case do
        {:ok, response} -> IO.puts(response)
        {:error, error} -> IO.puts(:stderr, "Error: #{error}")
      end
    else
      {:error, :unknown_tool, tool} ->
        IO.puts(:stderr, "Error: Unknown tool '#{tool}'")
        System.halt(1)

      error ->
        IO.puts(:stderr, "Error: #{inspect(error)}")
        System.halt(1)
    end
  end

  defp parse_tool_args(tool, args) do
    with {:ok, spec} <- AI.Tools.tool_spec(tool, AI.Tools.all_tools()) do
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
      multiple_option = if arg_spec.type == "array", do: [multiple: true], else: []

      opts =
        [
          long: long,
          help: help,
          required: required
        ] ++ multiple_option

      Keyword.put(acc, arg, opts)
    end)
  end

  defp get_subcommands() do
    tools = AI.Tools.all_tools()

    tools
    |> Enum.map(fn {tool, _module} ->
      spec = AI.Tools.tool_spec!(tool, tools)

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
