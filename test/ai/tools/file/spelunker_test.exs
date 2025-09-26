defmodule AI.Tools.File.SpelunkerTest do
  use Fnord.TestCase, async: false
  @moduletag capture_log: true

  describe "read_args/1" do
    setup do
      base = %{"symbol" => "S", "goal" => "G"}
      {:ok, base: base}
    end

    test "accepts all start_file variants", %{base: base} do
      for alias_key <- ["start_file", "start_file_path", "file_path", "file"] do
        args = Map.put(base, alias_key, "path/to.ex")

        assert {:ok, %{"symbol" => "S", "start_file" => "path/to.ex", "goal" => "G"}} =
                 AI.Tools.File.Spelunker.read_args(args)
      end
    end

    test "error when symbol missing", %{base: base} do
      args = Map.delete(base, "symbol") |> Map.put("start_file", "f.ex")
      assert {:error, :missing_argument, "symbol"} = AI.Tools.File.Spelunker.read_args(args)
    end

    test "error when start_file missing", %{base: base} do
      args = base
      assert {:error, :missing_argument, "start_file"} = AI.Tools.File.Spelunker.read_args(args)
    end

    test "error when goal missing", %{base: base} do
      args = Map.delete(base, "goal") |> Map.put("start_file", "f.ex")
      assert {:error, :missing_argument, "goal"} = AI.Tools.File.Spelunker.read_args(args)
    end
  end

  describe "spec/0" do
    test "function name and required keys" do
      spec = AI.Tools.File.Spelunker.spec()
      # spec/0 returns a plain map; use pattern matching to extract nested values
      assert %{
               function: %{
                 name: name,
                 parameters: %{
                   required: required
                 }
               }
             } = spec

      assert name == "file_spelunker_tool"
      assert required == ["symbol", "start_file", "goal"]
    end
  end

  describe "ui_note_on_request/1 and ui_note_on_result/2" do
    setup do
      args = %{"symbol" => "foo", "start_file" => "lib/a.ex", "goal" => "trace"}
      {:ok, args: args}
    end

    test "ui_note_on_request shows symbol, file, goal", %{args: args} do
      {title, body} = AI.Tools.File.Spelunker.ui_note_on_request(args)
      assert title == "Spelunking the code"
      assert body =~ "Start file: lib/a.ex"
      assert body =~ "Symbol: foo"
      assert body =~ "Goal: trace"
    end

    test "ui_note_on_result shows fields and result", %{args: args} do
      {title, body} = AI.Tools.File.Spelunker.ui_note_on_result(args, "RESULT123")
      assert title == "Finished spelunking"
      assert body =~ "Start file: lib/a.ex"
      assert body =~ "Symbol: foo"
      assert body =~ "Goal: trace"
      assert body =~ "-----"
      assert body =~ "RESULT123"
    end
  end

  describe "call/1" do
    test "returns :error when missing goal" do
      assert :error = AI.Tools.File.Spelunker.call(%{"symbol" => "S", "start_file" => "F"})
    end

    test "returns :error when missing symbol" do
      assert :error = AI.Tools.File.Spelunker.call(%{"start_file" => "F", "goal" => "G"})
    end

    test "returns :error when missing start_file" do
      assert :error = AI.Tools.File.Spelunker.call(%{"symbol" => "S", "goal" => "G"})
    end

  end

  describe "AI.Tools.perform_tool_call/3 integration" do
    test "missing goal returns argument error" do
      result =
        AI.Tools.perform_tool_call(
          "file_spelunker_tool",
          %{"symbol" => "s", "start_file" => "f"},
          %{"file_spelunker_tool" => AI.Tools.File.Spelunker}
        )

      assert result == {:error, :missing_argument, "goal"}
    end

  end


end
