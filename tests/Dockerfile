# Dockerfile for testing yoloclaude
#
# This creates an environment that simulates a real Linux system
# with user management, sudo, and git.

FROM ubuntu:22.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    git \
    sudo \
    bash \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create a test user (simulates the "invoking user")
RUN useradd -m -s /bin/bash testuser \
    && echo "testuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/testuser \
    && chmod 440 /etc/sudoers.d/testuser

# Create a directory for the yoloclaude source
WORKDIR /opt/yoloclaude

# Copy yoloclaude source files
COPY yoloclaude yoloclaude-setup install.sh README.md LICENSE ./
COPY tests/ ./tests/

# Make scripts executable
RUN chmod +x yoloclaude yoloclaude-setup tests/*.sh 2>/dev/null || true

# Install mock claude to PATH
RUN cp tests/mock-claude /usr/local/bin/claude 2>/dev/null || true \
    && chmod +x /usr/local/bin/claude 2>/dev/null || true

# Set up git config for testuser
RUN sudo -u testuser git config --global user.name "Test User" \
    && sudo -u testuser git config --global user.email "test@example.com" \
    && sudo -u testuser git config --global init.defaultBranch main

# Create repos directory for testuser
RUN mkdir -p /home/testuser/repos \
    && chown testuser:testuser /home/testuser/repos

# Default command runs the test suite
CMD ["sudo", "-u", "testuser", "/opt/yoloclaude/tests/run-tests.sh"]
