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
# Test: yoloclaude with local repo path
# ============================================================================
test_local_repo() {
    log_test "Testing yoloclaude with local repo path..."

    USER_REPO="/home/testuser/repos/test-project"

    # Run yoloclaude with the local repo using --yes for non-interactive mode
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Verify claude's clone exists (check as claude since testuser may not have access)
    if sudo -u claude test -d /home/claude/projects/test-project; then
        log_pass "Claude's project clone created"
    else
        log_fail "Claude's project clone not created"
        return 1
    fi

    # Verify origin points to user's repo
    CLAUDE_ORIGIN=$(sudo -u claude git -C /home/claude/projects/test-project remote get-url origin)
    if [[ "$CLAUDE_ORIGIN" == "$USER_REPO" ]]; then
        log_pass "Claude's origin correctly points to user's repo"
    else
        log_fail "Claude's origin incorrect: $CLAUDE_ORIGIN (expected $USER_REPO)"
        return 1
    fi

    # Verify mock claude made a commit
    COMMIT_COUNT=$(sudo -u claude git -C /home/claude/projects/test-project log --oneline | wc -l)
    if [[ "$COMMIT_COUNT" -gt 1 ]]; then
        log_pass "Mock Claude created commits (total: $COMMIT_COUNT)"
    else
        log_fail "No new commits from mock Claude"
        return 1
    fi
}

# ============================================================================
# Test: Git push flow
# ============================================================================
test_git_push_flow() {
    log_test "Testing git push flow..."

    USER_REPO="/home/testuser/repos/test-project"

    # With --yes mode, commits should have been auto-pushed to user's repo
    # Verify commits arrived in user's repo (should have more than initial commit)
    USER_COMMITS=$(git -C "$USER_REPO" log --oneline | wc -l)
    if [[ "$USER_COMMITS" -gt 1 ]]; then
        log_pass "Commits successfully pushed to user's repo (total: $USER_COMMITS)"
    else
        log_fail "Commits not found in user's repo (only $USER_COMMITS commits)"
        return 1
    fi
}

# ============================================================================
# Test: Second run uses existing clone
# ============================================================================
test_existing_clone() {
    log_test "Testing reuse of existing clone..."

    USER_REPO="/home/testuser/repos/test-project"
    CLAUDE_REPO="/home/claude/projects/test-project"

    # Get current commit count
    BEFORE_COUNT=$(sudo -u claude git -C "$CLAUDE_REPO" log --oneline | wc -l)

    # Run yoloclaude again with --yes for non-interactive mode
    cd /home/testuser
    "$YOLOCLAUDE_DIR/yoloclaude" --yes "$USER_REPO" || true

    # Check commit count increased
    AFTER_COUNT=$(sudo -u claude git -C "$CLAUDE_REPO" log --oneline | wc -l)

    if [[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]]; then
        log_pass "Second run created new commits ($BEFORE_COUNT -> $AFTER_COUNT)"
    else
        log_fail "Second run did not create commits"
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
    test_existing_clone
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
