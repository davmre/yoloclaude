#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yoloclaude"
BIN_DIR="$HOME/.local/bin"

# Get directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uninstall() {
    rm -rf "$INSTALL_DIR"
    rm -f "$BIN_DIR/yoloclaude"
    echo "Uninstalled yoloclaude"
    echo "Note: This does not remove the claude user or system configuration."
}

install() {
    # Create directories
    mkdir -p "$INSTALL_DIR" "$BIN_DIR"

    # Copy files
    cp "$SCRIPT_DIR/yoloclaude" "$SCRIPT_DIR/yoloclaude-setup" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/yoloclaude" "$INSTALL_DIR/yoloclaude-setup"

    # Create symlink (force to overwrite existing)
    ln -sf "$INSTALL_DIR/yoloclaude" "$BIN_DIR/yoloclaude"

    echo "Installed yoloclaude to $INSTALL_DIR"
    echo "Symlinked to $BIN_DIR/yoloclaude"
    echo ""
    echo "Next steps:"
    echo "  1. Ensure ~/.local/bin is in your PATH"
    echo "  2. Run: sudo $INSTALL_DIR/yoloclaude-setup"
}

case "${1:-}" in
    --uninstall)
        uninstall
        ;;
    --help|-h)
        echo "Usage: ./install.sh [--uninstall]"
        echo ""
        echo "Install yoloclaude to ~/.local/share/yoloclaude"
        echo ""
        echo "Options:"
        echo "  --uninstall  Remove yoloclaude installation"
        echo "  --help       Show this help message"
        ;;
    "")
        install
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run './install.sh --help' for usage"
        exit 1
        ;;
esac
