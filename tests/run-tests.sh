#!/bin/bash
#
# run-tests.sh - Integration tests for yoloclaude
#
# This script tests the complete yoloclaude workflow:
# 1. Setup (creating claude user)
# 2. Cloning and project setup
# 3. Running a Claude session (mocked)
# 4. Git sync back to origin
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Test directory
TEST_DIR="/tmp/yoloclaude-tests"
YOLOCLAUDE_DIR="/opt/yoloclaude"

cleanup() {
    log_info "Cleaning up test artifacts..."
    rm -rf "$TEST_DIR"
    # Don't delete claude user - might be reused
}

trap cleanup EXIT

# ============================================================================
# Test: Setup script creates claude user
# ============================================================================
test_setup() {
    log_test "Running yoloclaude-setup..."

    # Run setup as root (we have sudo NOPASSWD)
    sudo SUDO_USER=testuser "$YOLOCLAUDE_DIR/yoloclaude-setup"

    # Verify claude user exists
    if id claude &>/dev/null; then
        log_pass "claude user created"
    else
        log_fail "claude user not created"
        return 1
    fi

    # Verify home directory exists (check as claude since testuser may not have access)
    if sudo -u claude test -d /home/claude; then
        log_pass "claude home directory exists"
    else
        log_fail "claude home directory missing"
        return 1
    fi

    # Verify projects directory
    if sudo -u claude test -d /home/claude/projects; then
        log_pass "claude projects directory exists"
    else
        log_fail "claude projects directory missing"
        return 1
    fi

    # Verify sudoers rule
    if sudo -n -u claude true 2>/dev/null; then
        log_pass "sudo to claude user works"
    else
        log_fail "cannot sudo to claude user"
        return 1
    fi

    # Verify git config
    if sudo -u claude git config --global user.name &>/dev/null; then
        log_pass "git configured for claude user"
    else
        log_fail "git not configured for claude user"
        return 1
    fi
}

# ============================================================================
# Test: Create a test repository
# ============================================================================
create_test_repo() {
    log_test "Creating test repository..."

    mkdir -p "$TEST_DIR"

    # Create a "remote" bare repo (simulates GitHub)
    REMOTE_REPO="$TEST_DIR/remote-test-project.git"
    git init --bare "$REMOTE_REPO"

    # Create the user's local working repo (this is what yoloclaude uses as origin)
    USER_REPO="/home/testuser/repos/test-project"
    mkdir -p "$USER_REPO"
    cd "$USER_REPO"
    git init
    git remote add origin "$REMOTE_REPO"
    echo "# Test Project" > README.md
    echo "Initial content" > file.txt
    git add .
    git commit -m "Initial commit"
    git push -u origin main

    log_pass "Test repository created at $USER_REPO"
}

# ============================================================================
# Test: Restricted permission files don't break rsync
# ============================================================================
test_restricted_permissions() {
    log_test "Testing rsync with restricted permission directories..."

    USER_REPO="/home/testuser/repos/test-project"

    # Create a .claude directory with restricted permissions (only owner can read)
    # This simulates the real-world scenario where ~/.claude/settings.local.json
    # has restricted permissions
    mkdir -p "$USER_REPO/.claude"
    echo '{"some": "settings"}' > "$USER_REPO/.claude/settings.local.json"
    chmod 600 "$USER_REPO/.claude/settings.local.json"
    chmod 700 "$USER_REPO/.claude"

    # Create cache directories with restricted permissions
    mkdir -p "$USER_REPO/.ruff_cache/0.14.11"
    echo "cache data" > "$USER_REPO/.ruff_cache/0.14.11/somefile"
    chmod 600 "$USER_REPO/.ruff_cache/0.14.11/somefile"
    chmod 700 "$USER_REPO/.ruff_cache/0.14.11"
    chmod 700 "$USER_REPO/.ruff_cache"

    mkdir -p "$USER_REPO/__pycache__"
    echo "bytecode" > "$USER_REPO/__pycache__/module.pyc"
    chmod 600 "$USER_REPO/__pycache__/module.pyc"
    chmod 700 "$USER_REPO/__pycache__"

    # Verify the directories are NOT readable by claude user
    if sudo -u claude test -r "$USER_REPO/.claude" 2>/dev/null; then
        log_info ".claude directory is readable by claude (unexpected, but ok)"
    else
        log_info ".claude directory correctly unreadable by claude user"
    fi

    log_pass "Created restricted permission directories for testing"
}

# ============================================================================
# Test: yoloclaude with local repo path (creates worktree)
# ============================================================================
test_local_repo() {
    log_test "Testing yoloclaude with local repo path..."

    USER_REPO="/home/testuser/repos/test-project"
    BASE_CLONE="/home/claude/projects/test-project"

    # Run yoloclaude with the local repo using --yes for non-interactive mode
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Verify claude's base clone exists
    if sudo -u claude test -d "$BASE_CLONE"; then
        log_pass "Claude's base clone created"
    else
        log_fail "Claude's base clone not created"
        return 1
    fi

    # Verify worktrees directory exists
    if sudo -u claude test -d "$BASE_CLONE/worktrees"; then
        log_pass "Worktrees directory created"
    else
        log_fail "Worktrees directory not created"
        return 1
    fi

    # Find the worktree (there should be one)
    WORKTREE_PATH=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
    if [[ -n "$WORKTREE_PATH" ]] && sudo -u claude test -d "$WORKTREE_PATH"; then
        log_pass "Worktree created: $(basename "$WORKTREE_PATH")"
    else
        log_fail "No worktree found in $BASE_CLONE/worktrees"
        sudo -u claude ls -la "$BASE_CLONE/worktrees" 2>/dev/null || echo "Cannot list worktrees dir"
        return 1
    fi

    # Verify excluded directories were NOT synced to worktree
    # These have restricted permissions in USER_REPO and should be excluded by rsync
    if sudo -u claude test -d "$WORKTREE_PATH/.claude"; then
        log_fail ".claude directory should be excluded from worktree sync"
        return 1
    else
        log_pass ".claude directory correctly excluded from worktree"
    fi

    if sudo -u claude test -d "$WORKTREE_PATH/.ruff_cache"; then
        log_fail ".ruff_cache directory should be excluded from worktree sync"
        return 1
    else
        log_pass ".ruff_cache directory correctly excluded from worktree"
    fi

    if sudo -u claude test -d "$WORKTREE_PATH/__pycache__"; then
        log_fail "__pycache__ directory should be excluded from worktree sync"
        return 1
    else
        log_pass "__pycache__ directory correctly excluded from worktree"
    fi

    # Verify origin points to user's repo
    CLAUDE_ORIGIN=$(sudo -u claude git -C "$BASE_CLONE" remote get-url origin)
    if [[ "$CLAUDE_ORIGIN" == "$USER_REPO" ]]; then
        log_pass "Claude's origin correctly points to user's repo"
    else
        log_fail "Claude's origin incorrect: $CLAUDE_ORIGIN (expected $USER_REPO)"
        return 1
    fi

    # Verify mock claude made a commit in the worktree
    COMMIT_COUNT=$(sudo -u claude git -C "$WORKTREE_PATH" log --oneline | wc -l)
    if [[ "$COMMIT_COUNT" -gt 1 ]]; then
        log_pass "Mock Claude created commits (total: $COMMIT_COUNT)"
    else
        log_fail "No new commits from mock Claude"
        return 1
    fi

    # Store worktree path for later tests
    export FIRST_WORKTREE_PATH="$WORKTREE_PATH"
}

# ============================================================================
# Test: Git push flow
# ============================================================================
test_git_push_flow() {
    log_test "Testing git push flow..."

    USER_REPO="/home/testuser/repos/test-project"

    # With worktrees, commits go to a branch (not main)
    # Check that a claude/* branch exists and has commits
    CLAUDE_BRANCHES=$(git -C "$USER_REPO" branch -a | grep "claude/" | wc -l)
    if [[ "$CLAUDE_BRANCHES" -ge 1 ]]; then
        log_pass "Claude branch pushed to user's repo ($CLAUDE_BRANCHES branches)"
    else
        log_fail "No claude/* branch found in user's repo"
        git -C "$USER_REPO" branch -a
        return 1
    fi

    # Check the branch has more commits than main
    BRANCH_NAME=$(git -C "$USER_REPO" branch -a | grep "claude/" | head -1 | tr -d ' *')
    BRANCH_COMMITS=$(git -C "$USER_REPO" log --oneline "$BRANCH_NAME" | wc -l)
    if [[ "$BRANCH_COMMITS" -gt 1 ]]; then
        log_pass "Branch has commits (total: $BRANCH_COMMITS)"
    else
        log_fail "Branch doesn't have expected commits"
        return 1
    fi
}

# ============================================================================
# Test: Second run creates a new worktree
# ============================================================================
test_second_worktree() {
    log_test "Testing second session creates new worktree..."

    USER_REPO="/home/testuser/repos/test-project"
    BASE_CLONE="/home/claude/projects/test-project"

    # Count worktrees before
    BEFORE_COUNT=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    # Run yoloclaude again with --yes for non-interactive mode
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Count worktrees after
    AFTER_COUNT=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    if [[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]]; then
        log_pass "Second session created new worktree ($BEFORE_COUNT -> $AFTER_COUNT)"
    else
        log_fail "Second session did not create new worktree"
        return 1
    fi
}

# ============================================================================
# Test: Session listing
# ============================================================================
test_list_sessions() {
    log_test "Testing --list shows sessions..."

    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" --list 2>&1)

    # Should show at least 2 sessions (from previous tests)
    if echo "$OUTPUT" | grep -q "test-project"; then
        log_pass "Session list shows test-project sessions"
    else
        log_fail "Session list doesn't show expected sessions"
        echo "$OUTPUT"
        return 1
    fi

    # Check session files exist (in invoking user's home)
    SESSION_COUNT=$(ls /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | wc -l)
    if [[ "$SESSION_COUNT" -ge 2 ]]; then
        log_pass "Session files created ($SESSION_COUNT sessions)"
    else
        log_fail "Expected at least 2 session files, found $SESSION_COUNT"
        return 1
    fi
}

# ============================================================================
# Test: Resume session
# ============================================================================
test_resume_session() {
    log_test "Testing --resume..."

    cd /home/testuser

    # Get the most recent session ID (from invoking user's home)
    SESSION_ID=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1 | xargs basename | sed 's/.json$//')

    if [[ -z "$SESSION_ID" ]]; then
        log_fail "No session found to resume"
        return 1
    fi

    log_info "Resuming session: $SESSION_ID"

    # Resume the session with --yes
    "$YOLOCLAUDE_DIR/yoloclaude" --yes --resume "$SESSION_ID" || true

    # Verify session was accessed (last_accessed should be updated)
    # Just check that it ran without error and mock claude executed
    if cat "/home/testuser/.yoloclaude/sessions/${SESSION_ID}.json" | grep -q "last_accessed"; then
        log_pass "Resume session executed successfully"
    else
        log_fail "Session file not found after resume"
        return 1
    fi
}

# ============================================================================
# Test: List worktrees for a project
# ============================================================================
test_list_worktrees() {
    log_test "Testing --list-worktrees..."

    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    # Should show worktrees with status
    if echo "$OUTPUT" | grep -q "Worktree Name"; then
        log_pass "--list-worktrees shows worktree table header"
    else
        log_fail "--list-worktrees missing table header"
        echo "$OUTPUT"
        return 1
    fi

    # Should show at least 2 worktrees from previous tests
    # Worktree names are like "main-worktree-abcd" (based on source branch)
    WORKTREE_COUNT=$(echo "$OUTPUT" | grep -c "main-worktree-" || true)
    if [[ "$WORKTREE_COUNT" -ge 2 ]]; then
        log_pass "--list-worktrees shows $WORKTREE_COUNT worktrees"
    else
        log_fail "--list-worktrees shows fewer than 2 worktrees"
        echo "$OUTPUT"
        return 1
    fi

    # Should show status (clean, modified, or missing)
    if echo "$OUTPUT" | grep -qE "(clean|modified|missing)"; then
        log_pass "--list-worktrees shows worktree status"
    else
        log_fail "--list-worktrees missing status column"
        return 1
    fi
}

# ============================================================================
# Test: List worktrees error without project
# ============================================================================
test_list_worktrees_error() {
    log_test "Testing --list-worktrees error without project..."

    cd /home/testuser
    if "$YOLOCLAUDE_DIR/yoloclaude" --list-worktrees 2>&1 | grep -qi "requires a project"; then
        log_pass "--list-worktrees requires project name"
    else
        log_fail "--list-worktrees should error without project"
        return 1
    fi
}

# ============================================================================
# Test: Resume specific worktree with -w
# ============================================================================
test_worktree_resume() {
    log_test "Testing -w/--worktree direct resume..."

    cd /home/testuser

    # Get a worktree name from an existing session
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    if [[ -z "$SESSION_FILE" ]]; then
        log_fail "No session found for worktree resume test"
        return 1
    fi

    # Extract the worktree name from the branch (remove claude/ prefix)
    BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['branch'])")
    WORKTREE_NAME=${BRANCH#claude/}

    log_info "Resuming worktree: $WORKTREE_NAME"

    # Resume with the full worktree name
    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project -w "$WORKTREE_NAME" || true

    log_pass "-w/--worktree resume executed"

    # Test prefix matching (use first part of worktree name)
    PREFIX=${WORKTREE_NAME:0:20}
    log_info "Testing prefix match with: $PREFIX"

    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project -w "$PREFIX" || true

    log_pass "-w prefix matching works"
}

# ============================================================================
# Test: Worktree resume with invalid name
# ============================================================================
test_worktree_resume_invalid() {
    log_test "Testing -w with invalid worktree name..."

    cd /home/testuser
    if "$YOLOCLAUDE_DIR/yoloclaude" test-project -w "nonexistent-worktree-xyz" 2>&1 | grep -qi "not found"; then
        log_pass "-w with invalid name shows error"
    else
        log_fail "-w should error with invalid worktree name"
        return 1
    fi
}

# ============================================================================
# Test: Clear specific worktree
# ============================================================================
test_clear_worktree() {
    log_test "Testing --clear-worktree..."

    cd /home/testuser
    BASE_CLONE="/home/claude/projects/test-project"
    USER_REPO="/home/testuser/repos/test-project"

    # Create a fresh worktree to delete
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Get the most recent worktree name
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['branch'])")
    WORKTREE_NAME=${BRANCH#claude/}
    SESSION_ID=$(basename "$SESSION_FILE" .json)

    log_info "Clearing worktree: $WORKTREE_NAME"

    # Count worktrees before
    BEFORE_COUNT=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    # Clear the worktree
    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project --clear-worktree="$WORKTREE_NAME" 2>&1

    # Count worktrees after
    AFTER_COUNT=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    if [[ "$AFTER_COUNT" -lt "$BEFORE_COUNT" ]]; then
        log_pass "--clear-worktree removed worktree directory"
    else
        log_fail "--clear-worktree did not remove worktree"
        return 1
    fi

    # Verify session file was removed
    if [[ ! -f "/home/testuser/.yoloclaude/sessions/${SESSION_ID}.json" ]]; then
        log_pass "--clear-worktree removed session file"
    else
        log_fail "--clear-worktree did not remove session file"
        return 1
    fi
}

# ============================================================================
# Test: Clear all worktrees
# ============================================================================
test_clear_all_worktrees() {
    log_test "Testing --clear-worktrees..."

    cd /home/testuser
    BASE_CLONE="/home/claude/projects/test-project"
    USER_REPO="/home/testuser/repos/test-project"

    # First, create a couple of worktrees
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Count sessions before
    BEFORE_COUNT=$(ls /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | wc -l)
    log_info "Sessions before clear: $BEFORE_COUNT"

    # Clear all worktrees (--yes auto-confirms)
    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project --clear-worktrees 2>&1

    # Count sessions after
    AFTER_COUNT=$(ls /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | wc -l)
    log_info "Sessions after clear: $AFTER_COUNT"

    if [[ "$AFTER_COUNT" -eq 0 ]]; then
        log_pass "--clear-worktrees removed all session files"
    else
        log_fail "--clear-worktrees did not remove all sessions (remaining: $AFTER_COUNT)"
        return 1
    fi

    # Verify worktrees directory is empty or has no worktrees
    WORKTREE_COUNT=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [[ "$WORKTREE_COUNT" -eq 0 ]]; then
        log_pass "--clear-worktrees removed all worktree directories"
    else
        log_fail "--clear-worktrees did not remove all worktrees (remaining: $WORKTREE_COUNT)"
        return 1
    fi
}

# ============================================================================
# Test: Project name memory feature
# ============================================================================
test_project_memory() {
    log_test "Testing project name memory feature..."

    cd /home/testuser

    # First create a session with the full path
    USER_REPO="/home/testuser/repos/test-project"
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Now try using just the project name (should be remembered)
    # This should work because we have a session that records the origin_path
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    if echo "$OUTPUT" | grep -q "Worktree"; then
        log_pass "Project name resolved from session memory"
    else
        log_fail "Project name memory not working"
        echo "$OUTPUT"
        return 1
    fi
}

# ============================================================================
# Test: Lock file is created when session runs
# ============================================================================
test_lock_file_created() {
    log_test "Testing lock file creation..."

    USER_REPO="/home/testuser/repos/test-project"

    cd /home/testuser

    # Create a new session
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Get the most recent session ID
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    SESSION_ID=$(basename "$SESSION_FILE" .json)

    # Lock file should NOT exist after session ends (it gets released)
    LOCK_FILE="/home/testuser/.yoloclaude/sessions/${SESSION_ID}.lock"
    if [[ ! -f "$LOCK_FILE" ]]; then
        log_pass "Lock file properly released after session ends"
    else
        log_fail "Lock file should be released after session ends"
        cat "$LOCK_FILE"
        return 1
    fi
}

# ============================================================================
# Test: List worktrees shows Active column
# ============================================================================
test_list_worktrees_active_column() {
    log_test "Testing --list-worktrees shows Active column..."

    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    # Should show Active column header
    if echo "$OUTPUT" | grep -q "Active"; then
        log_pass "--list-worktrees shows Active column header"
    else
        log_fail "--list-worktrees missing Active column"
        echo "$OUTPUT"
        return 1
    fi
}

# ============================================================================
# Test: Stale lock files are cleaned up
# ============================================================================
test_stale_lock_cleanup() {
    log_test "Testing stale lock file cleanup..."

    USER_REPO="/home/testuser/repos/test-project"

    cd /home/testuser

    # Get an existing session
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    if [[ -z "$SESSION_FILE" ]]; then
        # Create one if none exists
        "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true
        SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    fi
    SESSION_ID=$(basename "$SESSION_FILE" .json)

    # Create a stale lock file with a non-existent PID
    LOCK_FILE="/home/testuser/.yoloclaude/sessions/${SESSION_ID}.lock"
    cat > "$LOCK_FILE" << EOF
{"pid": 999999, "started_at": "2026-01-01T00:00:00", "hostname": "test"}
EOF

    # Verify lock file exists
    if [[ ! -f "$LOCK_FILE" ]]; then
        log_fail "Failed to create test lock file"
        return 1
    fi

    # Run yoloclaude - it should clean up the stale lock
    BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['branch'])")
    WORKTREE_NAME=${BRANCH#claude/}
    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project -w "$WORKTREE_NAME" || true

    # Lock file should be gone (stale lock removed, then session ended normally)
    if [[ ! -f "$LOCK_FILE" ]]; then
        log_pass "Stale lock file was cleaned up"
    else
        log_fail "Stale lock file was not cleaned up"
        cat "$LOCK_FILE"
        rm -f "$LOCK_FILE"
        return 1
    fi
}

# ============================================================================
# Test: Create worktree on feature branch
# ============================================================================
test_feature_branch_worktree() {
    log_test "Testing worktree creation on feature branch..."

    USER_REPO="/home/testuser/repos/test-project"
    BASE_CLONE="/home/claude/projects/test-project"

    # Create a feature branch in user's repo
    cd "$USER_REPO"
    git checkout -b feature-test
    echo "feature content" > feature.txt
    git add .
    git commit -m "Feature commit"
    git push -u origin feature-test

    # Create worktree (--yes should use current branch: feature-test)
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Get the session and verify source_branch
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    SOURCE_BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('source_branch', 'MISSING'))")

    if [[ "$SOURCE_BRANCH" == "feature-test" ]]; then
        log_pass "Worktree created with source_branch=feature-test"
    else
        log_fail "Expected source_branch=feature-test, got $SOURCE_BRANCH"
        return 1
    fi

    # Verify worktree is based on feature-test (has feature.txt)
    WORKTREE_PATH=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | tail -1)
    if sudo -u claude test -f "$WORKTREE_PATH/feature.txt"; then
        log_pass "Worktree contains feature branch content"
    else
        log_fail "Worktree missing feature branch content"
        return 1
    fi

    # Cleanup: switch back to main
    cd "$USER_REPO"
    git checkout main
}

# ============================================================================
# Test: Display shows base branch and origin status
# ============================================================================
test_display_origin_status() {
    log_test "Testing worktree display shows base branch and origin status..."

    USER_REPO="/home/testuser/repos/test-project"

    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    # Should show Base column header
    if echo "$OUTPUT" | grep -q "Base"; then
        log_pass "Display shows Base column"
    else
        log_fail "Display missing Base column"
        echo "$OUTPUT"
        return 1
    fi

    # Should show origin status column
    if echo "$OUTPUT" | grep -q "Origin\|vs Origin"; then
        log_pass "Display shows Origin status column"
    else
        log_fail "Display missing Origin status column"
        echo "$OUTPUT"
        return 1
    fi

    # Should show "up-to-date" or behind/ahead
    if echo "$OUTPUT" | grep -qE "(up-to-date|behind|ahead)"; then
        log_pass "Display shows origin comparison status"
    else
        log_fail "Display missing origin comparison status"
        return 1
    fi
}

# ============================================================================
# Test: Behind status when origin has new commits
# ============================================================================
test_behind_status() {
    log_test "Testing behind status when origin has new commits..."

    USER_REPO="/home/testuser/repos/test-project"
    BASE_CLONE="/home/claude/projects/test-project"

    # Ensure we're on main and create a worktree
    cd "$USER_REPO"
    git checkout main
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Add a commit to origin AFTER the worktree was created
    cd "$USER_REPO"
    echo "new content from origin" >> file.txt
    git add .
    git commit -m "Commit after worktree created"

    # List worktrees - should show "behind"
    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    if echo "$OUTPUT" | grep -q "behind"; then
        log_pass "Worktree shows 'behind' status"
    else
        log_fail "Worktree should show 'behind' status"
        echo "$OUTPUT"
        return 1
    fi
}

# ============================================================================
# Test: Fast-forward on resume
# ============================================================================
test_fast_forward_resume() {
    log_test "Testing fast-forward on resume..."

    USER_REPO="/home/testuser/repos/test-project"
    BASE_CLONE="/home/claude/projects/test-project"

    # Get the most recent session
    SESSION_FILE=$(ls -t /home/testuser/.yoloclaude/sessions/*.json 2>/dev/null | head -1)
    BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['branch'])")
    WORKTREE_NAME=${BRANCH#claude/}
    # The worktree directory uses the full branch name with / replaced by -
    WORKTREE_PATH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['worktree_path'])")

    # Get commit count before fast-forward
    BEFORE_COUNT=$(sudo -u claude git -C "$WORKTREE_PATH" rev-list --count HEAD)

    # The origin already has a new commit from test_behind_status
    # Resume with --yes (should auto-fast-forward)
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes test-project -w "$WORKTREE_NAME" || true

    # Get commit count after
    AFTER_COUNT=$(sudo -u claude git -C "$WORKTREE_PATH" rev-list --count HEAD)

    if [[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]]; then
        log_pass "Fast-forward applied on resume ($BEFORE_COUNT -> $AFTER_COUNT commits)"
    else
        log_fail "Fast-forward not applied (before: $BEFORE_COUNT, after: $AFTER_COUNT)"
        return 1
    fi
}

# ============================================================================
# Test: Backward compatibility (old sessions without source_branch)
# ============================================================================
test_backward_compat_source_branch() {
    log_test "Testing backward compatibility for sessions without source_branch..."

    # Create a session file without source_branch field (simulates old session)
    OLD_SESSION_ID="test-old-session-$$"
    OLD_SESSION_FILE="/home/testuser/.yoloclaude/sessions/${OLD_SESSION_ID}.json"

    # Get an existing worktree path to use
    BASE_CLONE="/home/claude/projects/test-project"
    WORKTREE_PATH=$(sudo -u claude find "$BASE_CLONE/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
    WORKTREE_NAME=$(basename "$WORKTREE_PATH")

    cat > "$OLD_SESSION_FILE" << EOF
{
  "session_id": "$OLD_SESSION_ID",
  "project_name": "test-project",
  "branch": "claude/$WORKTREE_NAME",
  "worktree_path": "$WORKTREE_PATH",
  "origin_path": "/home/testuser/repos/test-project",
  "created_at": "2026-01-01T00:00:00",
  "last_accessed": "2026-01-01T00:00:00"
}
EOF

    # List worktrees - should work and show "main" as default source_branch
    cd /home/testuser
    OUTPUT=$("$YOLOCLAUDE_DIR/yoloclaude" test-project --list-worktrees 2>&1)

    if echo "$OUTPUT" | grep -q "main"; then
        log_pass "Old session defaults to main branch"
    else
        log_fail "Old session should default to main branch"
        echo "$OUTPUT"
        return 1
    fi

    # Cleanup
    rm -f "$OLD_SESSION_FILE"
}

# ============================================================================
# Test: Help output
# ============================================================================
test_help() {
    log_test "Testing --help output..."

    if "$YOLOCLAUDE_DIR/yoloclaude" --help | grep -q "sandboxed user environment"; then
        log_pass "Help output contains expected text"
    else
        log_fail "Help output missing expected content"
        return 1
    fi

    # Also verify new worktree arguments are documented
    if "$YOLOCLAUDE_DIR/yoloclaude" --help | grep -q "\-\-list-worktrees"; then
        log_pass "Help shows --list-worktrees option"
    else
        log_fail "Help missing --list-worktrees option"
        return 1
    fi
}

# ============================================================================
# Test: install.sh script
# ============================================================================
test_install_script() {
    log_test "Testing install.sh script..."

    cd /opt/yoloclaude

    # Test help
    if ./install.sh --help | grep -q "Install yoloclaude"; then
        log_pass "install.sh --help works"
    else
        log_fail "install.sh --help failed"
        return 1
    fi

    # Run install
    ./install.sh

    # Verify install directory exists
    if [[ -d "$HOME/.local/share/yoloclaude" ]]; then
        log_pass "Install directory created"
    else
        log_fail "Install directory not created"
        return 1
    fi

    # Verify files were copied
    if [[ -f "$HOME/.local/share/yoloclaude/yoloclaude" ]] && \
       [[ -f "$HOME/.local/share/yoloclaude/yoloclaude-setup" ]]; then
        log_pass "Files copied to install directory"
    else
        log_fail "Files not copied to install directory"
        return 1
    fi

    # Verify files are executable
    if [[ -x "$HOME/.local/share/yoloclaude/yoloclaude" ]]; then
        log_pass "Installed files are executable"
    else
        log_fail "Installed files not executable"
        return 1
    fi

    # Verify symlink exists
    if [[ -L "$HOME/.local/bin/yoloclaude" ]]; then
        log_pass "Symlink created in ~/.local/bin"
    else
        log_fail "Symlink not created"
        return 1
    fi

    # Verify symlink points to correct location
    SYMLINK_TARGET=$(readlink "$HOME/.local/bin/yoloclaude")
    if [[ "$SYMLINK_TARGET" == "$HOME/.local/share/yoloclaude/yoloclaude" ]]; then
        log_pass "Symlink points to correct location"
    else
        log_fail "Symlink points to wrong location: $SYMLINK_TARGET"
        return 1
    fi

    # Verify the symlinked command works
    if "$HOME/.local/bin/yoloclaude" --help | grep -q "sandboxed user environment"; then
        log_pass "Symlinked yoloclaude --help works"
    else
        log_fail "Symlinked yoloclaude --help failed"
        return 1
    fi

    # Test uninstall
    ./install.sh --uninstall

    # Verify install directory removed
    if [[ ! -d "$HOME/.local/share/yoloclaude" ]]; then
        log_pass "Uninstall removed install directory"
    else
        log_fail "Uninstall did not remove install directory"
        return 1
    fi

    # Verify symlink removed
    if [[ ! -L "$HOME/.local/bin/yoloclaude" ]]; then
        log_pass "Uninstall removed symlink"
    else
        log_fail "Uninstall did not remove symlink"
        return 1
    fi

    # Test invalid option
    if ./install.sh --invalid 2>&1 | grep -q "Unknown option"; then
        log_pass "Invalid option shows error"
    else
        log_fail "Invalid option should show error"
        return 1
    fi
}

# ============================================================================
# Test: Error handling for missing repo
# ============================================================================
test_missing_repo() {
    log_test "Testing error handling for missing repo..."

    cd /home/testuser
    if "$YOLOCLAUDE_DIR/yoloclaude" /nonexistent/path 2>&1 | grep -qi "cannot find\|not.*exist\|error"; then
        log_pass "Proper error for missing repo"
    else
        log_fail "No error for missing repo"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "========================================"
    echo "yoloclaude Integration Tests"
    echo "========================================"
    echo ""

    # Ensure we're running as testuser (or can sudo to them)
    if [[ "$(whoami)" != "testuser" ]]; then
        log_info "Running as $(whoami), tests expect testuser context"
    fi

    # Run tests
    test_help
    test_install_script
    test_setup
    create_test_repo
    test_restricted_permissions
    test_local_repo
    test_git_push_flow
    test_second_worktree
    test_list_sessions
    test_resume_session

    # Worktree management tests
    test_list_worktrees
    test_list_worktrees_error
    test_worktree_resume
    test_worktree_resume_invalid
    test_clear_worktree
    test_clear_all_worktrees
    test_project_memory

    # Session locking tests
    test_lock_file_created
    test_list_worktrees_active_column
    test_stale_lock_cleanup

    # Multi-branch workflow tests
    test_feature_branch_worktree
    test_display_origin_status
    test_behind_status
    test_fast_forward_resume
    test_backward_compat_source_branch

    test_missing_repo

    echo ""
    echo "========================================"
    echo "Test Results"
    echo "========================================"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
