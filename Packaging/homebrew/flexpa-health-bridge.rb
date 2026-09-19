cask "flexpa-health-bridge" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/flexpa/bridge/releases/download/v#{version}/FlexpaHealthBridge-#{version}.dmg",
      verified: "github.com/flexpa/bridge/"
  name "Flexpa Health Bridge"
  desc "Menu bar server that gives local AI agents read-only access to Apple Health data"
  homepage "https://github.com/flexpa/bridge"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Flexpa Health Bridge.app"

  uninstall quit:       "com.flexpa.HealthBridge",
            launchctl:  "com.flexpa.HealthBridge"

  # Pairings, settings, the audit log, and the imported Health store. Left in place on
  # uninstall so an upgrade keeps them; `brew uninstall --zap` removes them.
  #
  # Homebrew cannot delete keychain items, so a remembered iPhone backup password survives a
  # zap. Remove it first if you want it gone:
  #   security delete-generic-password -s com.flexpa.HealthBridge.backup-password
  zap trash: [
    "~/Library/Application Support/HealthBridge",
    "~/Library/Preferences/com.flexpa.HealthBridge.plist",
    "~/Library/Caches/com.flexpa.HealthBridge",
  ]

  caveats <<~EOS
    Flexpa Health Bridge runs in the menu bar and serves agents on 127.0.0.1 only.

    To read your Apple Health data it needs one of:
      • an encrypted iPhone backup on this Mac (Finder → iPhone → "Encrypt local backup"),
        which also requires granting the app Full Disk Access, or
      • a Health app export (Health → profile → Export All Health Data).

    Pair an agent from the menu bar panel, or run:
      "#{appdir}/Flexpa Health Bridge.app/Contents/MacOS/HealthBridge" --pair "Claude Code"
  EOS
end
