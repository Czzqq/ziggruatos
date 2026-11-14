USER_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR := $(USER_DIR)/user-out
BIN_DIR := $(USER_DIR)/bin
LIB_DIR := $(USER_DIR)/lib
TARGET := riscv64imac-unknown-none-elf
MODE ?= release

USER_APPS := $(patsubst $(BIN_DIR)/%/Cargo.toml,%,$(wildcard $(BIN_DIR)/*/Cargo.toml))

.PHONY: all build clean $(USER_APPS)

all: build

build: $(USER_APPS)

$(USER_APPS):
	@printf " CC   src/user/bin/%s\n" "$@"
	@cd $(BIN_DIR)/$@ && \
		cargo build --target $(TARGET) --$(MODE) --quiet > /dev/null 2>&1 || \
		(printf " ERROR building %s\n" "$@" && exit 1)
	@mkdir -p $(BUILD_DIR)
	@cp $(USER_DIR)/target/$(TARGET)/$(MODE)/$@ $(BUILD_DIR)/ 2>/dev/null || \
		(printf " ERROR copying binary %s\n" "$@" && exit 1)

clean:
	@printf " clean user ...\n"
	@for app in $(USER_APPS); do \
		cd $(BIN_DIR)/$$app && cargo clean 2>/dev/null || true; \
	done
	@cd $(LIB_DIR) && for lib in */; do \
		cd $(LIB_DIR)/$$lib && cargo clean 2>/dev/null || true; \
	done
	@rm -rf $(BUILD_DIR) 2>/dev/null || true
