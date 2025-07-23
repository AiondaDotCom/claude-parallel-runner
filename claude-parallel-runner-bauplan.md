# Bauplan: Claude Code Parallel Runner mit Async Session Management

## Überblick

Dieses Programm führt mehrere Claude Code Instanzen parallel aus mit **asynchronem Session Management**. Es löst das Claude Code 2-Minuten-Timeout Problem durch Background-Ausführung und persistente Ergebnis-Speicherung.

## 🚀 Neue Architektur (Async-First)

### Kernproblem gelöst
- **Claude Code Timeout**: 2-Minuten-Limit eliminiert
- **Long-Running Tasks**: Tasks können stundenlang laufen
- **Session Management**: Vollständige Übersicht über alle Ausführungen

## Eingabe-Formate (Unverändert)

### 1. STDIN (JSON)
```json
{
  "prompts": [
    "Erstelle eine Taschenrechner Web-App",
    "Schreibe Unit Tests für die App", 
    "Refaktoriere den Code für bessere Lesbarkeit"
  ]
}
```

### 2. JSON-Datei Parameter
```bash
# Async Mode (Standard) - startet Session und terminiert sofort
./claude-parallel-runner.pl prompts.json

# Sync Mode (alte Funktionalität)
./claude-parallel-runner.pl --sync prompts.json
```

## 🔄 Session Management Kommandos

### Session Überwachung
```bash
# Specific Session Status
./claude-parallel-runner.pl --status SESSION_ID

# Session Results anzeigen
./claude-parallel-runner.pl --results SESSION_ID

# Alle Sessions auflisten
./claude-parallel-runner.pl --list

# Globale Statistiken
./claude-parallel-runner.pl --overview
```

## 🏗️ Neue Architektur (Async-First)

### Kern-Komponenten

1. **Input Parser**: Liest JSON von STDIN oder Datei (unverändert)
2. **Session Manager**: Erstellt und verwaltet Session-IDs und Verzeichnisse
3. **Background Forker**: Fork in Background-Process für lange Tasks
4. **Async Process Manager**: Startet parallele Claude Instanzen mit Output-Redirect  
5. **Status Tracker**: Real-time Status-Updates in JSON-Dateien
6. **Result Persistence**: Speichert alle Outputs in Session-Verzeichnisse
7. **Session Query Engine**: Abfrage-System für Status und Results

### Session Storage System
```
./results/
├── session-uuid1/
│   ├── status.json          # Real-time Session Status
│   ├── task-uuid1.txt       # Task 1 Output
│   ├── task-uuid2.txt       # Task 2 Output
│   └── ...
└── session-uuid2/
    └── ...
```

### Technische Details

#### Async Workflow
1. **Session Start**: Parent Process erstellt Session-ID und Verzeichnis
2. **Background Fork**: Child-Process übernimmt Task-Ausführung  
3. **Parent Termination**: Parent terminiert sofort mit Session-ID
4. **Task Execution**: Child führt alle Tasks parallel aus
5. **Status Updates**: Real-time Updates während Ausführung
6. **Result Storage**: Outputs werden in Task-Dateien gespeichert

#### Claude Code Aufruf (Unverändert)
```bash
# Aber Output wird in Dateien umgeleitet
claude -p "PROMPT_TEXT" --dangerously-skip-permissions > task-uuid.txt 2>&1
```

#### Session Status Tracking
```json
{
  "session_id": "abc123...",
  "overall_status": "running|completed|error",
  "start_time": 1234567890,
  "end_time": 1234567950,
  "total": 3,
  "completed": 1,
  "successful": 1,
  "tasks": [
    {
      "task_num": 1,
      "transaction_id": "uuid1",
      "status": "completed|running|pending",
      "success": 1,
      "duration": 45
    }
  ]
}
```

## 💡 Implementation (Gewählte Lösung: Perl)

### Warum Perl?
- **JSON Support**: Native JSON-Verarbeitung
- **Process Management**: Robuste Fork/Wait APIs
- **File Handling**: Einfache Datei-Operationen für Session Storage
- **String Processing**: Excellent für Status-Updates und Logging

### Async Implementation Workflow

```perl
# Haupt-Workflow (Async):
# 1. JSON Input parsen
# 2. Session-ID generieren + Verzeichnis erstellen
# 3. Background fork() für Child-Process
# 4. Parent terminiert sofort mit Session-ID
# 5. Child führt alle Tasks parallel aus
# 6. Real-time Status-Updates in JSON-Dateien
# 7. Task-Outputs in separate Dateien

# Session Management:
# 8. Status-Abfragen über --status SESSION_ID
# 9. Result-Abfragen über --results SESSION_ID
# 10. Session-Listing über --list / --overview
```

## 🔧 Neue Kern-Funktionen (Async Implementation)

### 1. Session Management
```perl
sub generate_session_id { return generate_uuid(); }

sub create_session_dir {
    my ($session_id) = @_;
    my $results_dir = "./results/session-$session_id";
    mkdir $results_dir or die "Cannot create session directory: $!";
    return $results_dir;
}

sub update_session_status {
    my ($session_dir, $status_data) = @_;
    my $status_file = "$session_dir/status.json";
    write_json_file($status_file, $status_data);
}
```

### 2. Async Execution Engine
```perl
sub main_async_mode {
    my ($prompts) = @_;
    
    # Session Setup
    my $session_id = generate_session_id();
    my $session_dir = create_session_dir($session_id);
    
    # Background Fork
    my $bg_pid = fork();
    if ($bg_pid == 0) {
        # Child: Führe Tasks aus
        run_claude_parallel_async($prompts, $session_dir);
        exit;
    } else {
        # Parent: Terminiere sofort mit Session-Info
        print "🚀 Started session: $session_id\n";
        print "📂 Results directory: $session_dir\n";
        exit 0;
    }
}
```

### 3. Background Task Execution
```perl
sub run_claude_parallel_async {
    my ($prompts, $session_dir) = @_;
    
    for my $prompt (@$prompts) {
        my $task_pid = fork();
        if ($task_pid == 0) {
            # Output-Redirect zu Task-Datei
            my $result_file = "$session_dir/task-$transaction_id.txt";
            open STDOUT, '>', $result_file;
            
            exec('claude', '-p', $prompt, '--dangerously-skip-permissions');
        }
        # Parent sammelt PIDs und überwacht Status
    }
}
```

### 4. Session Query Functions
```perl
sub get_session_status {
    my ($session_id) = @_;
    my $status_file = "./results/session-$session_id/status.json";
    return read_json_file($status_file);
}

sub show_session_status {
    my ($session_id) = @_;
    my $status = get_session_status($session_id);
    
    print "Session: $session_id\n";
    print "Status: $status->{overall_status}\n";
    print "Tasks: $status->{completed}/$status->{total}\n";
    
    for my $task (@{$status->{tasks}}) {
        my $icon = $task->{status} eq 'completed' ? 
            ($task->{success} ? '✅' : '❌') : '⏳';
        print "  $icon Task $task->{task_num}: $task->{status}\n";
    }
}

sub list_all_sessions {
    opendir(my $dh, './results') or return;
    my @sessions = grep { /^session-/ } readdir($dh);
    
    for my $session_dir (@sessions) {
        my $session_id = $session_dir =~ s/^session-//r;
        # Zeige Session-Übersicht
        show_session_summary($session_id);
    }
}
```

### 5. Main Program Flow (Neue Logik)
```perl
sub main {
    # Command Line Optionen parsen
    if ($options{status}) {
        show_session_status($options{status});
        return;
    }
    
    if ($options{list}) {
        list_all_sessions();
        return;
    }
    
    # Input parsen
    my $prompts = read_input();
    
    if ($options{sync}) {
        # Alte synchrone Funktionalität
        run_synchronous_mode($prompts);
    } else {
        # Neue async Funktionalität (Standard)
        run_async_mode($prompts);
    }
}
```

## 🚀 Typischer Workflow (Neue Async-Architektur)

### 1. Session starten
```bash
$ ./claude-parallel-runner.pl my-tasks.json
🚀 Started session: abc123def-456g-789h-ijkl-mnop12345678
📂 Results directory: results/session-abc123def-456g-789h-ijkl-mnop12345678

Use these commands to monitor progress:
  ./claude-parallel-runner.pl --status abc123def-456g-789h-ijkl-mnop12345678
  ./claude-parallel-runner.pl --results abc123def-456g-789h-ijkl-mnop12345678
```

### 2. Status überwachen
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

### 3. Ergebnisse anzeigen
```bash
$ ./claude-parallel-runner.pl --results abc123def
Session: abc123def-456g-789h-ijkl-mnop12345678
==================================================

Task 1 (ID: uuid1):
------------------------------
[Kompletter Task-Output hier...]

Task 2 (ID: uuid2):
------------------------------
[Task läuft noch...]
```

### 4. Alle Sessions verwalten
```bash
$ ./claude-parallel-runner.pl --list
All Sessions:
============================================================
✅ abc123def [completed]
   Started: Wed Jul 23 15:30:45 2025
   Progress: 3/3 tasks (3 successful) - Duration: 120s

⏳ def456ghi [running]
   Started: Wed Jul 23 16:15:20 2025
   Progress: 1/2 tasks

$ ./claude-parallel-runner.pl --overview
📊 Session Overview
========================================
Total Sessions: 2
  ⏳ Running: 1
  ✅ Completed: 1
  ❌ Errors: 0

Total Tasks: 5
Successful Tasks: 4
Success Rate: 80.0%
```

## ✨ Erweiterte Features (Implementiert)

### 1. Session Persistence
- **JSON Status Files**: Real-time Session-Status in `status.json`
- **Task Output Files**: Jeder Task-Output separat in `task-uuid.txt`
- **Session Recovery**: Sessions überleben System-Restarts

### 2. Multi-Session Management
- **Session Listing**: `--list` zeigt alle Sessions mit Status
- **Global Overview**: `--overview` für Statistiken über alle Sessions
- **Session Isolation**: Jede Session läuft in eigenem Verzeichnis

### 3. Git Worktree Integration (Bestehend)
- **Task Isolation**: Jeder Task in separater Git-Branch
- **Merge Instructions**: Automatische Merge-Anweisungen nach Completion
- **Branch Cleanup**: Worktrees werden automatisch aufgeräumt

### 4. Resource Management (Bestehend)
- **Max Parallel**: `--max-parallel=N` begrenzt parallele Tasks pro Session
- **Graceful Cleanup**: Background-Process-Management
- **Safe Termination**: Proper Exit-Code Handling

## 📋 Verwendung (Aktualisiert)

### Grundlegende Verwendung (Async-First)
```bash
# Async Session starten (Standard)
./claude-parallel-runner.pl prompts.json

# Via STDIN  
echo '{"prompts":["task1","task2"]}' | ./claude-parallel-runner.pl

# Synchron (alte Funktionalität)
./claude-parallel-runner.pl --sync prompts.json
```

### Session Management
```bash
# Status einer Session abfragen
./claude-parallel-runner.pl --status abc123def-456g-789h

# Ergebnisse einer Session anzeigen
./claude-parallel-runner.pl --results abc123def-456g-789h

# Alle Sessions auflisten
./claude-parallel-runner.pl --list

# Globale Übersicht
./claude-parallel-runner.pl --overview
```

### Erweiterte Optionen (Bestehend)
```bash
# Mit maximaler Parallelität pro Session
./claude-parallel-runner.pl --max-parallel=3 prompts.json

# Mit Git Worktree Isolation
./claude-parallel-runner.pl --worktree prompts.json

# Mit Verbose Output
./claude-parallel-runner.pl --verbose prompts.json

# Kombiniert
./claude-parallel-runner.pl --worktree --max-parallel=2 --verbose prompts.json
```

## 🛡️ Fehlerbehandlung (Erweitert)

### Session-Level Fehler
1. **Session Creation Fehler**: Verzeichnis-Erstellung fehlgeschlagen
2. **Background Fork Fehler**: System-Resource Limits erreicht
3. **Session Recovery**: Defekte Sessions erkennbar über `--list`

### Task-Level Fehler (Bestehend)
1. **JSON Parse Fehler**: Validate JSON format before processing
2. **Claude Command Fehler**: Check if claude command exists
3. **Permission Fehler**: Verify --dangerously-skip-permissions availability  
4. **Fork Fehler**: Handle system resource limitations

### Neue Fehlerbehandlung
- **Partial Success**: Erfolgreiche Tasks bleiben verfügbar auch wenn andere fehlschlagen
- **Session Isolation**: Fehler in einer Session beeinflussen andere nicht
- **Status Tracking**: Fehler werden in Session-Status dokumentiert

## 🧪 Testing Strategy (Aktualisiert)

### Async-Spezifische Tests
1. **Session Management Tests**: Session-Erstellung, Status-Updates, Cleanup
2. **Background Process Tests**: Fork-Verhalten, Process-Isolation
3. **Persistence Tests**: Session-Recovery nach System-Restart
4. **Multi-Session Tests**: Mehrere parallele Sessions

### Bestehende Tests
1. **Unit Tests**: Einzelne Funktionen
2. **Integration Tests**: End-to-end mit echten Claude Aufrufen
3. **Load Tests**: Viele parallele Instanzen
4. **Error Tests**: Verschiedene Fehlerbedingungen

## 🔒 Security Considerations (Erweitert)

### Session Security
- **Session Isolation**: Jede Session in separatem Verzeichnis
- **Access Control**: Session-IDs als Access-Tokens
- **Result Privacy**: Task-Outputs nur über Session-ID abrufbar

### Bestehende Sicherheit
- `--dangerously-skip-permissions` birgt Sicherheitsrisiken
- Input Sanitization für Prompts
- Process Isolation zwischen Claude Instanzen
- Log-Dateien können sensitive Daten enthalten

## 🎯 Architektur-Vorteile der Async-Lösung

1. **Timeout-Problem gelöst**: Keine 2-Minuten-Begrenzung mehr
2. **Skalierbarkeit**: Unbegrenzt viele Sessions parallel
3. **Persistence**: Ergebnisse überleben System-Restarts
4. **User Experience**: Sofortiges Feedback mit Session-ID
5. **Monitoring**: Real-time Status aller laufenden Tasks
6. **Resource Efficiency**: Background-Processes benötigen weniger Ressourcen