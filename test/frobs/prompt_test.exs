defmodule Frobs.PromptTest do
  use Fnord.TestCase, async: true

  # A mock UI module that replays scripted responses. Tests set up a list of
  # responses in the process dictionary; each call to prompt/choose consumes
  # the next one in order.
  defmodule MockUI do
    def is_tty?(), do: true
    def quiet?(), do: false

    def puts(_msg), do: :ok

    def prompt(_text) do
      next_response()
    end

    def choose(_label, options) do
      case next_response() do
        idx when is_integer(idx) -> Enum.at(options, idx)
        val when is_binary(val) -> val
      end
    end

    defp next_response do
      case Process.get(:mock_ui_responses) do
        [resp | rest] ->
          Process.put(:mock_ui_responses, rest)
          resp

        [] ->
          raise "MockUI: no more scripted responses"
      end
    end
  end

  # A non-interactive mock UI (quiet or no TTY)
  defmodule QuietUI do
    def is_tty?(), do: false
    def quiet?(), do: true
    def puts(_msg), do: :ok
    def prompt(_text), do: nil
    def choose(_label, _options), do: nil
  end

  defp script_responses(responses) do
    Process.put(:mock_ui_responses, responses)
  end

  defp make_spec(properties, required) do
    %{
      "parameters" => %{
        "type" => "object",
        "required" => required,
        "properties" => properties
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Simple type prompting
  # ---------------------------------------------------------------------------

  describe "simple type prompting" do
    test "prompts for string" do
      spec = make_spec(%{"name" => %{"type" => "string", "description" => "Name"}}, ["name"])
      script_responses(["Alice"])

      assert {:ok, %{"name" => "Alice"}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for integer" do
      spec = make_spec(%{"count" => %{"type" => "integer", "description" => "Count"}}, ["count"])
      script_responses(["42"])

      assert {:ok, %{"count" => 42}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for boolean" do
      spec = make_spec(%{"flag" => %{"type" => "boolean", "description" => "Flag"}}, ["flag"])
      # choose returns first option index
      script_responses([0])

      assert {:ok, %{"flag" => true}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for enum" do
      spec =
        make_spec(
          %{
            "color" => %{"type" => "string", "description" => "Color", "enum" => ["red", "blue"]}
          },
          ["color"]
        )

      # choose returns second option
      script_responses([1])

      assert {:ok, %{"color" => "blue"}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for string with default, user enters blank" do
      spec =
        make_spec(
          %{"name" => %{"type" => "string", "description" => "Name", "default" => "Bob"}},
          ["name"]
        )

      script_responses([""])

      assert {:ok, %{"name" => "Bob"}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for array" do
      spec =
        make_spec(
          %{
            "items" => %{
              "type" => "array",
              "description" => "Items",
              "items" => %{"type" => "string"}
            }
          },
          ["items"]
        )

      script_responses(["a", "b", ""])

      assert {:ok, %{"items" => ["a", "b"]}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end
  end

  # ---------------------------------------------------------------------------
  # Composition prompting
  # ---------------------------------------------------------------------------

  describe "nullable anyOf prompting" do
    test "prompts for nullable string, user provides value" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "Optional name",
              "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
            }
          },
          []
        )

      script_responses(["Alice"])

      assert {:ok, %{"val" => "Alice"}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end

    test "prompts for nullable string, user skips" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "Optional name",
              "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
            }
          },
          []
        )

      script_responses([""])

      assert {:ok, %{"val" => nil}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end
  end

  describe "simple multi-type anyOf prompting" do
    test "user chooses type then provides value" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "String or integer",
              "anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]
            }
          },
          ["val"]
        )

      # First: choose type (index 0 = "integer"), then provide value
      script_responses([0, "42"])

      assert {:ok, %{"val" => 42}} = Frobs.Prompt.prompt_for_params(spec, MockUI)
    end
  end

  describe "allOf prompting" do
    test "merges schemas and prompts for merged result" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "Composed object",
              "allOf" => [
                %{
                  "type" => "object",
                  "properties" => %{"a" => %{"type" => "string", "description" => "a"}},
                  "required" => ["a"]
                },
                %{
                  "properties" => %{"b" => %{"type" => "string", "description" => "b"}}
                }
              ]
            }
          },
          ["val"]
        )

      # Prompts for "a" then "b" (alphabetical order)
      script_responses(["hello", "world"])

      assert {:ok, %{"val" => %{"a" => "hello", "b" => "world"}}} =
               Frobs.Prompt.prompt_for_params(spec, MockUI)
    end
  end

  describe "raw JSON fallback" do
    test "complex anyOf falls back to JSON input" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "Complex union",
              "anyOf" => [
                %{
                  "type" => "object",
                  "properties" => %{"a" => %{"type" => "string", "description" => "a"}}
                },
                %{
                  "type" => "array",
                  "items" => %{"type" => "integer"}
                }
              ]
            }
          },
          ["val"]
        )

      script_responses([~s|{"a": "hello"}|])

      assert {:ok, %{"val" => %{"a" => "hello"}}} =
               Frobs.Prompt.prompt_for_params(spec, MockUI)
    end
  end

  # ---------------------------------------------------------------------------
  # Non-interactive mode
  # ---------------------------------------------------------------------------

  describe "non-interactive mode" do
    test "uses defaults when available" do
      spec =
        make_spec(
          %{
            "name" => %{"type" => "string", "description" => "Name", "default" => "Bob"}
          },
          ["name"]
        )

      assert {:ok, %{"name" => "Bob"}} = Frobs.Prompt.prompt_for_params(spec, QuietUI)
    end

    test "errors on missing required without default" do
      spec =
        make_spec(
          %{"name" => %{"type" => "string", "description" => "Name"}},
          ["name"]
        )

      assert {:error, {:non_interactive_missing_required, ["name"]}} =
               Frobs.Prompt.prompt_for_params(spec, QuietUI)
    end

    test "uses defaults for composition schema properties" do
      spec =
        make_spec(
          %{
            "val" => %{
              "description" => "Optional",
              "anyOf" => [%{"type" => "string"}, %{"type" => "null"}],
              "default" => "fallback"
            }
          },
          ["val"]
        )

      assert {:ok, %{"val" => "fallback"}} = Frobs.Prompt.prompt_for_params(spec, QuietUI)
    end
  end
end
