defmodule AI.Tools.ParamsTest do
  use Fnord.TestCase, async: true

  describe "validate_and_coerce_param/2" do
    # -------------------------------------------------------------------------
    # Flat type coercion
    # -------------------------------------------------------------------------

    test "string coercion" do
      schema = %{"type" => "string"}

      assert {:ok, "hello"} = AI.Tools.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, "42"} = AI.Tools.Params.validate_and_coerce_param(schema, 42)

      assert {:error, :coercion_failed, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, nil)
    end

    test "string rejects nil even in anyOf nullable pattern" do
      schema = %{
        "anyOf" => [
          %{"type" => "string"},
          %{"type" => "null"}
        ]
      }

      assert {:ok, "hello"} = AI.Tools.Params.validate_and_coerce_param(schema, "hello")
      # nil matches only the null sub-schema, not string
      assert {:ok, nil} = AI.Tools.Params.validate_and_coerce_param(schema, nil)
    end

    test "integer coercion" do
      schema = %{"type" => "integer"}

      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, "42")
      assert {:ok, 5} = AI.Tools.Params.validate_and_coerce_param(schema, 5.0)

      assert {:error, :coercion_failed, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "abc")
    end

    test "number coercion" do
      schema = %{"type" => "number"}

      assert {:ok, 3.14} = AI.Tools.Params.validate_and_coerce_param(schema, 3.14)
      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, 3.14} = AI.Tools.Params.validate_and_coerce_param(schema, "3.14")
    end

    test "boolean coercion" do
      schema = %{"type" => "boolean"}

      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, true)
      assert {:ok, false} = AI.Tools.Params.validate_and_coerce_param(schema, false)
      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, "yes")
      assert {:ok, false} = AI.Tools.Params.validate_and_coerce_param(schema, "no")
      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, 1)
      assert {:ok, false} = AI.Tools.Params.validate_and_coerce_param(schema, 0)
    end

    test "null type" do
      schema = %{"type" => "null"}

      assert {:ok, nil} = AI.Tools.Params.validate_and_coerce_param(schema, nil)

      assert {:error, :coercion_failed, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "x")
    end

    test "enum validation" do
      schema = %{"type" => "string", "enum" => ["a", "b", "c"]}

      assert {:ok, "a"} = AI.Tools.Params.validate_and_coerce_param(schema, "a")
      assert {:error, :enum_mismatch, _} = AI.Tools.Params.validate_and_coerce_param(schema, "z")
    end

    test "array coercion with items schema" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}}

      assert {:ok, [1, 2, 3]} = AI.Tools.Params.validate_and_coerce_param(schema, ["1", "2", "3"])

      assert {:error, :invalid_type, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "not a list")
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
               AI.Tools.Params.validate_and_coerce_param(schema, %{
                 "name" => "Alice",
                 "age" => "30"
               })

      assert {:error, :missing_required, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, %{"age" => 30})
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

      assert {:ok, "hello"} = AI.Tools.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, 42)
    end

    test "anyOf fails when no sub-schema matches" do
      schema = %{
        "anyOf" => [
          %{"type" => "integer"},
          %{"type" => "boolean"}
        ]
      }

      assert {:error, :no_matching_schema, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, [1, 2, 3])
    end

    test "anyOf with nullable pattern" do
      schema = %{
        "anyOf" => [
          %{"type" => "string"},
          %{"type" => "null"}
        ]
      }

      assert {:ok, "hello"} = AI.Tools.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, nil} = AI.Tools.Params.validate_and_coerce_param(schema, nil)
    end

    # -------------------------------------------------------------------------
    # oneOf
    # -------------------------------------------------------------------------

    test "oneOf succeeds when exactly one sub-schema matches" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "boolean"}
        ]
      }

      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, true)
    end

    test "oneOf fails when no sub-schema matches" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "boolean"}
        ]
      }

      assert {:error, :no_matching_schema, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, [])
    end

    test "oneOf fails when multiple sub-schemas match" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "number"}
        ]
      }

      # 42 is both a valid integer and a valid number
      assert {:error, :multiple_schemas_matched, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, 42)
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
               AI.Tools.Params.validate_and_coerce_param(schema, %{"a" => "x", "b" => "1"})

      assert {:error, :missing_required, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, %{"a" => "x"})
    end

    test "allOf enum intersection" do
      schema = %{
        "allOf" => [
          %{"type" => "string", "enum" => ["a", "b", "c"]},
          %{"type" => "string", "enum" => ["b", "c", "d"]}
        ]
      }

      assert {:ok, "b"} = AI.Tools.Params.validate_and_coerce_param(schema, "b")
      assert {:error, :enum_mismatch, _} = AI.Tools.Params.validate_and_coerce_param(schema, "a")
    end

    # -------------------------------------------------------------------------
    # Unresolvable schema
    # -------------------------------------------------------------------------

    test "returns error for schema with no type or composition" do
      schema = %{"description" => "nothing useful"}

      assert {:error, :unresolvable_schema, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "anything")
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

      normalized = AI.Tools.Params.normalize_schema(schema)

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

      normalized = AI.Tools.Params.normalize_schema(schema)

      assert %{"type" => "string"} = normalized["properties"]["inner"]
    end

    test "normalizes items schema" do
      schema = %{
        type: "array",
        items: %{type: "integer"}
      }

      normalized = AI.Tools.Params.normalize_schema(schema)

      assert %{"type" => "integer"} = normalized["items"]
    end
  end

  describe "resolve_schema_type/1" do
    test "returns type for flat schema" do
      assert {:ok, "string"} = AI.Tools.Params.resolve_schema_type(%{"type" => "string"})
    end

    test "returns composition for anyOf" do
      schema = %{"anyOf" => [%{"type" => "string"}]}
      assert {:composition, "anyOf", _} = AI.Tools.Params.resolve_schema_type(schema)
    end

    test "returns composition for oneOf" do
      schema = %{"oneOf" => [%{"type" => "string"}]}
      assert {:composition, "oneOf", _} = AI.Tools.Params.resolve_schema_type(schema)
    end

    test "returns composition for allOf" do
      schema = %{"allOf" => [%{"type" => "string"}]}
      assert {:composition, "allOf", _} = AI.Tools.Params.resolve_schema_type(schema)
    end

    test "type takes precedence over composition" do
      schema = %{"type" => "object", "oneOf" => [%{"type" => "string"}]}
      assert {:ok, "object"} = AI.Tools.Params.resolve_schema_type(schema)
    end

    test "returns error for unresolvable" do
      assert {:error, :unresolvable} =
               AI.Tools.Params.resolve_schema_type(%{"description" => "x"})
    end
  end

  describe "nullable_schema?/2" do
    test "detects nullable anyOf" do
      subs = [%{"type" => "string"}, %{"type" => "null"}]
      assert {:nullable, %{"type" => "string"}} = AI.Tools.Params.nullable_schema?("anyOf", subs)
    end

    test "detects nullable oneOf" do
      subs = [%{"type" => "null"}, %{"type" => "integer"}]
      assert {:nullable, %{"type" => "integer"}} = AI.Tools.Params.nullable_schema?("oneOf", subs)
    end

    test "not nullable with more than 2 sub-schemas" do
      subs = [%{"type" => "string"}, %{"type" => "null"}, %{"type" => "integer"}]
      assert :not_nullable = AI.Tools.Params.nullable_schema?("anyOf", subs)
    end

    test "not nullable for allOf" do
      subs = [%{"type" => "string"}, %{"type" => "null"}]
      assert :not_nullable = AI.Tools.Params.nullable_schema?("allOf", subs)
    end

    test "not nullable when neither sub-schema is null" do
      subs = [%{"type" => "string"}, %{"type" => "integer"}]
      assert :not_nullable = AI.Tools.Params.nullable_schema?("anyOf", subs)
    end
  end

  describe "all_simple_types?/1" do
    test "true for simple types" do
      subs = [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "boolean"}]
      assert AI.Tools.Params.all_simple_types?(subs)
    end

    test "false when array present" do
      subs = [%{"type" => "string"}, %{"type" => "array"}]
      refute AI.Tools.Params.all_simple_types?(subs)
    end

    test "false when no type" do
      subs = [%{"anyOf" => [%{"type" => "string"}]}]
      refute AI.Tools.Params.all_simple_types?(subs)
    end
  end

  describe "merge_schemas/1" do
    test "merges type (last wins)" do
      result = AI.Tools.Params.merge_schemas([%{"type" => "string"}, %{"type" => "integer"}])
      assert result["type"] == "integer"
    end

    test "merges properties (union)" do
      result =
        AI.Tools.Params.merge_schemas([
          %{"properties" => %{"a" => %{"type" => "string"}}},
          %{"properties" => %{"b" => %{"type" => "integer"}}}
        ])

      assert Map.has_key?(result["properties"], "a")
      assert Map.has_key?(result["properties"], "b")
    end

    test "merges required (union)" do
      result =
        AI.Tools.Params.merge_schemas([
          %{"required" => ["a"]},
          %{"required" => ["b", "a"]}
        ])

      assert Enum.sort(result["required"]) == ["a", "b"]
    end

    test "merges enum (intersection)" do
      result =
        AI.Tools.Params.merge_schemas([
          %{"enum" => ["a", "b", "c"]},
          %{"enum" => ["b", "c", "d"]}
        ])

      assert Enum.sort(result["enum"]) == ["b", "c"]
    end
  end

  describe "normalize_spec/1" do
    test "normalizes atom-keyed spec to string keys" do
      spec = %{
        parameters: %{
          type: "object",
          required: [:name],
          properties: %{
            name: %{type: "string", description: "Name"}
          }
        }
      }

      assert {:ok, %{properties: props, required: ["name"]}} =
               AI.Tools.Params.normalize_spec(spec)

      assert Map.has_key?(props, "name")
      assert props["name"]["type"] == "string"
    end

    test "defaults required to empty list when missing" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "val" => %{"type" => "string"}
          }
        }
      }

      assert {:ok, %{required: []}} = AI.Tools.Params.normalize_spec(spec)
    end

    test "defaults required to empty list when not a list" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => "not_a_list",
          "properties" => %{"val" => %{"type" => "string"}}
        }
      }

      assert {:ok, %{required: []}} = AI.Tools.Params.normalize_spec(spec)
    end

    test "returns error when parameters is not a map" do
      spec = %{"parameters" => "bad"}

      assert {:error, :invalid_parameters, _} = AI.Tools.Params.normalize_spec(spec)
    end

    test "returns error when parameters is missing" do
      assert {:error, :invalid_parameters, _} = AI.Tools.Params.normalize_spec(%{})
    end

    test "returns error when properties is not a map" do
      spec = %{"parameters" => %{"type" => "object", "properties" => "bad"}}

      assert {:error, :invalid_properties, _} = AI.Tools.Params.normalize_spec(spec)
    end

    test "normalizes composition keywords in properties" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => [],
          "properties" => %{
            "val" => %{
              "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
            }
          }
        }
      }

      assert {:ok, %{properties: %{"val" => val_schema}}} = AI.Tools.Params.normalize_spec(spec)
      assert is_list(val_schema["anyOf"])
    end
  end

  describe "param_list/1" do
    test "returns sorted parameter list from normalized spec" do
      normalized = %{
        properties: %{
          "zebra" => %{"type" => "string"},
          "alpha" => %{"type" => "integer"}
        },
        required: ["alpha"]
      }

      assert {:ok, [{"alpha", _, true}, {"zebra", _, false}]} =
               AI.Tools.Params.param_list(normalized)
    end

    test "accepts raw spec and normalizes" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => ["a"],
          "properties" => %{"a" => %{"type" => "string"}}
        }
      }

      assert {:ok, [{"a", _, true}]} = AI.Tools.Params.param_list(spec)
    end

    test "propagates normalize error" do
      assert {:error, :invalid_parameters, _} = AI.Tools.Params.param_list(%{})
    end
  end

  describe "validate_and_coerce_param/2 — additional coverage" do
    test "integer coercion rejects non-integer float" do
      schema = %{"type" => "integer"}

      assert {:error, :coercion_failed, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, 5.5)
    end

    test "integer coercion rejects list" do
      schema = %{"type" => "integer"}
      assert {:error, :coercion_failed, _} = AI.Tools.Params.validate_and_coerce_param(schema, [])
    end

    test "number coercion rejects list" do
      schema = %{"type" => "number"}
      assert {:error, :coercion_failed, _} = AI.Tools.Params.validate_and_coerce_param(schema, [])
    end

    test "number coercion from string integer" do
      schema = %{"type" => "number"}
      assert {:ok, 42.0} = AI.Tools.Params.validate_and_coerce_param(schema, "42")
    end

    test "boolean coercion rejects non-boolean" do
      schema = %{"type" => "boolean"}
      assert {:error, :coercion_failed, _} = AI.Tools.Params.validate_and_coerce_param(schema, [])
    end

    test "boolean coercion from string variants" do
      schema = %{"type" => "boolean"}
      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, "true")
      assert {:ok, false} = AI.Tools.Params.validate_and_coerce_param(schema, "false")
      assert {:ok, true} = AI.Tools.Params.validate_and_coerce_param(schema, "1")
      assert {:ok, false} = AI.Tools.Params.validate_and_coerce_param(schema, "0")
    end

    test "boolean coercion rejects invalid string" do
      schema = %{"type" => "boolean"}

      assert {:error, :coercion_failed, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "maybe")
    end

    test "unsupported type returns error" do
      schema = %{"type" => "foobar"}
      assert {:error, :invalid_type, _} = AI.Tools.Params.validate_and_coerce_param(schema, "x")
    end

    test "array without items schema passes through" do
      schema = %{"type" => "array"}

      assert {:ok, [1, "two", true]} =
               AI.Tools.Params.validate_and_coerce_param(schema, [1, "two", true])
    end

    test "array with invalid item returns error with index" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}}

      assert {:error, :invalid_param, msg} =
               AI.Tools.Params.validate_and_coerce_param(schema, [1, "not_int", 3])

      assert msg =~ "index 1"
    end

    test "object passes through unknown keys" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}}
      }

      assert {:ok, %{"a" => "x", "extra" => 42}} =
               AI.Tools.Params.validate_and_coerce_param(schema, %{"a" => "x", "extra" => 42})
    end

    test "object with invalid property value" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "integer"}}
      }

      assert {:error, _, msg} =
               AI.Tools.Params.validate_and_coerce_param(schema, %{"a" => "not_int"})

      assert msg =~ "object.a"
    end

    test "object rejects non-map value" do
      schema = %{"type" => "object"}

      assert {:error, :invalid_type, _} =
               AI.Tools.Params.validate_and_coerce_param(schema, "not_a_map")
    end

    test "integer enum validation" do
      schema = %{"type" => "integer", "enum" => [1, 2, 3]}

      assert {:ok, 2} = AI.Tools.Params.validate_and_coerce_param(schema, 2)
      assert {:error, :enum_mismatch, _} = AI.Tools.Params.validate_and_coerce_param(schema, 5)
    end

    test "oneOf with nullable string pattern" do
      schema = %{
        "oneOf" => [
          %{"type" => "string"},
          %{"type" => "null"}
        ]
      }

      assert {:ok, "hello"} = AI.Tools.Params.validate_and_coerce_param(schema, "hello")
      assert {:ok, nil} = AI.Tools.Params.validate_and_coerce_param(schema, nil)
    end

    test "oneOf with integer and null works correctly" do
      # integer + null is a clean nullable since nil doesn't coerce to integer
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "null"}
        ]
      }

      assert {:ok, 42} = AI.Tools.Params.validate_and_coerce_param(schema, 42)
      assert {:ok, nil} = AI.Tools.Params.validate_and_coerce_param(schema, nil)
    end
  end

  describe "merge_schemas/1 — deep merge" do
    test "deep-merges conflicting property schemas" do
      result =
        AI.Tools.Params.merge_schemas([
          %{
            "properties" => %{
              "item" => %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
            }
          },
          %{
            "properties" => %{
              "item" => %{"properties" => %{"b" => %{"type" => "integer"}}}
            }
          }
        ])

      item_props = result["properties"]["item"]["properties"]
      assert Map.has_key?(item_props, "a")
      assert Map.has_key?(item_props, "b")
    end

    test "merges remaining keys with last-wins" do
      result =
        AI.Tools.Params.merge_schemas([
          %{"description" => "first", "minLength" => 1},
          %{"description" => "second"}
        ])

      assert result["description"] == "second"
      assert result["minLength"] == 1
    end
  end

  describe "resolve_schema_type/1 — atom type keys" do
    test "converts atom type to string" do
      assert {:ok, "string"} = AI.Tools.Params.resolve_schema_type(%{"type" => :string})
    end
  end

  describe "validate_prefilled_args/2" do
    test "rejects unknown keys" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => [],
          "properties" => %{"a" => %{"type" => "string"}}
        }
      }

      assert {:error, :unknown_prefill_keys, _} =
               AI.Tools.Params.validate_prefilled_args(spec, %{"a" => "x", "unknown" => "y"})
    end

    test "coerces known keys" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => [],
          "properties" => %{"count" => %{"type" => "integer"}}
        }
      }

      assert {:ok, %{"count" => 42}} =
               AI.Tools.Params.validate_prefilled_args(spec, %{"count" => "42"})
    end

    test "returns coercion error for invalid value" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => [],
          "properties" => %{"count" => %{"type" => "integer"}}
        }
      }

      assert {:error, :invalid_prefill, _} =
               AI.Tools.Params.validate_prefilled_args(spec, %{"count" => "abc"})
    end

    test "accepts pre-normalized spec" do
      normalized = %{
        properties: %{"a" => %{"type" => "string"}},
        required: []
      }

      assert {:ok, %{"a" => "x"}} =
               AI.Tools.Params.validate_prefilled_args(normalized, %{"a" => "x"})
    end
  end

  describe "validate_all_args/2" do
    test "returns error for missing required keys" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => ["name", "age"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "age" => %{"type" => "integer"}
          }
        }
      }

      assert {:error, {:missing_required, missing}} =
               AI.Tools.Params.validate_all_args(spec, %{"name" => "Alice"})

      assert "age" in missing
    end

    test "passes when all required present" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{"name" => %{"type" => "string"}}
        }
      }

      assert {:ok, %{"name" => "Alice"}} =
               AI.Tools.Params.validate_all_args(spec, %{"name" => "Alice"})
    end

    test "accepts spec without required field" do
      spec = %{
        "parameters" => %{
          "type" => "object",
          "properties" => %{"val" => %{"type" => "string"}}
        }
      }

      assert {:ok, %{"val" => "x"}} = AI.Tools.Params.validate_all_args(spec, %{"val" => "x"})
    end

    test "propagates normalize error" do
      assert {:error, :invalid_parameters, _} = AI.Tools.Params.validate_all_args(%{}, %{})
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
               AI.Tools.Params.validate_all_args(spec, %{"val" => "hello"})

      assert {:ok, %{"val" => 42}} = AI.Tools.Params.validate_all_args(spec, %{"val" => 42})
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

      assert {:ok, %{"val" => "b"}} = AI.Tools.Params.validate_all_args(spec, %{"val" => "b"})

      assert {:error, :invalid_prefill, _} =
               AI.Tools.Params.validate_all_args(spec, %{"val" => "a"})
    end
  end
end
