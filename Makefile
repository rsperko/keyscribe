# KeyScribe — task front door. Run `make` (or `make help`) to list everything.
# The scripts under ./ and scripts/ stay the implementation; this just makes them
# discoverable and gives a uniform interface. Full detail: BUILD.md.
.DEFAULT_GOAL := help
.PHONY: help build run release publish ship cask test preflight setup reset-permissions verify icon clean patch minor major

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build the dev app (KeyScribeDev.app, self-signed; isolated from a prod install)
	./make-app.sh

run: build ## Build then launch the dev app
	open ./KeyScribeDev.app

# Bump can be positional (make release patch) or an explicit version (make release BUMP=vX.Y.Z).
# When positional, it shows up as a goal in MAKECMDGOALS; pluck it out and feed it to release.sh.
BUMP ?= $(filter patch minor major,$(MAKECMDGOALS))
release: ## Cut a release: make release patch | minor | major   (or BUMP=vX.Y.Z; bare = re-run current tag)
	./release.sh $(BUMP)

# No-op stubs so `make release patch` treats 'patch' as the bump arg, not an unknown target to build.
patch minor major:
	@:

publish: ## Publish the built+verified release: push tag + GitHub release (auto-notes) + cask + tap
	./scripts/publish.sh

ship: ## Build, run the release preflight (incl. human smoke), then publish: make ship patch|minor|major
	$(MAKE) release BUMP="$(BUMP)" && ./scripts/preflight.sh && $(MAKE) publish

cask: ## Refresh the Homebrew cask in ../homebrew-tap from the built DMG (then commit+push the tap)
	./scripts/update-cask.sh

test: ## Run the full test suite
	swift test

preflight: ## Release gate: automated build/packaging + functional checks, then human smoke (writes the publish stamp)
	./scripts/preflight.sh

setup: ## One-time: create the 'KeyScribe Local' signing cert (so dev TCC grants persist)
	./scripts/setup-dev-signing.sh

reset-permissions: ## Wipe + re-grant the dev app's TCC permissions (Mic/Accessibility)
	./scripts/reset-permissions.sh

verify: ## Interactive manual-verification checklist (mic, cloud rewrite, paste)
	./scripts/verify-live.sh

icon: ## Regenerate Resources/AppIcon.icns from scripts/render_app_icon.swift
	@tmp=$$(mktemp -d); set=$$tmp/AppIcon.iconset; mkdir -p $$set; \
		swift scripts/render_app_icon.swift $$tmp/icon.png; \
		for s in 16 32 128 256 512; do d=$$((s * 2)); \
			sips -z $$s $$s $$tmp/icon.png --out $$set/icon_$${s}x$${s}.png    >/dev/null; \
			sips -z $$d $$d $$tmp/icon.png --out $$set/icon_$${s}x$${s}@2x.png >/dev/null; \
		done; \
		iconutil -c icns $$set -o Resources/AppIcon.icns; \
		rm -rf $$tmp; echo "wrote Resources/AppIcon.icns"

clean: ## Remove build artifacts (.build, the .app bundles, the release DMG)
	rm -rf .build KeyScribe.app KeyScribeDev.app KeyScribe-*.dmg
