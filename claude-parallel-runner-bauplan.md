# Bauplan: Claude Code Parallel Runner

## Überblick

Dieses Programm führt mehrere Claude Code Instanzen parallel aus und wartet bis alle Tasks abgeschlossen sind.

## Eingabe-Formate

### 1. STDIN (JSON)
```json
{
  "prompts": [
    "Analysiere die Datei config.js und finde Verbesserungen",
    "Schreibe Unit Tests für die auth.js Datei", 
    "Refaktoriere die utils.js für bessere Lesbarkeit"
  ]
}
```

### 2. JSON-Datei Parameter
```bash
./claude-runner.pl prompts.json
./claude-runner.sh prompts.json
```

## Architektur

### Kern-Komponenten

1. **Input Parser**: Liest JSON von STDIN oder Datei
2. **Process Manager**: Startet parallele Claude Instanzen
3. **Completion Monitor**: Überwacht Exit-Codes der Child-Prozesse
4. **Result Aggregator**: Sammelt Ergebnisse und Exit-Status

### Technische Details

#### Claude Code Aufruf
```bash
claude -p "PROMPT_TEXT" --dangerously-skip-permissions
```

#### Exit-Code Erkennung
- Exit Code 0: Erfolg
- Exit Code != 0: Fehler
- Standard Unix Process Management via `wait()` oder `waitpid()`

## Implementation Optionen

### Option A: Perl Implementation

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use JSON;
use POSIX ":sys_wait_h";

# Haupt-Workflow:
# 1. JSON Input parsen
# 2. Für jeden Prompt: fork() + exec() claude
# 3. Parent sammelt Child PIDs
# 4. waitpid() für alle Children
# 5. Exit wenn alle fertig
```

**Vorteile:**
- Eingebaute JSON Unterstützung
- Robuste Process Management APIs
- Gute String-Manipulation

**Nachteile:**
- Zusätzliche Dependencies (JSON module)

### Option B: Shell Script Implementation

```bash
#!/bin/bash
# Haupt-Workflow:
# 1. jq für JSON parsing
# 2. Background jobs mit &
# 3. wait für alle jobs
# 4. Exit status aggregation
```

**Vorteile:**
- Minimal Dependencies (nur jq)
- Native Process Management
- Einfach zu verstehen

**Nachteile:**
- Komplexere JSON Verarbeitung
- Weniger robuste Fehlerbehandlung

## Detaillierte Implementierung (Perl Variante)

### 1. Eingabe-Verarbeitung
```perl
sub read_input {
    my $input;
    if (@ARGV && -f $ARGV[0]) {
        # JSON-Datei lesen
        open my $fh, '<', $ARGV[0] or die "Cannot open $ARGV[0]: $!";
        local $/;
        $input = <$fh>;
        close $fh;
    } else {
        # STDIN lesen
        local $/;
        $input = <STDIN>;
    }
    
    my $data = decode_json($input);
    return $data->{prompts} // [];
}
```

### 2. Parallele Ausführung
```perl
sub run_claude_parallel {
    my ($prompts) = @_;
    my @pids;
    
    for my $prompt (@$prompts) {
        my $pid = fork();
        if ($pid == 0) {
            # Child Prozess
            exec('claude', '-p', $prompt, '--dangerously-skip-permissions');
            die "exec failed: $!";
        } elsif ($pid > 0) {
            # Parent Prozess
            push @pids, $pid;
        } else {
            die "fork failed: $!";
        }
    }
    
    return @pids;
}
```

### 3. Completion Monitoring
```perl
sub wait_for_completion {
    my (@pids) = @_;
    my %results;
    my $all_success = 1;
    
    for my $pid (@pids) {
        my $status = waitpid($pid, 0);
        my $exit_code = $? >> 8;
        
        $results{$pid} = {
            exit_code => $exit_code,
            success => $exit_code == 0
        };
        
        $all_success = 0 if $exit_code != 0;
        
        print "Process $pid finished with exit code $exit_code\n";
    }
    
    return ($all_success, \%results);
}
```

### 4. Main Program Flow
```perl
sub main {
    my $prompts = read_input();
    
    if (!@$prompts) {
        die "No prompts provided\n";
    }
    
    print "Starting " . scalar(@$prompts) . " Claude instances...\n";
    
    my @pids = run_claude_parallel($prompts);
    my ($success, $results) = wait_for_completion(@pids);
    
    if ($success) {
        print "All Claude instances completed successfully\n";
        exit 0;
    } else {
        print "Some Claude instances failed\n";
        exit 1;
    }
}
```

## Detaillierte Implementierung (Shell Variante)

### 1. JSON Parsing
```bash
parse_prompts() {
    if [[ -f "$1" ]]; then
        jq -r '.prompts[]' "$1"
    else
        jq -r '.prompts[]'
    fi
}
```

### 2. Parallele Ausführung
```bash
run_claude_parallel() {
    local pids=()
    
    while IFS= read -r prompt; do
        claude -p "$prompt" --dangerously-skip-permissions &
        pids+=($!)
    done < <(parse_prompts "$@")
    
    echo "${pids[@]}"
}
```

### 3. Wait für Completion
```bash
wait_for_completion() {
    local pids=("$@")
    local all_success=true
    
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            echo "Process $pid completed successfully"
        else
            echo "Process $pid failed with exit code $?"
            all_success=false
        fi
    done
    
    if $all_success; then
        echo "All Claude instances completed successfully"
        exit 0
    else
        echo "Some Claude instances failed"
        exit 1
    fi
}
```

## Erweiterte Features

### 1. Logging
- Jede Claude Instanz loggt in separate Datei
- Timestamp für Start/Ende jeder Instanz
- Aggregierte Log-Datei für Gesamtstatus

### 2. Retry-Mechanismus
- Automatischer Retry bei Fehlern
- Konfigurierbare Retry-Anzahl
- Exponential Backoff

### 3. Progress Monitoring
- Real-time Status Updates
- Progress Bar für große Prompt-Listen
- Estimated Time Remaining

### 4. Resource Management
- Maximale Anzahl paralleler Prozesse
- Memory/CPU Monitoring
- Graceful Shutdown bei SIGTERM

## Verwendung

### Grundlegende Verwendung
```bash
# Via STDIN
echo '{"prompts":["task1","task2"]}' | ./claude-runner.pl

# Via Datei
./claude-runner.pl prompts.json

# Shell Version
./claude-runner.sh prompts.json
```

### Erweiterte Optionen
```bash
# Mit maximaler Parallelität
./claude-runner.pl --max-parallel=5 prompts.json

# Mit Logging
./claude-runner.pl --log-dir=/tmp/claude-logs prompts.json

# Mit Retry
./claude-runner.pl --retry=3 prompts.json
```

## Fehlerbehandlung

1. **JSON Parse Fehler**: Validate JSON format before processing
2. **Claude Command Fehler**: Check if claude command exists
3. **Permission Fehler**: Verify --dangerously-skip-permissions availability  
4. **Fork Fehler**: Handle system resource limitations
5. **Timeout Handling**: Optional timeout für lange laufende Tasks

## Testing Strategy

1. **Unit Tests**: Testen der einzelnen Funktionen
2. **Integration Tests**: End-to-end mit echten Claude Aufrufen
3. **Load Tests**: Viele parallele Instanzen
4. **Error Tests**: Verschiedene Fehlerbedingungen

## Security Considerations

- `--dangerously-skip-permissions` birgt Sicherheitsrisiken
- Input Sanitization für Prompts
- Process Isolation zwischen Claude Instanzen
- Log-Dateien können sensitive Daten enthalten