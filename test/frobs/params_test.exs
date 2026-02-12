defmodule Frobs.ParamsTest do
  use Fnord.TestCase, async: true

  describe "validate_and_coerce_param/2" do
    # -------------------------------------------------------------------------
    # Flat type coercion
    # -------------------------------------------------------------------------

    test "string coercion" do
      schema = %{"type" => "string"}

      assert {:ok, "hello"} = Frobs.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, "42"} = Frobs.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, nil} = Frobs.Params.validate_and_coerce_param(schema, nil)
    end

    test "integer coercion" do
      schema = %{"type" => "integer"}

      assert {:ok, 42} = Frobs.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, 42} = Frobs.Params.validate_and_coerce_param(schema, "42")
      assert {:ok, 5} = Frobs.Params.validate_and_coerce_param(schema, 5.0)
      assert {:error, :coercion_failed, _} = Frobs.Params.validate_and_coerce_param(schema, "abc")
    end

    test "number coercion" do
      schema = %{"type" => "number"}

      assert {:ok, 3.14} = Frobs.Params.validate_and_coerce_param(schema, 3.14)
      assert {:ok, 42} = Frobs.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, 3.14} = Frobs.Params.validate_and_coerce_param(schema, "3.14")
    end

    test "boolean coercion" do
      schema = %{"type" => "boolean"}

      assert {:ok, true} = Frobs.Params.validate_and_coerce_param(schema, true)
      assert {:ok, false} = Frobs.Params.validate_and_coerce_param(schema, false)
      assert {:ok, true} = Frobs.Params.validate_and_coerce_param(schema, "yes")
      assert {:ok, false} = Frobs.Params.validate_and_coerce_param(schema, "no")
      assert {:ok, true} = Frobs.Params.validate_and_coerce_param(schema, 1)
      assert {:ok, false} = Frobs.Params.validate_and_coerce_param(schema, 0)
    end

    test "null type" do
      schema = %{"type" => "null"}

      assert {:ok, nil} = Frobs.Params.validate_and_coerce_param(schema, nil)
      assert {:error, :coercion_failed, _} = Frobs.Params.validate_and_coerce_param(schema, "x")
    end

    test "enum validation" do
      schema = %{"type" => "string", "enum" => ["a", "b", "c"]}

      assert {:ok, "a"} = Frobs.Params.validate_and_coerce_param(schema, "a")
      assert {:error, :enum_mismatch, _} = Frobs.Params.validate_and_coerce_param(schema, "z")
    end

    test "array coercion with items schema" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}}

      assert {:ok, [1, 2, 3]} = Frobs.Params.validate_and_coerce_param(schema, ["1", "2", "3"])

      assert {:error, :invalid_type, _} =
               Frobs.Params.validate_and_coerce_param(schema, "not a list")
    end

    test "object coercion with properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

      assert {:ok, %{"name" => "Alice", "age" => 30}} =
               Frobs.Params.validate_and_coerce_param(schema, %{"name" => "Alice", "age" => "30"})

      assert {:error, :missing_required, _} =
               Frobs.Params.validate_and_coerce_param(schema, %{"age" => 30})
    end

    # -------------------------------------------------------------------------
    # anyOf
    # -------------------------------------------------------------------------

    test "anyOf matches first valid sub-schema" do
      # Order matters: string coercion accepts integers via to_string,
      # so integer must come first to preserve the integer type.
      schema = %{
        "anyOf" => [
          %{"type" => "integer"},
          %{"type" => "string"}
        ]
      }

      assert {:ok, "hello"} = Frobs.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, 42} = Frobs.Params.validate_and_coerce_param(schema, 42)
    end

    test "anyOf fails when no sub-schema matches" do
      schema = %{
        "anyOf" => [
          %{"type" => "integer"},
          %{"type" => "boolean"}
        ]
      }

      assert {:error, :no_matching_schema, _} =
               Frobs.Params.validate_and_coerce_param(schema, [1, 2, 3])
    end

    test "anyOf with nullable pattern" do
      schema = %{
        "anyOf" => [
          %{"type" => "string"},
          %{"type" => "null"}
        ]
      }

      assert {:ok, "hello"} = Frobs.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, nil} = Frobs.Params.validate_and_coerce_param(schema, nil)
    end

    # -------------------------------------------------------------------------
    # oneOf
    # -------------------------------------------------------------------------

    test "oneOf matches first valid sub-schema" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "string"}
        ]
      }

      assert {:ok, "hello"} = Frobs.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, 42} = Frobs.Params.validate_and_coerce_param(schema, 42)
    end

    test "oneOf fails when no sub-schema matches" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "boolean"}
        ]
      }

      assert {:error, :no_matching_schema, _} =
               Frobs.Params.validate_and_coerce_param(schema, [])
    end

    # -------------------------------------------------------------------------
    # allOf
    # -------------------------------------------------------------------------

    test "allOf merges sub-schemas and validates" do
      schema = %{
        "allOf" => [
          %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
          %{"properties" => %{"b" => %{"type" => "integer"}}, "required" => ["b"]}
        ]
      }

      assert {:ok, %{"a" => "x", "b" => 1}} =
               Frobs.Params.validate_and_coerce_param(schema, %{"a" => "x", "b" => "1"})

      assert {:error, :missing_required, _} =
               Frobs.Params.validate_and_coerce_param(schema, %{"a" => "x"})
    end

    test "allOf enum intersection" do
      schema = %{
        "allOf" => [
          %{"type" => "string", "enum" => ["a", "b", "c"]},
          %{"type" => "string", "enum" => ["b", "c", "d"]}
        ]
      }

      assert {:ok, "b"} = Frobs.Params.validate_and_coerce_param(schema, "b")
      assert {:error, :enum_mismatch, _} = Frobs.Params.validate_and_coerce_param(schema, "a")
    end

    # -------------------------------------------------------------------------
    # Unresolvable schema
    # -------------------------------------------------------------------------

    test "returns error for schema with no type or composition" do
      schema = %{"description" => "nothing useful"}

      assert {:error, :unresolvable_schema, _} =
               Frobs.Params.validate_and_coerce_param(schema, "anything")
    end
  end

  describe "normalize_schema/1" do
    test "recursively normalizes anyOf sub-schemas" do
      schema = %{
        anyOf: [
          %{type: "string"},
          %{type: "null"}
        ]
      }

      normalized = Frobs.Params.normalize_schema(schema)

      assert Map.has_key?(normalized, "anyOf")
      assert [%{"type" => "string"}, %{"type" => "null"}] = normalized["anyOf"]
    end

    test "recursively normalizes nested properties" do
      schema = %{
        type: "object",
        properties: %{
          inner: %{type: "string"}
        }
      }

      normalized = Frobs.Params.normalize_schema(schema)

      assert %{"type" => "string"} = normalized["properties"]["inner"]
    end

    test "normalizes items schema" do
      schema = %{
        type: "array",
        items: %{type: "integer"}
      }

      normalized = Frobs.Params.normalize_schema(schema)

      assert %{"type" => "integer"} = normalized["items"]
    end
  end

  describe "resolve_schema_type/1" do
    test "returns type for flat schema" do
      assert {:ok, "string"} = Frobs.Params.resolve_schema_type(%{"type" => "string"})
    end

    test "returns composition for anyOf" do
      schema = %{"anyOf" => [%{"type" => "string"}]}
      assert {:composition, "anyOf", _} = Frobs.Params.resolve_schema_type(schema)
    end

    test "returns composition for oneOf" do
      schema = %{"oneOf" => [%{"type" => "string"}]}
      assert {:composition, "oneOf", _} = Frobs.Params.resolve_schema_type(schema)
    end

    test "returns composition for allOf" do
      schema = %{"allOf" => [%{"type" => "string"}]}
      assert {:composition, "allOf", _} = Frobs.Params.resolve_schema_type(schema)
    end

    test "type takes precedence over composition" do
      schema = %{"type" => "object", "oneOf" => [%{"type" => "string"}]}
      assert {:ok, "object"} = Frobs.Params.resolve_schema_type(schema)
    end

    test "returns error for unresolvable" do
      assert {:error, :unresolvable} = Frobs.Params.resolve_schema_type(%{"description" => "x"})
    end
  end

  describe "nullable_schema?/2" do
    test "detects nullable anyOf" do
      subs = [%{"type" => "string"}, %{"type" => "null"}]
      assert {:nullable, %{"type" => "string"}} = Frobs.Params.nullable_schema?("anyOf", subs)
    end

    test "detects nullable oneOf" do
      subs = [%{"type" => "null"}, %{"type" => "integer"}]
      assert {:nullable, %{"type" => "integer"}} = Frobs.Params.nullable_schema?("oneOf", subs)
    end

    test "not nullable with more than 2 sub-schemas" do
      subs = [%{"type" => "string"}, %{"type" => "null"}, %{"type" => "integer"}]
      assert :not_nullable = Frobs.Params.nullable_schema?("anyOf", subs)
    end

    test "not nullable for allOf" do
      subs = [%{"type" => "string"}, %{"type" => "null"}]
      assert :not_nullable = Frobs.Params.nullable_schema?("allOf", subs)
    end

    test "not nullable when neither sub-schema is null" do
      subs = [%{"type" => "string"}, %{"type" => "integer"}]
      assert :not_nullable = Frobs.Params.nullable_schema?("anyOf", subs)
    end
  end

  describe "all_simple_types?/1" do
    test "true for simple types" do
      subs = [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "boolean"}]
      assert Frobs.Params.all_simple_types?(subs)
    end

    test "false when array present" do
      subs = [%{"type" => "string"}, %{"type" => "array"}]
      refute Frobs.Params.all_simple_types?(subs)
    end

    test "false when no type" do
      subs = [%{"anyOf" => [%{"type" => "string"}]}]
      refute Frobs.Params.all_simple_types?(subs)
    end
  end

  describe "merge_schemas/1" do
    test "merges type (last wins)" do
      result = Frobs.Params.merge_schemas([%{"type" => "string"}, %{"type" => "integer"}])
      assert result["type"] == "integer"
    end

    test "merges properties (union)" do
      result =
        Frobs.Params.merge_schemas([
          %{"properties" => %{"a" => %{"type" => "string"}}},
          %{"properties" => %{"b" => %{"type" => "integer"}}}
        ])

      assert Map.has_key?(result["properties"], "a")
      assert Map.has_key?(result["properties"], "b")
    end

    test "merges required (union)" do
      result =
        Frobs.Params.merge_schemas([
          %{"required" => ["a"]},
          %{"required" => ["b", "a"]}
        ])

      assert Enum.sort(result["required"]) == ["a", "b"]
    end

    test "merges enum (intersection)" do
      result =
        Frobs.Params.merge_schemas([
          %{"enum" => ["a", "b", "c"]},
          %{"enum" => ["b", "c", "d"]}
        ])

      assert Enum.sort(result["enum"]) == ["b", "c"]
    end
  end

  describe "validate_all_args/2 with composition schemas" do
    test "validates args with anyOf property" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => ["val"],
          "properties" => %{
            "val" => %{
              "description" => "string or int",
              "anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]
            }
          }
        }
      }

      assert {:ok, %{"val" => "hello"}} =
               Frobs.Params.validate_all_args(spec, %{"val" => "hello"})

      assert {:ok, %{"val" => 42}} = Frobs.Params.validate_all_args(spec, %{"val" => 42})
    end

    test "validates args with allOf property" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => ["val"],
          "properties" => %{
            "val" => %{
              "description" => "composed",
              "allOf" => [
                %{"type" => "string", "enum" => ["a", "b", "c"]},
                %{"type" => "string", "enum" => ["b", "c", "d"]}
              ]
            }
          }
        }
      }

      assert {:ok, %{"val" => "b"}} = Frobs.Params.validate_all_args(spec, %{"val" => "b"})

      assert {:error, :invalid_prefill, _} =
               Frobs.Params.validate_all_args(spec, %{"val" => "a"})
    end
  end
end
