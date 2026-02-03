# Development Verification Checklist

This project treats warnings as errors in spirit and strives to keep a clean bill of health during development and CI.

## Verify before you push

1. Format code: `mix format`
2. Static analysis (type checking): `mix dialyzer`
3. Run the test suite: `mix test`

...or just run `make check`, which does all of the above and more.

Notes:
- The codebase aims to run with warnings treated as errors; please ensure compiler warnings are addressed, not ignored.
- Dialyzer should pass clean; fix or suppress only with clear justification.
- Prefer small, minimal diffs to reduce review friction and merge conflicts.
