defmodule Cmd.PrimeTest do
  use Fnord.TestCase
  @moduletag :capture_log

  describe "run/3" do
    setup do
      mock_project("test_proj")
      :ok
    end

    test "delegates to Cmd.Ask.run/3 with rounds=3 and primer question (happy path)" do
      :meck.new(Cmd.Ask, [:no_link, :passthrough, :non_strict])
      on_exit(fn -> :meck.unload(Cmd.Ask) end)

      :meck.expect(Cmd.Ask, :run, fn opts, subcommands, unknown ->
        # Overrides
        assert Map.get(opts, :rounds) == 3
        question = Map.get(opts, :question)
        assert is_binary(question)
        assert String.starts_with?(question, "Please provide an overview of the current project.")

        # Delegates
        assert subcommands == []
        assert unknown == []

        :ok
      end)

      result = Cmd.Prime.run(%{}, [], [])
      assert result == :ok
    end

    test "overrides existing rounds and question while preserving other opts" do
      :meck.new(Cmd.Ask, [:no_link, :passthrough, :non_strict])
      on_exit(fn -> :meck.unload(Cmd.Ask) end)

      :meck.expect(Cmd.Ask, :run, fn opts, subcommands, unknown ->
        # Overridden
        assert Map.get(opts, :rounds) == 3
        q = Map.get(opts, :question)
        assert is_binary(q)
        assert String.starts_with?(q, "Please provide an overview of the current project.")

        # Preserved misc opt
        assert Map.get(opts, :edit) == true

        assert subcommands == []
        assert unknown == []
        {:ok, :delegated}
      end)

      result = Cmd.Prime.run(%{rounds: 99, question: "ignored", edit: true}, [], [])
      assert result == {:ok, :delegated}
    end

    test "propagates error from Cmd.Ask.run/3" do
      :meck.new(Cmd.Ask, [:no_link, :passthrough, :non_strict])
      on_exit(fn -> :meck.unload(Cmd.Ask) end)

      :meck.expect(Cmd.Ask, :run, fn _opts, _sub, _unk -> {:error, :boom} end)

      result = Cmd.Prime.run(%{}, [], [])
      assert result == {:error, :boom}
    end
  end
end