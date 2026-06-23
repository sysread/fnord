defmodule MCP.ToolsTest do
  @moduledoc false
  use Fnord.TestCase, async: false

  setup do
    :ok
  end

  defp unique_server_name do
    "srv_#{System.unique_integer([:positive])}"
  end

  test "register_server_tools defines dynamic modules with correct specs" do
    server = unique_server_name()

    tool_specs = [
      %{"name" => "foo", "description" => "desc", "inputSchema" => %{"a" => "b"}}
    ]

    assert :ok == MCP.Tools.register_server_tools(server, tool_specs)

    tool = "foo"

    mod = ["AI", "Tools", "MCP", Macro.camelize(server), Macro.camelize(tool)] |> Module.concat()

    assert Code.ensure_loaded?(mod)

    expected_spec = %{
      type: "function",
      name: "#{server}_foo",
      description:
        """
        desc

        Note: This tool is provided by the MCP server, "#{server}".
        """
        |> String.trim(),
      parameters: %{"a" => "b", "required" => []}
    }

    assert function_exported?(mod, :spec, 0)
    assert apply(mod, :spec, []) == expected_spec

    # Verify all required AI.Tools callbacks are implemented
    assert function_exported?(mod, :async?, 0)
    assert function_exported?(mod, :is_available?, 0)
    assert function_exported?(mod, :read_args, 1)
    assert function_exported?(mod, :ui_note_on_request, 1)
    assert function_exported?(mod, :ui_note_on_result, 2)
    assert function_exported?(mod, :call, 1)

    # Test the callbacks that don't require MCP infrastructure
    assert apply(mod, :async?, []) == true
    assert apply(mod, :is_available?, []) == true
    assert apply(mod, :read_args, [%{"test" => 1}]) == {:ok, %{"test" => 1}}

    # Test UI note functions
    note = apply(mod, :ui_note_on_request, [%{"arg1" => "val1"}])
    assert is_binary(note)
    assert note =~ "#{server}_foo"
  end

  test "register_server_tools handles concurrent registration for same module" do
    server = unique_server_name()

    tool_specs = [
      %{"name" => "foo", "description" => "desc", "inputSchema" => %{"a" => "b"}}
    ]

    tasks =
      for _ <- 1..10 do
        Services.Globals.Spawn.async(fn ->
          MCP.Tools.register_server_tools(server, tool_specs)
        end)
      end

    assert Enum.all?(tasks, fn task -> Task.await(task, 5_000) == :ok end)

    mod = ["AI", "Tools", "MCP", Macro.camelize(server), Macro.camelize("foo")] |> Module.concat()

    assert Code.ensure_loaded?(mod)
    assert Enum.any?(MCP.Tools.module_map(), fn {_key, value} -> value == mod end)
  end
end
