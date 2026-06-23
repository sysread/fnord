defmodule MCP.Tools do
  @moduledoc false

  use Agent

  @definition_tab :mcp_tool_definitions

  @doc "Start the MCP.Tools agent, registered in the current process tree"
  def start_link(_opts \\ []) do
    with {:ok, pid} <- Agent.start_link(fn -> %{} end) do
      Services.Instance.register(__MODULE__, pid)

      Services.Globals.ensure_shared_table(@definition_tab, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

      {:ok, pid}
    end
  end

  @doc "Register or define AI.Tools modules for each MCP tool"
  @spec register_server_tools(String.t(), [map()]) :: :ok
  def register_server_tools(server, tools) when is_binary(server) and is_list(tools) do
    Enum.each(tools, fn tool_spec ->
      name = tool_spec["name"]
      mod = module_name(server, name)
      spec_data = default_spec(server, tool_spec)
      tool_name = "#{server}_#{name}"

      # The modules are VM-global; serialize first-definition across the VM
      # to avoid duplicate Module.create/3 races under concurrent discovery.
      ensure_tool_module_defined(mod, spec_data, server, tool_name)

      # The tool_name => module index is tree-scoped, so it must be written
      # even when the module itself was defined by an earlier tree.
      Agent.update(instance(), &Map.put(&1, tool_name, mod))
    end)

    :ok
  end

  # Build the module name under AI.Tools.MCP.<ServerCamel>.<ToolCamel>
  defp module_name(server, tool_name) do
    server_mod = Macro.camelize(server)
    tool_mod = Macro.camelize(tool_name)
    Module.concat([AI.Tools.MCP, server_mod, tool_mod])
  end

  # Construct default spec metadata for the dynamic tool module. Emits the
  # flat Responses-API shape: %{type, name, description, parameters} at the
  # top level. AI.Tools.Params.normalize_spec/1 (the central validator)
  # expects this exact shape - nested chat-completions-style
  # %{function: %{...}} would fail loudly there. Keep this in sync if the
  # MCP `inputSchema` ever grows additional wrapper layers.
  defp default_spec(server, tool_spec) do
    input_schema = Map.get(tool_spec, "inputSchema", %{})

    # Ensure the parameters have a required field (even if empty)
    parameters = Map.put_new(input_schema, "required", [])

    desc = """
    #{Map.get(tool_spec, "description", "")}

    Note: This tool is provided by the MCP server, "#{server}".
    """

    %{
      type: "function",
      name: "#{server}_#{tool_spec["name"]}",
      description: String.trim(desc),
      parameters: parameters
    }
  end

  # Generated tool modules are VM-global, while the Agent state is tree-scoped.
  # The shared ETS table serializes first-definition and gives waiters a ready
  # signal before they publish the tree-local tool_name => module mapping.
  defp ensure_tool_module_defined(mod, spec_data, server, tool_name) do
    cond do
      Code.ensure_loaded?(mod) ->
        :ok

      claim_tool_definition(mod) == :owner ->
        define_tool_module(mod, spec_data, server, tool_name)

      true ->
        wait_for_tool_module(mod, spec_data, server, tool_name)
    end
  end

  defp claim_tool_definition(mod) do
    if :ets.insert_new(@definition_tab, {mod, :defining}) do
      :owner
    else
      :wait
    end
  end

  defp define_tool_module(mod, spec_data, server, tool_name) do
    try do
      Module.create(mod, module_ast(spec_data, server, tool_name), __ENV__)
      :ets.insert(@definition_tab, {mod, :ready})
      :ok
    rescue
      error ->
        :ets.delete(@definition_tab, mod)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        :ets.delete(@definition_tab, mod)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp wait_for_tool_module(mod, spec_data, server, tool_name) do
    cond do
      Code.ensure_loaded?(mod) ->
        :ok

      :ets.lookup(@definition_tab, mod) == [{mod, :ready}] ->
        :ok

      :ets.lookup(@definition_tab, mod) == [{mod, :defining}] ->
        Process.sleep(10)
        wait_for_tool_module(mod, spec_data, server, tool_name)

      true ->
        ensure_tool_module_defined(mod, spec_data, server, tool_name)
    end
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
        tool_name = Map.get(@spec_data, :name, @tool)

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
      def tool_call_failure_message(_args, _reason), do: :default

      @impl true
      def call(args) do
        timeout = min(Map.get(@spec_data, "timeout_ms", 30_000), 300_000)
        MCP.Client.call_tool(@server, @tool, args, timeout: timeout)
      end
    end
  end

  @doc "Get a map of tool name to module for all registered MCP tools"
  @spec module_map() :: %{String.t() => module()}
  def module_map do
    Agent.get(instance(), & &1)
  end

  defp instance(), do: Services.Instance.fetch!(__MODULE__)
end
