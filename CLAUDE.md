# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

yoloclaude runs Claude Code with `--dangerously-skip-permissions` in a sandboxed user environment. It creates a separate `claude` system user and uses git worktrees to isolate Claude's work while maintaining a safe sync pathway back to the user's repositories.

## Architecture

**Two-tier isolation model:**
1. **User isolation**: A `claude` system user runs Claude Code, isolated via Unix permissions
2. **Git isolation**: Claude's git origin points to the invoking user's local repo (not the remote), so pushes stay local

**Key flow:**
```
GitHub/Remote
    ↑ (you push - gated)
~/repos/project/                  # User's local repo (origin for Claude)
    ↑ (synced via git bundle)
~claude/projects/project/         # Claude's clone
    └── worktrees/branch-name/    # Isolated worktree per session
```

**Main components:**
- `yoloclaude` (Python): Main CLI that manages sessions, worktrees, and git sync
- `yoloclaude-setup` (Bash): One-time setup creating the `claude` user with appropriate permissions

## Commands

**Run tests** (Docker-based, safe for system):
```bash
./tests/docker-test.sh           # Run full test suite
./tests/docker-test.sh --shell   # Drop into container for debugging
```

**Lint:**
```bash
python -m py_compile yoloclaude  # Check Python syntax
bash -n yoloclaude-setup         # Check Bash syntax
```

**CI runs both tests and lint on push/PR to main.**

## Key Implementation Details

- Sessions stored in `~/.yoloclaude/sessions/` (invoking user's home)
- Worktrees stored in `~claude/projects/<project>/worktrees/`
- Git sync uses bundles to avoid "dubious ownership" errors
- macOS requires keychain setup for credential storage
- Feature flags in `~claude/.claude.json` may need disabling (`tengu_mcp_tool_search`, `tengu_scratch`)
