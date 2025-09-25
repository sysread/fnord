defmodule CmdTest do
  use Fnord.TestCase, async: false

  defmodule MockCmd do
    @behaviour Cmd

    @impl true
    def spec, do: []

    @impl true
    def requires_project?, do: false

    @impl true
    def run(opts, subcommands, unknown) do
      {:ran, opts, subcommands, unknown}
    end
  end

  describe "default_workers/0" do
    test "returns default concurrency" do
      assert Cmd.default_workers() == 12
    end
  end

  describe "project_arg/0" do
    test "returns the expected option schema" do
      opt = Cmd.project_arg()
      assert Keyword.get(opt, :value_name) == "PROJECT"
      assert Keyword.get(opt, :long) == "--project"
      assert Keyword.get(opt, :short) == "-p"
      assert is_binary(Keyword.get(opt, :help))
      assert Keyword.get(opt, :required) == false
    end
  end

  describe "workers_arg/0" do
    test "returns the expected option schema" do
      opt = Cmd.workers_arg()
      assert Keyword.get(opt, :value_name) == "WORKERS"
      assert Keyword.get(opt, :long) == "--workers"
      assert Keyword.get(opt, :short) == "-w"
      assert is_binary(Keyword.get(opt, :help))
      assert Keyword.get(opt, :parser) == :integer
      assert Keyword.get(opt, :default) == Cmd.default_workers()
    end
  end

  describe "perform_command/4" do
    test "delegates to the module's run/3" do
      opts = %{foo: :bar}
      sub = ["sub"]
      unk = ["--weird"]
      assert Cmd.perform_command(MockCmd, opts, sub, unk) == {:ran, opts, sub, unk}
    end
  end
end
