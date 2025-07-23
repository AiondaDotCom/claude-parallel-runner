# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Perl-based tool for executing multiple Claude Code instances in parallel with **asynchronous session management**. The main script (`claude-parallel-runner.pl`) reads JSON-formatted prompts and executes them concurrently in the background, solving the Claude Code 2-minute timeout limitation.

## Key Architecture

- **Main Script**: `claude-parallel-runner.pl` - Core Perl script with async session management
- **Async by Default**: All executions run in background, returning session IDs immediately
- **Session Management**: Each execution creates a persistent session with UUID tracking
- **Process Management**: Uses Unix `fork()` for creating child processes, each running a separate Claude instance
- **Persistent Storage**: Results stored in `./results/session-UUID/` directories
- **Status Tracking**: Real-time status updates via JSON files
- **Git Worktree Integration**: Optional `--worktree` flag creates isolated git branches for each task

## Common Commands

### Basic Execution (Async by Default)
```bash
# Start async session (returns immediately with session ID)
./claude-parallel-runner.pl example-prompts.json

# From STDIN - starts background session
echo '{"prompts":["task1","task2"]}' | ./claude-parallel-runner.pl

# Force synchronous execution (original behavior)
./claude-parallel-runner.pl --sync example-prompts.json
```

### Session Management
```bash
# Check status of specific session
./claude-parallel-runner.pl --status SESSION_ID

# View results of completed session
./claude-parallel-runner.pl --results SESSION_ID

# List all sessions (running and completed)
./claude-parallel-runner.pl --list

# Show overview statistics of all sessions
./claude-parallel-runner.pl --overview
```

### Advanced Options
```bash
# Limit parallel processes within a session
./claude-parallel-runner.pl --max-parallel=3 example-prompts.json

# Use git worktree isolation (recommended for code tasks)
./claude-parallel-runner.pl --worktree example-prompts.json

# Verbose output with session details
./claude-parallel-runner.pl --verbose example-prompts.json

# Combined options
./claude-parallel-runner.pl --worktree --max-parallel=2 --verbose example-prompts.json
```

### Development Commands
```bash
# Check Perl syntax
perl -c claude-parallel-runner.pl

# Run with debugging
perl -d claude-parallel-runner.pl example-prompts.json

# Test JSON parsing
perl -MJSON -e 'print decode_json(`cat example-prompts.json`)->{prompts}->[0]'
```

## Session Workflow

### Typical Usage Pattern
1. **Start Session**: Execute prompts file → Get session ID immediately
2. **Monitor Progress**: Use `--status SESSION_ID` to check progress
3. **View Results**: Use `--results SESSION_ID` when tasks complete
4. **Manage Sessions**: Use `--list` and `--overview` for session management

### Benefits of Async Design
- **No Timeout Issues**: Claude Code caller doesn't wait, eliminating 2-minute timeouts
- **Long-Running Tasks**: Tasks can run for hours without interruption
- **Multiple Sessions**: Run many different task sets concurrently
- **Persistent Results**: All outputs saved and retrievable anytime
- **Status Monitoring**: Real-time progress tracking

## Input Format

JSON structure required:
```json
{
    "prompts": [
        "Simple string prompt",
        {
            "id": "optional-uuid",
            "prompt": "Object-based prompt with optional ID"
        }
    ]
}
```

## Core Functions

### Session Management
- `generate_session_id()`: Creates unique session identifiers
- `create_session_dir()`: Sets up persistent session storage
- `update_session_status()`: Real-time status updates
- `get_session_status()`: Retrieves current session state
- `list_all_sessions()`: Shows all sessions with status
- `show_overview()`: Global statistics across all sessions

### Execution Engine
- `run_claude_parallel_async()`: Async execution with result persistence
- `run_claude_parallel()`: Synchronous execution (legacy mode)
- `wait_for_completion_async()`: Non-blocking completion handling
- `read_input()`: Parses JSON from file or STDIN, validates structure
- `generate_uuid()`: Creates unique identifiers for transaction tracking
- `validate_claude_command()`: Ensures Claude CLI is available

### Git Integration
- `get_current_branch()`: Retrieves current git branch for worktree naming
- `create_worktree_branch()`: Creates isolated git worktree with branch naming pattern
- `cleanup_worktree()`: Removes worktree directory while preserving branch

## Git Worktree Workflow

When using the `--worktree` flag, the runner creates isolated development environments for each task:

### Branch Naming Pattern
- Format: `{original_branch}-task-{uuid}`
- Examples:
  - From `main`: `main-task-a1b2c3d4-e5f6-7890-abcd-ef1234567890`
  - From `feature-auth`: `feature-auth-task-a1b2c3d4-e5f6-7890-abcd-ef1234567890`

### Workflow Steps
1. **Creation**: Each task gets a separate worktree directory and branch
2. **Execution**: Claude works in isolation with full git history
3. **Completion**: Worktree is cleaned up, but branch remains for merging
4. **Integration**: Main AI can merge successful branches back

### Benefits
- **Isolation**: No conflicts between parallel tasks
- **Traceability**: Each branch is tied to a specific task UUID
- **Safety**: Main branch remains untouched during execution
- **Flexibility**: Failed tasks can be easily abandoned or retried
- **AI Integration**: Provides clear merge instructions for automated workflow orchestration

## Security Considerations

The script uses `--dangerously-skip-permissions` flag when executing Claude instances. This bypasses interactive permission prompts but requires careful consideration of the prompts being executed.

## Exit Codes

- 0: All Claude instances completed successfully
- 1: One or more Claude instances failed
- 2: Input/validation error or Claude CLI not found

## Requirements

- Claude Code CLI must be installed and in PATH
- Perl with JSON module
- Unix-like system with fork() support
- Git (required for --worktree mode)