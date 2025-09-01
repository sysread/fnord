defmodule MCP.Tools do
  @moduledoc false

  use Agent

  @doc "Start the MCP.Tools agent"
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Register or define AI.Tools modules for each MCP tool"
  @spec register_server_tools(String.t(), [map()]) :: :ok
  def register_server_tools(server, tools) when is_binary(server) and is_list(tools) do
    ensure_started()

    Enum.each(tools, fn tool_spec ->
      name = tool_spec["name"]
      mod = module_name(server, name)
      spec_data = default_spec(server, tool_spec)
      tool_name = "#{server}_#{name}"

      unless Code.ensure_loaded?(mod) do
        Module.create(mod, module_ast(spec_data, server, name), __ENV__)
        # Track the module for later retrieval
        Agent.update(__MODULE__, &Map.put(&1, tool_name, mod))
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
    input_schema = Map.get(tool_spec, "inputSchema", %{})

    # Ensure the parameters have a required field (even if empty)
    parameters = Map.put_new(input_schema, "required", [])

    %{
      type: "function",
      function: %{
        name: "#{server}_#{tool_spec["name"]}",
        description: Map.get(tool_spec, "description", ""),
        parameters: parameters
      }
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
      def ui_note_on_request(args) do
        tool_name = Map.get(@spec_data.function, :name, @tool)

        case Map.keys(args) do
          [] -> "Calling #{tool_name}"
          keys -> "Calling #{tool_name} with #{Enum.join(keys, ", ")}"
        end
      end

      @impl true
      def ui_note_on_result(_args, result) do
        case result do
          {:ok, data} when is_map(data) ->
            case Map.get(data, "content") do
              [%{"text" => text}] when is_binary(text) ->
                if String.length(text) > 100 do
                  {"Result", String.slice(text, 0, 97) <> "..."}
                else
                  {"Result", text}
                end

              content when is_list(content) ->
                {"Result", "#{length(content)} items"}

              _ ->
                {"Result", "Success"}
            end

          {:ok, text} when is_binary(text) ->
            if String.length(text) > 100 do
              {"Result", String.slice(text, 0, 97) <> "..."}
            else
              {"Result", text}
            end

          {:error, reason} ->
            {"Error", inspect(reason)}

          _ ->
            nil
        end
      end

      @impl true
      def call(args) do
        timeout = min(Map.get(@spec_data, "timeout_ms", 30_000), 300_000)
        supervisor = MCP.Supervisor.instance_name(@server)

        # Get the client process from the supervisor
        try do
          children = Supervisor.which_children(supervisor)

          case List.keyfind(children, Hermes.Client.Base, 0) do
            {Hermes.Client.Base, client_pid, _, _} when is_pid(client_pid) ->
              case Hermes.Client.Base.call_tool(client_pid, @tool, args, timeout: timeout) do
                {:ok, %Hermes.MCP.Response{result: result}} -> {:ok, result}
                {:ok, res} -> {:ok, res}
                {:error, reason} -> {:error, reason}
              end

            _ ->
              {:error, "MCP client not available"}
          end
        catch
          :exit, _ -> {:error, "MCP client not available"}
        end
      end
    end
  end

  @doc "Get a map of tool name to module for all registered MCP tools"
  @spec module_map() :: %{String.t() => module()}
  def module_map do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  # Ensure the agent is started
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _ -> :ok
    end
  end
end
