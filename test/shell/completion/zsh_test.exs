defmodule Shell.Completion.ZshTest do
  use ExUnit.Case

  describe "generate_zsh_script/1" do
    test "generates a valid zsh script for a minimal spec" do
      spec = %{name: "test"}
      script = Shell.Completion.Zsh.generate_zsh_script(spec)

      # Check that the zsh header is present.
      assert script =~ "#compdef test"
      assert script =~ "compdef _test_completion test"
      # Verify that our typeset arrays are declared.
      assert script =~ "typeset -A _sc_subcommands"
      assert script =~ "typeset -A _sc_options"
      assert script =~ "typeset -A _sc_option_args"
      assert script =~ "typeset -A _sc_argument"
    end

    test "includes subcommands and options correctly" do
      spec = %{
        name: "test",
        options: [
          %{name: "--global"}
        ],
        subcommands: [
          %{
            name: "sub",
            options: [
              %{name: "--option", from: {:choices, ["a", "b", "c"]}}
            ]
          }
        ]
      }

      script = Shell.Completion.Zsh.generate_zsh_script(spec)

      # Check that the subcommand "sub" is registered under "test".
      assert script =~ ~s(_sc_subcommands["test"]="sub")
      # Global option should appear under "test".
      assert script =~ ~s(_sc_options["test"]="--global")
      # The option for subcommand "sub" should be registered.
      assert script =~ ~s(_sc_options["test:sub"]="--option")
      # The option argument for --option is converted to zsh's choices string.
      assert script =~ ~s(_sc_option_args["test:sub:--option"]="choices:a b c")
    end

    test "handles positional arguments correctly" do
      spec = %{
        name: "test",
        arguments: [
          %{name: "file", from: :files}
        ]
      }

      script = Shell.Completion.Zsh.generate_zsh_script(spec)
      # Check that the argument for the base command is correctly converted.
      assert script =~ ~s(_sc_argument["test"]="files")
    end
  end
end
