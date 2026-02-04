#~ nj: Claude Statusline Build (Odin)

ODIN     := odin
OFLAGS   := -o:speed -no-bounds-check -disable-assert -microarch:native

PREFIX   := $(HOME)/.claude
BIN      := statusline

.PHONY: all clean install

all: $(BIN)

$(BIN): statusline.odin
	$(ODIN) build . $(OFLAGS) -out:$(BIN)

clean:
	rm -f $(BIN)

install: $(BIN)
	cp $(BIN) $(PREFIX)/$(BIN)
	@echo "Installed to $(PREFIX)/$(BIN)"
	@echo "Update ~/.claude/settings.json:"
	@echo '  "statusLine": {"type": "command", "command": "$(PREFIX)/$(BIN)"}'

# Build the legacy C version
legacy:
	$(MAKE) -f Makefile.c-legacy
