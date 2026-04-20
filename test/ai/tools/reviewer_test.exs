defmodule AI.Tools.ReviewerTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Reviewer

  describe "mutual exclusion of target params" do
    test "passing branch and pr together returns an actionable error" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "branch" => "feature-x",
                 "pr" => 42
               })

      assert msg =~ "pass at most one"
      assert msg =~ "branch"
      assert msg =~ "pr"
    end

    test "passing branch and range together returns an actionable error" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "branch" => "feature-x",
                 "range" => "HEAD~3..HEAD"
               })

      assert msg =~ "pass at most one"
    end

    test "passing pr and range together returns an actionable error" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "pr" => 42,
                 "range" => "HEAD~3..HEAD"
               })

      assert msg =~ "pass at most one"
    end

    test "passing all three target params returns an error listing all three" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "branch" => "feature-x",
                 "pr" => 42,
                 "range" => "HEAD~3..HEAD"
               })

      assert msg =~ "branch"
      assert msg =~ "pr"
      assert msg =~ "range"
    end
  end

  describe "schema" do
    test "spec exposes the new target params" do
      props = get_in(Reviewer.spec(), [:function, :parameters, :properties])

      assert Map.has_key?(props, :scope)
      assert Map.has_key?(props, :branch)
      assert Map.has_key?(props, :pr)
      assert Map.has_key?(props, :range)
      assert Map.has_key?(props, :base)
    end

    test "scope is required; target params are optional" do
      required = get_in(Reviewer.spec(), [:function, :parameters, :required])
      assert required == ["scope"]
    end

    test "pr parameter is an integer" do
      type = get_in(Reviewer.spec(), [:function, :parameters, :properties, :pr, :type])
      assert type == "integer"
    end
  end
end
