defmodule AI.ToolsTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)

  defmodule MockTool do
    @behaviour AI.Tools

    @impl AI.Tools
    def async?, do: true

    @impl AI.Tools
    def is_available?, do: true

    @impl AI.Tools
    def ui_note_on_request(args), do: {"Request", inspect(args)}

    @impl AI.Tools
    def ui_note_on_result(_args, result), do: {"Result", result}

    @impl AI.Tools
    def tool_call_failure_message(_args, _reason), do: :default

    @impl AI.Tools
    def read_args(%{"required_arg" => _}), do: {:ok, %{"required_arg" => "blarg"}}
    def read_args(_args), do: AI.Tools.required_arg_error("required_arg")

    @impl AI.Tools
    def call(_args), do: {:ok, "Huzzah!"}

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

  # PassthroughTool has a passthrough read_args, so validate_json_args is the
  # only validation gate. This exercises the centralized validation pipeline
  # without read_args short-circuiting on missing/invalid args.
  defmodule PassthroughTool do
    @behaviour AI.Tools

    @impl AI.Tools
    def async?, do: false

    @impl AI.Tools
    def is_available?, do: true

    @impl AI.Tools
    def ui_note_on_request(args), do: {"Passthrough", inspect(args)}

    @impl AI.Tools
    def ui_note_on_result(_args, result), do: {"Done", result}

    @impl AI.Tools
    def tool_call_failure_message(_args, _reason), do: :default

    @impl AI.Tools
    def read_args(args), do: {:ok, args}

    @impl AI.Tools
    def call(%{"count" => n, "label" => label}), do: {:ok, "#{label} x#{n}"}
    def call(_), do: {:ok, "ok"}

    @impl AI.Tools
    def spec do
      %{
        type: "function",
        function: %{
          name: "passthrough_tool",
          description: "A tool with passthrough read_args for testing centralized validation",
          parameters: %{
            type: "object",
            required: ["count", "label"],
            properties: %{
              count: %{
                type: "integer",
                description: "A count"
              },
              label: %{
                type: "string",
                description: "A label"
              }
            }
          }
        }
      }
    end
  end

  @tools %{"mock_tool" => MockTool, "passthrough_tool" => PassthroughTool}
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

  describe "tool_spec!/2" do
    test "fails when tool is not registered" do
      assert_raise ArgumentError, "Unknown tool: mock_tool", fn ->
        AI.Tools.tool_spec!("mock_tool")
      end
    end

    test "succeeds when tool is registered" do
      spec = MockTool.spec()
      assert ^spec = AI.Tools.tool_spec!("mock_tool", @tools)
    end
  end

  describe "perform_tool_call/3" do
    test "fails when tool is not registered" do
      assert {:error, :unknown_tool, "mock_tool"} =
               AI.Tools.perform_tool_call("mock_tool", @req_args)
    end

    test "fails when missing required args" do
      assert {:error, :missing_argument, "required_arg"} =
               AI.Tools.perform_tool_call("mock_tool", @empty_args, @tools)
    end

    test "succeeds when tool is registered and args are valid" do
      assert {:ok, "Huzzah!"} = AI.Tools.perform_tool_call("mock_tool", @req_args, @tools)
    end

    test "validates and coerces args via centralized schema validation" do
      # Integer coercion: string "3" should be coerced to integer 3
      args = %{"count" => "3", "label" => "widgets"}
      assert {:ok, "widgets x3"} = AI.Tools.perform_tool_call("passthrough_tool", args, @tools)
    end

    test "rejects args that fail schema validation" do
      # Missing required "label" — read_args passes through, validate_json_args catches it
      args = %{"count" => 5}

      assert {:error, :missing_argument, msg} =
               AI.Tools.perform_tool_call("passthrough_tool", args, @tools)

      assert msg =~ "label"
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

    test "returns UI note when centralized validation passes" do
      args = %{"count" => 5, "label" => "test"}
      assert {"Passthrough", _} = AI.Tools.on_tool_request("passthrough_tool", args, @tools)
    end

    test "returns nil when centralized validation fails" do
      args = %{"count" => 5}
      assert AI.Tools.on_tool_request("passthrough_tool", args, @tools) |> is_nil()
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

  describe "build_toolbox/1" do
    defmodule MockBuildTool do
      @behaviour AI.Tools

      @impl AI.Tools
      def async?, do: true

      @impl AI.Tools
      def spec, do: %{function: %{name: "mock_build_tool"}}

      @impl AI.Tools
      def is_available?, do: true

      @impl AI.Tools
      def read_args(args), do: {:ok, args}

      @impl AI.Tools
      def ui_note_on_request(_args), do: nil

      @impl AI.Tools
      def ui_note_on_result(_args, _result), do: nil
      @impl AI.Tools
      def tool_call_failure_message(_args, _reason), do: :default

      @impl AI.Tools
      def call(_args), do: {:ok, :ok}
    end

    test "returns a proper toolbox map from a list of modules" do
      assert AI.Tools.build_toolbox([MockBuildTool]) == %{"mock_build_tool" => MockBuildTool}
    end

    defmodule BadSpecTool do
      @behaviour AI.Tools

      @impl AI.Tools
      def async?, do: true

      @impl AI.Tools
      def spec, do: nil

      @impl AI.Tools
      def is_available?, do: true

      @impl AI.Tools
      def read_args(args), do: {:ok, args}

      @impl AI.Tools
      def ui_note_on_request(_args), do: nil

      @impl AI.Tools
      def ui_note_on_result(_args, _result), do: nil
      @impl AI.Tools
      def tool_call_failure_message(_args, _reason), do: :default

      @impl AI.Tools
      def call(_args), do: {:ok, :ok}
    end

    test "skips modules with malformed or missing spec/0" do
      assert AI.Tools.build_toolbox([MockBuildTool, BadSpecTool]) == %{
               "mock_build_tool" => MockBuildTool
             }
    end
  end
end
