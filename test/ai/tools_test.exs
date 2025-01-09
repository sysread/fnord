defmodule AI.ToolsTest do
  use ExUnit.Case
  use TestUtil

  setup do: set_log_level(:none)

  defmodule MockTool do
    @behaviour AI.Tools

    @impl AI.Tools
    def ui_note_on_request(args), do: {"Request", inspect(args)}

    @impl AI.Tools
    def ui_note_on_result(_args, result), do: {"Result", result}

    @impl AI.Tools
    def call(_agent, _args), do: {:ok, "Huzzah!"}

    @impl AI.Tools
    def spec() do
      %{
        type: "function",
        function: %{
          name: "mock_tool",
          description: "pretends to do a thing",
          parameters: %{
            type: "object",
            required: ["required_arg"],
            properties: %{
              required_arg: %{
                type: "string",
                description: "a required arg for a mock tool"
              }
            }
          }
        }
      }
    end
  end

  @tools %{"mock_tool" => MockTool}
  @req_args %{"required_arg" => "blarg"}
  @empty_args %{}

  describe "tool_module/2" do
    test "fails when tool is not registered" do
      assert {:error, :unknown_tool, "mock_tool"} = AI.Tools.tool_module("mock_tool")
    end

    test "succeeds when tool is registered" do
      assert {:ok, MockTool} = AI.Tools.tool_module("mock_tool", @tools)
    end
  end

  describe "tool_spec/2" do
    test "fails when tool is not registered" do
      assert {:error, :unknown_tool, "mock_tool"} = AI.Tools.tool_spec("mock_tool")
    end

    test "succeeds when tool is registered" do
      spec = MockTool.spec()
      assert {:ok, ^spec} = AI.Tools.tool_spec("mock_tool", @tools)
    end
  end

  describe "perform_tool_call/4" do
    test "fails when tool is not registered" do
      assert {:error, :unknown_tool, "mock_tool"} =
               AI.Tools.perform_tool_call(nil, "mock_tool", @req_args)
    end

    test "fails when missing required args" do
      assert {:error, :missing_argument, "required_arg"} =
               AI.Tools.perform_tool_call(nil, "mock_tool", @empty_args, @tools)
    end

    test "succeeds when tool is registered and args are valid" do
      assert {:ok, "Huzzah!"} = AI.Tools.perform_tool_call(nil, "mock_tool", @req_args, @tools)
    end
  end

  describe "on_tool_request/3" do
    test "fails when tool is not registered" do
      assert AI.Tools.on_tool_request("mock_tool", @req_args) |> is_nil
    end

    test "fails when missing required args" do
      assert AI.Tools.on_tool_request("mock_tool", @empty_args, @tools) |> is_nil
    end

    test "successfully logs tool request" do
      value = inspect(@req_args)

      assert {"Request", ^value} =
               AI.Tools.on_tool_request("mock_tool", @req_args, @tools)
    end
  end

  describe "on_tool_result/3" do
    test "fails when tool is not registered" do
      assert {:error, :unknown_tool, "mock_tool"} =
               AI.Tools.on_tool_result("mock_tool", @req_args, "some value")
    end

    test "successfully logs tool request" do
      assert {"Result", "some value"} =
               AI.Tools.on_tool_result("mock_tool", @req_args, "some value", @tools)
    end
  end
end
