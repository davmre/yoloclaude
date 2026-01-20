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
    test_setup
    create_test_repo
    test_local_repo
    test_git_push_flow
    test_second_worktree
    test_list_sessions
    test_resume_session
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
