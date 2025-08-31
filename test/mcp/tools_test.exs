defmodule MCP.ToolsTest do
  @moduledoc false
  use Fnord.TestCase, async: false

  setup do
    # Stub Hermes.Client.Base.call_tool/4 with meck
    :meck.new(Hermes.Client.Base, [:non_strict, :passthrough])

    :meck.expect(Hermes.Client.Base, :call_tool, fn instance, "foo", args, opts ->
      {:ok, %{instance: instance, received: args, opts: opts}}
    end)

    on_exit(fn ->
      try do
        :meck.unload(Hermes.Client.Base)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "register_server_tools defines dynamic modules and call works" do
    tool_specs = [
      %{"name" => "foo", "description" => "desc", "parameters" => %{"a" => "b"}}
    ]

    # Register dynamic tool modules for server "srv"
    assert :ok == MCP.Tools.register_server_tools("srv", tool_specs)

    server = "srv"
    tool = "foo"

    mod = ["AI", "Tools", "MCP", Macro.camelize(server), Macro.camelize(tool)] |> Module.concat()

    assert Code.ensure_loaded?(mod)

    expected_spec = %{
      "name" => "srv:foo",
      "description" => "desc",
      "parameters" => %{"a" => "b"}
    }

    assert function_exported?(mod, :spec, 0)
    assert apply(mod, :spec, []) == expected_spec

    args = %{"x" => 1}
    assert function_exported?(mod, :call, 1)
    assert {:ok, result} = apply(mod, :call, [args])

    assert result.instance == MCP.Supervisor.instance_name("srv")
    assert result.received == args
    assert Keyword.has_key?(result.opts, :timeout)
    assert is_integer(Keyword.get(result.opts, :timeout))
  end
end
