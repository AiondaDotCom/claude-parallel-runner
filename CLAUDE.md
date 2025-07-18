# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Perl-based tool for executing multiple Claude Code instances in parallel. The main script (`claude-parallel-runner.pl`) reads JSON-formatted prompts and executes them concurrently using process forking.

## Key Architecture

- **Main Script**: `claude-parallel-runner.pl` - Core Perl script that handles parallel execution
- **Process Management**: Uses Unix `fork()` for creating child processes, each running a separate Claude instance
- **Input/Output**: Accepts JSON input from files or STDIN with a `prompts` array structure
- **Transaction Tracking**: Each prompt gets a unique UUID for tracking and identification
- **Resource Control**: Optional `--max-parallel` flag to limit concurrent processes
- **Git Worktree Integration**: Optional `--worktree` flag creates isolated git branches for each task

## Common Commands

### Running the Tool
```bash
# Basic usage with JSON file
./claude-parallel-runner.pl example-prompts.json

# From STDIN
echo '{"prompts":["task1","task2"]}' | ./claude-parallel-runner.pl

# With limited parallelism
./claude-parallel-runner.pl --max-parallel=3 example-prompts.json

# Verbose output
./claude-parallel-runner.pl --verbose example-prompts.json

# With git worktree isolation
./claude-parallel-runner.pl --worktree example-prompts.json

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

- `read_input()`: Parses JSON from file or STDIN, validates structure
- `run_claude_parallel()`: Main execution engine with fork-based parallelism
- `generate_uuid()`: Creates unique identifiers for transaction tracking
- `validate_claude_command()`: Ensures Claude CLI is available
- `wait_for_completion()`: Monitors child processes and collects results
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