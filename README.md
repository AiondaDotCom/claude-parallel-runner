# Claude Parallel Runner

A Perl script that executes multiple Claude Code instances in parallel, allowing you to process multiple prompts simultaneously and efficiently.

## Features

- **Parallel Execution**: Run multiple Claude Code instances simultaneously
- **Flexible Input**: Accept prompts from JSON files or STDIN
- **Process Management**: Monitor all processes and wait for completion
- **Error Handling**: Comprehensive validation and error reporting
- **Progress Monitoring**: Real-time status updates and execution summary
- **Resource Control**: Optional limit on maximum parallel processes

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
echo '{"prompts":["task1","task2"]}' | claude-parallel-runner

# With limited parallelism
claude-parallel-runner --max-parallel=3 example-prompts.json

# Verbose output
claude-parallel-runner --verbose example-prompts.json
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

## How It Works

1. **Input Parsing**: Reads JSON from file or STDIN and validates format
2. **Process Forking**: Creates child processes using `fork()` for each prompt
3. **Claude Execution**: Each child executes `claude -p "prompt" --dangerously-skip-permissions`
4. **Completion Monitoring**: Parent process monitors exit codes using `waitpid()`
5. **Result Aggregation**: Collects all results and provides summary

## Exit Codes

- **0**: All Claude instances completed successfully
- **1**: One or more Claude instances failed
- **2**: Input/validation error or Claude CLI not found

## Example Output

```
Starting 3 Claude instances...
Starting task 1: Analyze the config.js file and suggest improvemen...
Starting task 2: Write unit tests for the auth.js file
Starting task 3: Refactor utils.js for better readability
Task 1 completed in 45s with exit code 0
Task 2 completed in 38s with exit code 0  
Task 3 completed in 52s with exit code 0

==================================================
EXECUTION SUMMARY
==================================================
Total tasks: 3
Successful: 3
Failed: 0
Total time: 52s
Overall status: SUCCESS
==================================================

All Claude instances completed successfully!
```

## Requirements

- **Claude Code CLI**: Must be installed and available in PATH
- **Perl**: With JSON module support
- **Unix-like system**: With fork() support
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