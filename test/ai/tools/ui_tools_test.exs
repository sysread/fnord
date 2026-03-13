defmodule AI.Tools.UIToolsTest do
  use Fnord.TestCase, async: false

  setup do
    set_log_level(:none)

    try do
      :meck.new(UI, [:passthrough])
    rescue
      _ -> :ok
    end

    :meck.expect(UI, :is_tty?, 0, true)
    :meck.expect(UI, :quiet?, 0, false)

    original = Services.Globals.get_env(:fnord, :ui_output)

    on_exit(fn ->
      Services.Globals.put_env(:fnord, :ui_output, original)

      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defmodule MockUIOutput do
    def prompt(_label, _opts), do: "freeform"
    def choose(_label, options), do: options |> List.first()
    def choose(_label, options, _timeout_ms, _default), do: options |> List.first()
    def confirm(_msg, default), do: default
    def newline, do: :ok
    def box(_contents, _opts), do: :ok
  end

  describe "AI.Tools.UI.Ask" do
    test "returns structured answer" do
      Services.Globals.put_env(:fnord, :ui_output, MockUIOutput)

      assert {:ok, %{answer: "freeform"}} = AI.Tools.UI.Ask.call(%{"prompt" => "what?"})
    end
  end

  describe "AI.Tools.UI.Choose" do
    test "returns structured option choice" do
      Services.Globals.put_env(:fnord, :ui_output, MockUIOutput)

      args = %{"prompt" => "pick", "options" => ["a", "b"]}

      assert {:ok, %{choice: :option, value: "a"}} = AI.Tools.UI.Choose.call(args)
    end

    test "something else triggers freeform prompt" do
      defmodule SomethingElseOutput do
        def prompt(_label, _opts), do: "custom"
        def choose(_label, _options), do: "Something else"
        def choose(_label, _options, _timeout_ms, _default), do: "Something else"
        def confirm(_msg, _default), do: true
        def newline, do: :ok
        def box(_contents, _opts), do: :ok
      end

      Services.Globals.put_env(:fnord, :ui_output, SomethingElseOutput)

      args = %{"prompt" => "pick", "options" => ["a", "b"]}

      assert {:ok, %{choice: :something_else, value: "custom"}} = AI.Tools.UI.Choose.call(args)
    end
  end

  describe "AI.Tools.UI.Confirm" do
    test "returns structured yes/no with default" do
      Services.Globals.put_env(:fnord, :ui_output, MockUIOutput)

      assert {:ok, %{choice: :no, value: false}} =
               AI.Tools.UI.Confirm.call(%{"prompt" => "ok?", "default" => false})

      assert {:ok, %{choice: :yes, value: true}} =
               AI.Tools.UI.Confirm.call(%{"prompt" => "ok?", "default" => true})
    end
  end

  describe "toolbox integration" do
    test "skill tag ui adds tools to toolbox" do
      assert {:ok, toolbox} = Skills.Runtime.toolbox_from_tags(["basic", "ui"])

      assert Map.has_key?(toolbox, "ui_ask_tool")
      assert Map.has_key?(toolbox, "ui_choose_tool")
      assert Map.has_key?(toolbox, "ui_confirm_tool")
    end
  end
end
