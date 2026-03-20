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

  describe "perform_command/4" do
    test "delegates to the module's run/3" do
      opts = %{foo: :bar}
      sub = ["sub"]
      unk = ["--weird"]
      assert Cmd.perform_command(MockCmd, opts, sub, unk) == {:ran, opts, sub, unk}
    end
  end

  describe "Fnord.spec/0 config validation integration" do
    test "includes the config validation command family in the top-level spec" do
      parser = Fnord.spec() |> Optimus.new!()

      assert {[:config, :validation, :list],
              %Optimus.ParseResult{options: %{project: nil}, unknown: []}} =
               Optimus.parse!(parser, ["config", "validation", "list"])
    end

    test "includes config validation add/remove/clear in the top-level spec" do
      parser = Fnord.spec() |> Optimus.new!()

      assert {[:config, :validation, :add],
              %Optimus.ParseResult{
                args: %{command: "mix test"},
                options: %{project: nil, path_glob: ["lib/**/*.ex"]},
                unknown: []
              }} =
               Optimus.parse!(parser, [
                 "config",
                 "validation",
                 "add",
                 "mix test",
                 "--path-glob",
                 "lib/**/*.ex"
               ])

      assert {[:config, :validation, :remove], %Optimus.ParseResult{}} =
               Optimus.parse!(parser, ["config", "validation", "remove", "1"])

      assert {[:config, :validation, :clear], %Optimus.ParseResult{}} =
               Optimus.parse!(parser, ["config", "validation", "clear"])
    end
  end
end
