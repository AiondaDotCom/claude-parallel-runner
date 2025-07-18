# Claude Parallel Runner

A Perl script that executes multiple Claude Code instances in parallel, allowing you to process multiple prompts simultaneously and efficiently.

## Features

- **Parallel Execution**: Run multiple Claude Code instances simultaneously
- **Flexible Input**: Accept prompts from JSON files or STDIN
- **Process Management**: Monitor all processes and wait for completion
- **Error Handling**: Comprehensive validation and error reporting
- **Progress Monitoring**: Real-time status updates and execution summary
- **Resource Control**: Optional limit on maximum parallel processes
- **Git Worktree Integration**: Isolated development environments for each task

## Installation

1. Ensure Claude Code CLI is installed and available in your PATH
2. Make sure Perl with JSON module is available
3. The script is already executable and linked to `/Users/saf/bin/claude-parallel-runner`

## Usage

### Basic Usage

```bash
# Run from JSON file
claude-parallel-runner example-prompts.json

# Run from STDIN  
echo '{"prompts":["What is 5+5?","What is the capital of France?"]}' | claude-parallel-runner

# With limited parallelism
claude-parallel-runner --max-parallel=3 example-prompts.json

# Verbose output
claude-parallel-runner --verbose example-prompts.json

# With git worktree isolation
claude-parallel-runner --worktree example-prompts.json

# Combined options
claude-parallel-runner --worktree --max-parallel=2 --verbose example-prompts.json
```

### Input Format

The input must be a JSON object with a "prompts" array:

```json
{
    "prompts": [
        "Analyze the config.js file and suggest improvements",
        "Write unit tests for the auth.js file", 
        "Refactor utils.js for better readability"
    ]
}
```

### Command Line Options

- `-h, --help` - Show help message
- `-v, --version` - Show version information  
- `--max-parallel=N` - Limit parallel processes (default: unlimited)
- `--verbose` - Enable detailed output
- `--worktree` - Enable git worktree mode for isolated task execution

## How It Works

1. **Input Parsing**: Reads JSON from file or STDIN and validates format
2. **Process Forking**: Creates child processes using `fork()` for each prompt
3. **Git Worktree Setup** (optional): Creates isolated branches and directories
4. **Claude Execution**: Each child executes `claude -p "prompt" --dangerously-skip-permissions`
5. **Completion Monitoring**: Parent process monitors exit codes using `waitpid()`
6. **Result Aggregation**: Collects all results and provides summary

## Git Worktree Mode

When using the `--worktree` flag, the runner creates isolated development environments:

### Branch Naming Pattern
- Format: `{original_branch}-task-{uuid}`
- Examples:
  - From `main`: `main-task-a1b2c3d4-e5f6-7890-abcd-ef1234567890`
  - From `feature-auth`: `feature-auth-task-a1b2c3d4-e5f6-7890-abcd-ef1234567890`

### Workflow
1. **Creation**: Each task gets a separate worktree directory and branch
2. **Execution**: Claude works in isolation with full git history
3. **Completion**: Worktree is cleaned up, branch remains for merging
4. **Integration**: Branch names are returned for main AI to merge

### Benefits
- **Isolation**: No conflicts between parallel tasks
- **Traceability**: Each branch tied to specific task UUID
- **Safety**: Main branch untouched during execution
- **Team-friendly**: Multiple developers can work from different base branches
- **AI Integration**: Provides merge instructions for automated workflow orchestration

## Exit Codes

- **0**: All Claude instances completed successfully
- **1**: One or more Claude instances failed
- **2**: Input/validation error or Claude CLI not found

## Example Output

```
Starting 3 Claude instances...
Starting task 1 (ID: a1b2c3d4): Analyze the config.js file and suggest improvemen...
Created worktree branch: main-task-a1b2c3d4 at ../claude-worktrees/task-a1b2c3d4
Starting task 2 (ID: e5f6g7h8): Write unit tests for the auth.js file
Created worktree branch: main-task-e5f6g7h8 at ../claude-worktrees/task-e5f6g7h8
Starting task 3 (ID: i9j0k1l2): Refactor utils.js for better readability
Created worktree branch: main-task-i9j0k1l2 at ../claude-worktrees/task-i9j0k1l2
Task 1 (ID: a1b2c3d4) completed in 45s with exit code 0
Branch available for merge: main-task-a1b2c3d4
Task 2 (ID: e5f6g7h8) completed in 38s with exit code 0  
Branch available for merge: main-task-e5f6g7h8
Task 3 (ID: i9j0k1l2) completed in 52s with exit code 0
Branch available for merge: main-task-i9j0k1l2

==================================================
EXECUTION SUMMARY
==================================================
Total tasks: 3
Successful: 3
Failed: 0
Total time: 52s
Overall status: SUCCESS
==================================================

🤖 AI MERGE INSTRUCTIONS
==================================================
The following branches are ready for merging:

  • main-task-a1b2c3d4
  • main-task-e5f6g7h8
  • main-task-i9j0k1l2

To merge these branches, run:
  git merge main-task-a1b2c3d4
  git merge main-task-e5f6g7h8
  git merge main-task-i9j0k1l2

Or to merge all successful branches at once:
  git merge main-task-a1b2c3d4 main-task-e5f6g7h8 main-task-i9j0k1l2

After merging, you can clean up the branches with:
  git branch -d main-task-a1b2c3d4
  git branch -d main-task-e5f6g7h8
  git branch -d main-task-i9j0k1l2

==================================================

All Claude instances completed successfully!
```

## Requirements

- **Claude Code CLI**: Must be installed and available in PATH
- **Perl**: With JSON module support
- **Unix-like system**: With fork() support
- **Git**: Required for --worktree mode
- **Permissions**: Script uses `--dangerously-skip-permissions` flag

## Files

- `claude-parallel-runner.pl` - Main Perl script
- `example-prompts.json` - Example input file
- `claude-parallel-runner-bauplan.md` - German blueprint/design document

## Security Notes

⚠️ **Warning**: This script uses the `--dangerously-skip-permissions` flag, which bypasses Claude Code's permission prompts. Use with caution and ensure you trust all prompts being executed.

## Architecture

The script implements a robust parallel execution model:

- **Fork-based parallelism**: Each prompt runs in a separate process
- **Process pool management**: Optional limit on concurrent processes  
- **Signal handling**: Proper cleanup and exit code propagation
- **Real-time monitoring**: Progress updates and completion tracking

## Contributing

This tool was designed for efficient batch processing of Claude Code tasks. Feel free to extend or modify for your specific use cases.

## License

See LICENSE file for details.