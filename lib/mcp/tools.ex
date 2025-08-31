defmodule MCP.Tools do
  @moduledoc false

  @doc "Register or define AI.Tools modules for each MCP tool"
  @spec register_server_tools(String.t(), [map()]) :: :ok
  def register_server_tools(server, tools) when is_binary(server) and is_list(tools) do
    Enum.each(tools, fn tool_spec ->
      name = tool_spec["name"]
      mod = module_name(server, name)
      spec_data = default_spec(server, tool_spec)

      unless Code.ensure_loaded?(mod) do
        Module.create(mod, module_ast(spec_data, server, name), __ENV__)
      end
    end)

    :ok
  end

  # Build the module name under AI.Tools.MCP.<ServerCamel>.<ToolCamel>
  defp module_name(server, tool_name) do
    server_mod = Macro.camelize(server)
    tool_mod = Macro.camelize(tool_name)
    Module.concat([AI.Tools.MCP, server_mod, tool_mod])
  end

  # Construct default spec metadata for the dynamic tool module
  defp default_spec(server, tool_spec) do
    %{
      "name" => "#{server}:#{tool_spec["name"]}",
      "description" => Map.get(tool_spec, "description", ""),
      "parameters" => Map.get(tool_spec, "parameters", %{})
    }
  end

  # Generate AST for the dynamic tool module implementing AI.Tools callbacks
  defp module_ast(spec_data, server, tool_name) do
    quote do
      @moduledoc false
      @behaviour AI.Tools
      @compile {:no_warn_undefined, __MODULE__}

      @server unquote(server)
      @tool unquote(tool_name)
      @spec_data unquote(Macro.escape(spec_data))

      @impl true

      @impl true
      def async?, do: true

      @impl true
      def is_available?, do: true

      @impl true
      def spec, do: @spec_data

      @impl true
      def read_args(args), do: {:ok, args}

      @impl true
      def call(args) do
        timeout = min(Map.get(@spec_data, "timeout_ms", 30_000), 300_000)
        instance = MCP.Supervisor.instance_name(@server)

        case Hermes.Client.Base.call_tool(instance, @tool, args, timeout: timeout) do
          {:ok, res} -> {:ok, res}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end
end
