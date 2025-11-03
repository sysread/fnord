defmodule MCP.ToolsTest do
  @moduledoc false
  use Fnord.TestCase, async: false

  setup do
    :ok
  end

  test "register_server_tools defines dynamic modules with correct specs" do
    tool_specs = [
      %{"name" => "foo", "description" => "desc", "inputSchema" => %{"a" => "b"}}
    ]

    assert :ok == MCP.Tools.register_server_tools("srv", tool_specs)

    server = "srv"
    tool = "foo"

    mod = ["AI", "Tools", "MCP", Macro.camelize(server), Macro.camelize(tool)] |> Module.concat()

    assert Code.ensure_loaded?(mod)

    expected_spec = %{
      type: "function",
      function: %{
        name: "srv_foo",
        description:
          """
          desc

          Note: This tool is provided by the MCP server, "srv".
          """
          |> String.trim(),
        parameters: %{"a" => "b", "required" => []}
      }
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
    assert note =~ "srv_foo"
  end
end
