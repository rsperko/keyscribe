# KeyScribe — task front door. Run `make` (or `make help`) to list everything.
# The scripts under ./ and scripts/ stay the implementation; this just makes them
# discoverable and gives a uniform interface. Full detail: BUILD.md.
.DEFAULT_GOAL := help
.PHONY: help build run release test setup reset-permissions verify icon clean

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build the dev app (KeyScribeDev.app, self-signed; isolated from a prod install)
	./make-app.sh

run: build ## Build then launch the dev app
	open ./KeyScribeDev.app

release: ## Notarized release build + DMG. Pass a bump: make release BUMP=patch|minor|major|vX.Y.Z
	./release.sh $(BUMP)

test: ## Run the full test suite
	swift test

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
