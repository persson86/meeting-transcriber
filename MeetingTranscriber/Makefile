APP      = MeetingTranscriber
BUNDLE   = $(APP).app
BIN_DIR  = .build/release
CONTENTS = $(BUNDLE)/Contents
# Use named cert (stable identity → TCC remembers permissions between builds)
# Run 'make setup-cert' once if not created yet
SIGN_ID  = MeetingTranscriber Dev Signing
OPEN_APP ?= 1

.PHONY: build install run clean setup-cert

build:
	swift build -c release 2>&1
	@echo "→ Assembling $(BUNDLE)..."
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/
	@cp Resources/Info.plist $(CONTENTS)/
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/
	@# Try named cert (stable); fall back to ad-hoc if not found
	@if security find-identity -v -p codesigning | grep -q "$(SIGN_ID)"; then \
		codesign --force --deep \
			--sign "$(SIGN_ID)" \
			--entitlements Resources/$(APP).entitlements \
			$(BUNDLE) && echo "✓ Signed with '$(SIGN_ID)'"; \
	else \
		codesign --force --deep --sign - \
			--entitlements Resources/$(APP).entitlements \
			$(BUNDLE) && echo "⚠️  Ad-hoc signed (run 'make setup-cert' to fix permissions)"; \
	fi
	@echo "✓ $(BUNDLE) ready"

install: build
	@pkill -x $(APP) 2>/dev/null || true
	@mkdir -p ~/Applications
	@cp -r $(BUNDLE) ~/Applications/
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f ~/Applications/$(BUNDLE) 2>/dev/null || true
	@sleep 0.5
	@if [ "$(OPEN_APP)" = "1" ]; then open ~/Applications/$(BUNDLE); fi
	@echo "✓ Installed to ~/Applications/$(BUNDLE)"

run: build
	@pkill -x $(APP) 2>/dev/null || true
	@sleep 0.5
	@open $(BUNDLE)

setup-cert:
	@echo "Abra o Keychain Access e crie um certificado:"
	@echo "  Keychain Access → Certificate Assistant → Create a Certificate"
	@echo "  Name: $(SIGN_ID)"
	@echo "  Identity Type: Self Signed Root"
	@echo "  Certificate Type: Code Signing"
	@echo ""
	@echo "Após criar, rode 'make build' novamente."
	@open -a "Keychain Access"

clean:
	@rm -rf $(BUNDLE) .build make_icon
