.DEFAULT_GOAL := help
.PHONY: help
help: ## Display this help message
	@echo "Usage: make [target]"
	@echo
	@echo "Targets:"
	@awk '/^[a-zA-Z0-9_-]+:.*## / {printf "%s : %s\n", $$1, substr($$0, index($$0, "##") + 3)}' $(MAKEFILE_LIST) | sort | column -t -s ':'
	@echo

.PHONY: compile
compile: ## Compile the project
	mix compile --all-warnings --warnings-as-errors

.PHONY: test
test: ## Run tests
	mix test

.PHONY: dialyzer
dialyzer: ## Run Dialyzer
	MIX_ENV=dev mix dialyzer

.PHONY: check
check: compile test dialyzer ## Run all checks
	@echo "All checks passed"

.PHONY: release
release: publish ## Alias for publish because apparently this is what my fingers' muscle memory prefers

.PHONY: publish
publish: check ## Publish the package
	mix hex.publish

.PHONY: republish
republish: check ## Republish the package (within like 20m of publishing the last version)
	mix hex.publish --force
