defmodule AI.Tools.ReviewerTest do
  use Fnord.TestCase, async: true

  alias AI.Tools.Reviewer

  describe "mutual exclusion of target params" do
    test "passing branch and pr together returns an actionable error" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "branch" => "feature-x",
                 "pr" => 42
               })

      assert msg =~ "only one of branch, pr, range"
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

      assert msg =~ "only one of branch, pr, range"
    end

    test "passing pr and range together returns an actionable error" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "pr" => 42,
                 "range" => "HEAD~3..HEAD"
               })

      assert msg =~ "only one of branch, pr, range"
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

    test "error message shows actual values so the retry loop can correct" do
      assert {:error, msg} =
               Reviewer.call(%{
                 "scope" => "design context",
                 "branch" => "feature-x",
                 "pr" => 42,
                 "range" => "HEAD~3..HEAD"
               })

      assert msg =~ "feature-x"
      assert msg =~ "42"
      assert msg =~ "HEAD~3..HEAD"
    end
  end

  # The trigger for this bug: LLM tool-call generators frequently emit type-
  # default placeholders for optional params (`""` for strings, `0` for
  # integers) instead of omitting them. The OLD filter treated those as
  # "provided," which caused an infinite retry loop where every call shape
  # tripped the mutex and the model couldn't see why.
  describe "tolerance for LLM-style type-default placeholders" do
    test "empty-string range alongside a real branch is treated as absent" do
      # We can't easily run the full call without a git repo, so we go through
      # normalize_target_args via the public mutex path: if normalization
      # treats range="" as absent, this call will NOT hit the mutex error.
      result =
        Reviewer.call(%{
          "scope" => "design context",
          "branch" => "feature-x",
          "range" => ""
        })

      # Whatever the downstream resolve returns, it must NOT be the mutex error.
      case result do
        {:error, msg} -> refute msg =~ "only one of branch, pr, range"
        _ -> :ok
      end
    end

    test "zero pr alongside a real branch is treated as absent" do
      result =
        Reviewer.call(%{
          "scope" => "design context",
          "branch" => "feature-x",
          "pr" => 0
        })

      case result do
        {:error, msg} -> refute msg =~ "only one of branch, pr, range"
        _ -> :ok
      end
    end

    test "branch + pr=0 + range='' (the captured failure shape) is treated as branch-only" do
      result =
        Reviewer.call(%{
          "scope" => "design context",
          "branch" => "responses",
          "pr" => 0,
          "range" => "",
          "base" => "origin/main"
        })

      case result do
        {:error, msg} -> refute msg =~ "only one of branch, pr, range"
        _ -> :ok
      end
    end

    test "empty-string base is treated as absent (does not affect mutex)" do
      result =
        Reviewer.call(%{
          "scope" => "design context",
          "branch" => "feature-x",
          "base" => ""
        })

      case result do
        {:error, msg} -> refute msg =~ "only one of branch, pr, range"
        _ -> :ok
      end
    end
  end

  describe "schema" do
    test "spec exposes the new target params" do
      props = get_in(Reviewer.spec(), [:parameters, :properties])

      assert Map.has_key?(props, :scope)
      assert Map.has_key?(props, :branch)
      assert Map.has_key?(props, :pr)
      assert Map.has_key?(props, :range)
      assert Map.has_key?(props, :base)
    end

    test "scope is required; target params are optional" do
      required = get_in(Reviewer.spec(), [:parameters, :required])
      assert required == ["scope"]
    end

    test "pr parameter is an integer" do
      type = get_in(Reviewer.spec(), [:parameters, :properties, :pr, :type])
      assert type == "integer"
    end
  end
end
