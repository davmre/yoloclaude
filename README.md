# yoloclaude

Run Claude Code with `--dangerously-skip-permissions` in a sandboxed user environment.

## Overview

`yoloclaude` wraps Claude Code to run it as a separate `claude` system user. This provides containment through Unix permissions - the agent can freely install packages, modify files, and run commands within its own user account, while being unable to access or modify files belonging to other users.

### How it works

```
GitHub/Remote
    ↑ (you push - gated)
~/repos/project/                  # Your local repo (source of truth)
    ↑ (claude pushes)
~claude/projects/project/         # Claude's clone (origin → your repo)
```

Claude's git "origin" points to your local repository, not the remote. This means:
- Claude can commit and push freely using normal git workflow
- But those pushes only reach your local repo
- You remain the gatekeeper for what actually gets pushed to GitHub

## Installation

### Prerequisites

- macOS or Linux
- Python 3.9+
- `sudo` access
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code` or similar)

### Setup

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/yoloclaude.git
   cd yoloclaude
   ```

2. Run the setup script to create the `claude` user:
   ```bash
   sudo ./yoloclaude-setup
   ```

3. Authenticate Claude Code for the `claude` user:
   ```bash
   sudo -u claude -i claude
   ```
   Complete the authentication flow, then exit with `/exit`.

4. Add `yoloclaude` to your PATH (optional):
   ```bash
   # Add to ~/.bashrc or ~/.zshrc:
   export PATH="/path/to/yoloclaude:$PATH"
   ```

## Usage

### Start a session with a GitHub repo

```bash
yoloclaude https://github.com/user/repo
```

This will:
1. Clone the repo to `~/repos/repo` (if not already present)
2. Clone that to `~claude/projects/repo` (with origin pointing to your local clone)
3. Start Claude Code in the claude user's clone
4. When done, offer to push changes back to your local repo

### Start a session with a local repo

```bash
yoloclaude /path/to/your/project
```

This uses your existing local repo as the origin for Claude's clone.

### Use an existing project

If you've already cloned a repo to `~/repos/`:

```bash
yoloclaude myproject
```

### Pass arguments to Claude

Any additional arguments are passed through to `claude`:

```bash
yoloclaude myproject --print
yoloclaude myproject -p "Fix the bug in auth.py"
```

## End of session

When you exit Claude Code, `yoloclaude` will:

1. Check for uncommitted changes in Claude's working directory
2. Check for unpushed commits
3. Offer to push commits to your local repo
4. Optionally offer to push from your local repo to the remote

This gives you a chance to review Claude's changes before they reach your shared remote.

## Directory structure

```
~/repos/                          # Your local clones (origin for Claude)
    └── myproject/

~claude/
    ├── projects/                 # Claude's working copies
    │   └── myproject/            # origin → ~/repos/myproject
    └── .yoloclaude/              # Config and state (future use)
```

## Security considerations

- The `claude` user has no special privileges
- It cannot read or write files outside its home directory (unless world-readable/writable)
- It cannot sudo or access other users' data
- Git pushes only reach your local repo; you control what goes to remote

This is defense-in-depth: even if Claude Code does something unexpected, the Unix permission system limits the blast radius.

## Troubleshooting

### "Cannot sudo to claude user"

Make sure you've run `sudo ./yoloclaude-setup` from your regular user account.

### "Claude home directory does not exist"

Run the setup script: `sudo ./yoloclaude-setup`

### Authentication issues

Re-run the Claude Code auth as the claude user:
```bash
sudo -u claude -i claude
```

## Development

### Running tests

Tests run in Docker to avoid touching your actual system. This simulates the full workflow including user creation, git operations, and session management.

```bash
# Run the test suite
./tests/docker-test.sh

# Drop into a shell for debugging
./tests/docker-test.sh --shell
```

The tests use a mock `claude` script that simulates Claude Code's behavior (creating files and commits).

### CI

Tests run automatically on GitHub Actions for every push and PR. See `.github/workflows/test.yml`.

## Future plans

- Session resume (`yoloclaude --resume`)
- Concurrent worktrees for parallel sessions
- MCP server configuration

## License

Apache 2.0
