defmodule Shell.Completion.BashTest do
  use ExUnit.Case

  describe "validate_command_spec/1" do
    test "returns :ok when spec has a :name key" do
      spec = %{name: "test"}
      assert Shell.Completion.Bash.validate_command_spec(spec) == :ok
    end

    test "returns error when spec is missing :name" do
      spec = %{foo: "bar"}

      assert Shell.Completion.Bash.validate_command_spec(spec) ==
               {:error, "Command spec must have a :name key"}
    end
  end

  describe "generate_bash_script/1" do
    test "generates a script for a minimal valid spec" do
      spec = %{name: "test"}
      script = Shell.Completion.Bash.generate_bash_script(spec)
      assert is_binary(script)
      assert script =~ "#!/usr/bin/env bash"
      assert script =~ "complete -F _test_completion test"
    end

    test "includes subcommands and options in the generated script" do
      spec = %{
        name: "scratch",
        subcommands: [
          %{
            name: "foo",
            options: [
              %{name: "--bar", from: {:choices, ["a", "b"]}},
              %{name: "--baz", takes_argument: false}
            ]
          }
        ],
        options: [
          %{name: "--global", from: :files}
        ]
      }

      script = Shell.Completion.Bash.generate_bash_script(spec)

      # Check that the top-level command registers the subcommand "foo"
      assert script =~ ~s(_sc_subcommands["scratch"]="foo")
      # Check that the global option is present
      assert script =~ ~s(_sc_options["scratch"]="--global")
      # Verify that the option "--bar" is processed with a choices source.
      assert script =~ ~s(_sc_option_args["scratch:foo:--bar"]="choices:a b")
      # "--baz" is a flag (takes_argument: false) so it should appear in the options list
      assert script =~ ~s(_sc_options["scratch:foo"]="--bar --baz")
      # But "--baz" should not be in the option_args table.
      refute script =~ ~s(scratch:foo:--baz)
    end

    test "processes positional argument completions" do
      spec = %{
        name: "cmd",
        arguments: [
          %{name: "file", from: :files}
        ]
      }

      script = Shell.Completion.Bash.generate_bash_script(spec)
      assert script =~ ~s(_sc_argument["cmd"]="files")
    end

    test "raises error for custom function completions" do
      spec = %{
        name: "fail",
        options: [
          %{name: "--custom", from: fn _ -> ["a", "b"] end}
        ]
      }

      assert_raise RuntimeError, "Custom function completions are not supported in bash", fn ->
        Shell.Completion.Bash.generate_bash_script(spec)
      end
    end
  end

  describe "nested command table generation" do
    test "builds correct tables for nested commands and options" do
      spec = %{
        name: "parent",
        subcommands: [
          %{
            name: "child",
            options: [
              %{name: "--opt", from: {:command, "echo hi"}}
            ]
          }
        ],
        options: [
          %{name: "--global", from: :directories}
        ]
      }

      script = Shell.Completion.Bash.generate_bash_script(spec)
      # Check top-level option for "parent"
      assert script =~ ~s(_sc_options["parent"]="--global")
      # Check that child subcommand is registered
      assert script =~ ~s(_sc_subcommands["parent"]="child")
      # Check that child's option is registered
      assert script =~ ~s(_sc_options["parent:child"]="--opt")
      # Check that child's option argument is converted correctly (using cmd:)
      assert script =~ ~s(_sc_option_args["parent:child:--opt"]="cmd:echo hi")
    end
  end
end
