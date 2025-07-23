# Claude Parallel Runner

A Perl-based tool for executing multiple Claude Code instances in parallel with **asynchronous session management**. Designed to solve Claude Code's 2-minute timeout limitation by running tasks in the background with persistent result storage.

## 🚀 Key Features

- **Async by Default**: All executions run in background, returning session IDs immediately
- **No Timeout Issues**: Tasks can run for hours without Claude Code timeouts
- **Parallel Execution**: Multiple Claude instances run simultaneously within each session
- **Session Management**: Track multiple sessions with persistent storage
- **Git Worktree Integration**: Isolated development environments for each task
- **Real-time Status**: Monitor progress and view results anytime
- **Flexible Input**: JSON from files or STDIN

## 📋 Requirements

- **Claude Code CLI** must be installed and available in PATH
- **Perl** with JSON module
- **Unix-like system** with fork() support
- **Git** (required for --worktree mode)

## 🏁 Quick Start

### 1. Basic Usage

```bash
# Start async session (returns immediately)
./claude-parallel-runner.pl prompts.json

# From STDIN
echo '{"prompts":["Create a web app","Write tests"]}' | ./claude-parallel-runner.pl
```

### 2. Monitor Sessions

```bash
# Check specific session status
./claude-parallel-runner.pl --status SESSION_ID

# View completed results
./claude-parallel-runner.pl --results SESSION_ID

# List all sessions
./claude-parallel-runner.pl --list

# Show overview statistics
./claude-parallel-runner.pl --overview
```

### 3. Input Format

Create a JSON file with your prompts:

```json
{
    "prompts": [
        "Create a calculator web app",
        "Write unit tests for the calculator",
        {
            "id": "custom-uuid",
            "prompt": "Add documentation"
        }
    ]
}
```

## 📚 Command Reference

### Execution Modes

| Command | Description |
|---------|-------------|
| `./claude-parallel-runner.pl file.json` | **Default**: Start async session |
| `./claude-parallel-runner.pl --sync file.json` | Synchronous execution (original behavior) |

### Session Management

| Command | Description |
|---------|-------------|
| `--status SESSION_ID` | Show detailed status of specific session |
| `--results SESSION_ID` | View all task results from session |
| `--list` | List all sessions with status and progress |
| `--overview` | Show statistics across all sessions |

### Advanced Options

| Command | Description |
|---------|-------------|
| `--max-parallel=N` | Limit concurrent Claude instances (default: unlimited) |
| `--worktree` | Use git worktree isolation for each task |
| `--verbose` | Show detailed execution information |
| `--help` | Show detailed help documentation |

## 🔄 Session Workflow

### Typical Usage Pattern

1. **Start Session**
   ```bash
   ./claude-parallel-runner.pl tasks.json
   # 🚀 Started session: abc123...
   ```

2. **Monitor Progress**
   ```bash
   ./claude-parallel-runner.pl --status abc123
   # Session: abc123 [running]
   # Tasks: 2/5 completed
   ```

3. **View Results**
   ```bash
   ./claude-parallel-runner.pl --results abc123
   # Shows all task outputs
   ```

4. **Manage Sessions**
   ```bash
   ./claude-parallel-runner.pl --list
   # Shows all sessions with status
   ```

## 🌿 Git Worktree Integration

The `--worktree` flag creates isolated development environments:

```bash
./claude-parallel-runner.pl --worktree coding-tasks.json
```

**Benefits:**
- **Isolation**: Each task works in separate git branch
- **No Conflicts**: Parallel tasks don't interfere
- **Traceability**: Each branch tied to specific task UUID
- **Easy Merging**: Successful branches ready for integration

**Branch Naming Pattern:**
- Format: `{original_branch}-task-{uuid}`
- Example: `main-task-a1b2c3d4-e5f6-7890-abcd-ef1234567890`

## 📊 Session Storage

Sessions are stored in `./results/session-UUID/`:

```
./results/
├── session-abc123.../
│   ├── status.json          # Real-time session status
│   ├── task-uuid1.txt       # Task 1 output
│   ├── task-uuid2.txt       # Task 2 output
│   └── ...
└── session-def456.../
    └── ...
```

## 🛡️ Error Handling

- **Session Tracking**: Failed tasks clearly marked in status
- **Partial Success**: View results of completed tasks even if others fail
- **Error Recovery**: Restart failed sessions with new session ID
- **Safe Cleanup**: Background processes properly managed

## 🔧 Advanced Examples

### Complex Workflow with Worktree

```bash
# Start isolated coding session
./claude-parallel-runner.pl --worktree --max-parallel=3 --verbose complex-tasks.json

# Monitor progress
watch ./claude-parallel-runner.pl --overview

# Check specific task
./claude-parallel-runner.pl --status SESSION_ID

# View results when complete
./claude-parallel-runner.pl --results SESSION_ID
```

### Multiple Sessions Management

```bash
# Start multiple different projects
./claude-parallel-runner.pl frontend-tasks.json    # Session 1
./claude-parallel-runner.pl backend-tasks.json     # Session 2
./claude-parallel-runner.pl testing-tasks.json     # Session 3

# Monitor all sessions
./claude-parallel-runner.pl --list

# Global statistics
./claude-parallel-runner.pl --overview
```

## 🏗️ Architecture

- **Async Design**: Parent process returns immediately, child runs tasks
- **Process Forking**: Each task runs in separate Claude Code process
- **Persistent Storage**: JSON status files + text result files
- **Real-time Updates**: Status updated as tasks complete
- **Resource Management**: Optional parallelism limits and cleanup

## Exit Codes

- **0**: Session started successfully (async) or all tasks completed (sync)
- **1**: One or more tasks failed (sync mode only)
- **2**: Input/validation error or Claude CLI not found

## Example Session Flow

### Starting a Session
```bash
$ ./claude-parallel-runner.pl tasks.json
🚀 Started session: abc123def-456g-789h-ijkl-mnop12345678
📂 Results directory: results/session-abc123def-456g-789h-ijkl-mnop12345678

Use these commands to monitor progress:
  ./claude-parallel-runner.pl --status abc123def-456g-789h-ijkl-mnop12345678
  ./claude-parallel-runner.pl --results abc123def-456g-789h-ijkl-mnop12345678
```

### Checking Status
```bash
$ ./claude-parallel-runner.pl --status abc123def
Session: abc123def-456g-789h-ijkl-mnop12345678
Status: running
Started: Wed Jul 23 15:30:45 2025
Tasks: 2/3

Tasks:
  ✅ Task 1 (ID: uuid1): completed
  ⏳ Task 2 (ID: uuid2): running
  ⏳ Task 3 (ID: uuid3): pending
```

### Viewing Results
```bash
$ ./claude-parallel-runner.pl --results abc123def
Session: abc123def-456g-789h-ijkl-mnop12345678
==================================================

Task 1 (ID: uuid1):
------------------------------
[Complete task output here...]

Task 2 (ID: uuid2):
------------------------------
[Task still running...]
```

## 🆘 Troubleshooting

### Common Issues

1. **"Claude Code CLI not found"**
   ```bash
   # Ensure Claude Code is installed and in PATH
   which claude
   ```

2. **Permission Issues**
   ```bash
   # Make script executable
   chmod +x claude-parallel-runner.pl
   ```

3. **Session Not Found**
   ```bash
   # Check available sessions
   ./claude-parallel-runner.pl --list
   ```

### Debug Mode

```bash
# Check Perl syntax
perl -c claude-parallel-runner.pl

# Verbose execution
./claude-parallel-runner.pl --verbose --sync tasks.json
```

## ⚠️ Security Notes

This script uses the `--dangerously-skip-permissions` flag, which bypasses Claude Code's permission prompts. Use with caution and ensure you trust all prompts being executed.

## 📄 License

This tool is designed for use with Claude Code for parallel task execution and session management.

## 🤝 Contributing

When working with this codebase, refer to `CLAUDE.md` for detailed architectural information and development guidelines.