defmodule AI.UtilTest do
  use Fnord.TestCase, async: false

  test "cosine_similarity/2 computes correct similarity", _context do
    vec1 = [1.0, 0.0, 0.0]
    vec2 = [0.0, 1.0, 0.0]
    vec3 = [1.0, 0.0, 0.0]

    # Cosine similarity between orthogonal vectors should be 0
    assert AI.Util.cosine_similarity(vec1, vec2) == 0.0

    # Cosine similarity between identical vectors should be 1
    assert AI.Util.cosine_similarity(vec1, vec3) == 1.0

    # Cosine similarity between vector and itself
    similarity = AI.Util.cosine_similarity(vec1, vec1)
    assert similarity == 1.0

    # Cosine similarity between arbitrary vectors
    vec4 = [1.0, 2.0, 3.0]
    vec5 = [4.0, 5.0, 6.0]
    similarity = AI.Util.cosine_similarity(vec4, vec5)

    # Compute expected value
    dot_product = Enum.zip(vec4, vec5) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec4, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec5, 0.0, fn x, acc -> acc + x * x end))
    expected_similarity = dot_product / (magnitude1 * magnitude2)
    assert_in_delta similarity, expected_similarity, 1.0e-5
  end
end
