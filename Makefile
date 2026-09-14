# Health Bridge — build, test, package.
.PHONY: build test app run release dmg notarize icon clean

build:            ## Debug build of the package
	swift build

test:             ## Run the test suite
	swift test

app:              ## Ad-hoc signed debug app at dist/Flexpa Health Bridge.app
	scripts/build-app.sh

run: app          ## Build and launch the app (state in ~/Library/Application Support/HealthBridge)
	open "dist/Flexpa Health Bridge.app"

release:          ## Universal release build. Set CODESIGN_IDENTITY and PROVISIONING_PROFILE for Developer ID.
	scripts/build-app.sh --release --universal

dmg:              ## Package dist/Flexpa Health Bridge.app into a DMG
	scripts/make-dmg.sh

notarize:         ## Notarize and staple the app (set NOTARY_PROFILE)
	scripts/notarize.sh "dist/Flexpa Health Bridge.app"

cask:             ## Publish the Homebrew cask for the current version (needs gh auth)
	@VERSION="$$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/HealthBridgeCore/MCP/MCPServer.swift); \
	 SHA="$$(shasum -a 256 dist/FlexpaHealthBridge-$$VERSION.dmg | cut -d' ' -f1)"; \
	 scripts/update-cask.sh "$$VERSION" "$$SHA"

icon:             ## Re-render Packaging/AppIcon.icns
	swift scripts/make-icon.swift Packaging/AppIcon.icns

clean:
	rm -rf .build dist Packaging/AppIcon.icns

help:
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed -E 's/^([a-z]+):.*## (.*)/  \1\t\2/'
