#~ nj: Claude Statusline Build

PREFIX   := $(HOME)/.claude
BIN      := statusline

# C version (default)
CC       := cc
CFLAGS   := -O3 -march=native -Wall -Wextra -Wno-unused-parameter -Wno-unused-result

# Odin version
ODIN     := odin
OFLAGS   := -o:speed -no-bounds-check -disable-assert -microarch:native

.PHONY: all clean install install-odin bench odin

all: $(BIN)

$(BIN): statusline.c
	$(CC) $(CFLAGS) -o $@ $<

odin: statusline_odin

statusline_odin: statusline.odin
	$(ODIN) build . $(OFLAGS) -out:$@

clean:
	rm -f $(BIN) statusline_odin

install: $(BIN)
	-mv $(PREFIX)/$(BIN) $(PREFIX)/$(BIN).old
	cp $(BIN) $(PREFIX)/$(BIN)
	-rm -f $(PREFIX)/$(BIN).old
	@echo "Installed to $(PREFIX)/$(BIN)"

install-odin: statusline_odin
	-mv $(PREFIX)/$(BIN) $(PREFIX)/$(BIN).old
	cp statusline_odin $(PREFIX)/$(BIN)
	-rm -f $(PREFIX)/$(BIN).old
	@echo "Installed Odin version to $(PREFIX)/$(BIN)"

bench: $(BIN) statusline_odin
	@JSON='{"current_dir":"$(PWD)","display_name":"Opus 4.6","total_cost_usd":1.23,"total_lines_added":42,"total_lines_removed":7,"total_duration_ms":120000,"used_percentage":35,"context_window_size":200000}'; \
	echo "=== C ==="; \
	echo "$$JSON" | ./$(BIN); echo ""; \
	echo "=== Odin ==="; \
	echo "$$JSON" | ./statusline_odin; echo ""
