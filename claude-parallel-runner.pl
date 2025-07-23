#!/usr/bin/env perl

use strict;
use warnings;
use JSON;
use POSIX ":sys_wait_h";
use Getopt::Long;
use Pod::Usage;
use File::Spec;
use Cwd;

our $VERSION = '1.0.0';

sub generate_uuid {
    my @chars = ('0'..'9', 'a'..'f');
    my $uuid = '';
    for my $i (0..31) {
        $uuid .= $chars[rand @chars];
        $uuid .= '-' if $i == 7 || $i == 11 || $i == 15 || $i == 19;
    }
    return $uuid;
}

sub read_input {
    my ($file_path) = @_;
    my $input;
    
    if ($file_path && -f $file_path) {
        open my $fh, '<', $file_path or die "Cannot open $file_path: $!\n";
        local $/;
        $input = <$fh>;
        close $fh;
    } else {
        if (-t STDIN) {
            die "No input provided. Use a JSON file as argument or pipe JSON to STDIN.\n";
        }
        local $/;
        $input = <STDIN>;
    }
    
    unless ($input && $input =~ /\S/) {
        die "Empty input provided\n";
    }
    
    my $data;
    eval {
        $data = decode_json($input);
    };
    if ($@) {
        die "Invalid JSON format: $@\n";
    }
    
    unless (ref $data eq 'HASH' && exists $data->{prompts}) {
        die "JSON must contain a 'prompts' array\n";
    }
    
    unless (ref $data->{prompts} eq 'ARRAY') {
        die "The 'prompts' field must be an array\n";
    }
    
    # Convert prompts to standardized format with IDs
    my @processed_prompts;
    
    for my $prompt (@{$data->{prompts}}) {
        if (ref $prompt eq 'HASH') {
            # Prompt is already an object
            unless (exists $prompt->{prompt}) {
                die "Prompt objects must contain a 'prompt' field\n";
            }
            $prompt->{id} ||= generate_uuid();
            push @processed_prompts, $prompt;
        } elsif (!ref $prompt) {
            # Prompt is a simple string
            push @processed_prompts, {
                id => generate_uuid(),
                prompt => $prompt
            };
        } else {
            die "Prompts must be strings or objects with 'prompt' field\n";
        }
    }
    
    return \@processed_prompts;
}

sub validate_claude_command {
    my $claude_path = `which claude 2>/dev/null`;
    chomp $claude_path;
    
    unless ($claude_path && -x $claude_path) {
        die "Claude Code CLI not found in PATH. Please install Claude Code first.\n";
    }
    
    return $claude_path;
}

sub get_current_branch {
    my $branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`;
    chomp $branch;
    
    unless ($branch && $branch ne 'HEAD') {
        die "Not in a Git repository or detached HEAD state.\n";
    }
    
    return $branch;
}

sub create_worktree_branch {
    my ($base_branch, $task_id, $worktree_base) = @_;
    
    my $branch_name = "${base_branch}-task-${task_id}";
    my $worktree_path = File::Spec->catdir($worktree_base, "task-${task_id}");
    
    # Create worktree with new branch
    my $cmd = "git worktree add \"$worktree_path\" -b \"$branch_name\" 2>/dev/null";
    my $result = system($cmd);
    
    if ($result != 0) {
        die "Failed to create worktree for task $task_id: $!\n";
    }
    
    return ($branch_name, $worktree_path);
}

sub cleanup_worktree {
    my ($worktree_path, $branch_name) = @_;
    
    # Remove worktree
    system("git worktree remove \"$worktree_path\" --force 2>/dev/null");
    
    # Clean up any remaining directory using /bin/rm
    if (-d $worktree_path) {
        system("/bin/rm -rf \"$worktree_path\" 2>/dev/null");
    }
    
    # Optionally remove branch (commented out - let main AI decide)
    # system("git branch -D \"$branch_name\" 2>/dev/null");
}

sub run_claude_parallel {
    my ($prompts, $options) = @_;
    my %results;
    my $max_parallel = $options->{max_parallel} || scalar(@$prompts);
    my $batch_size = $max_parallel < scalar(@$prompts) ? $max_parallel : scalar(@$prompts);
    
    # Git worktree setup
    my $use_worktree = $options->{use_worktree} || 0;
    my $base_branch = '';
    my $original_cwd = '';
    my $worktree_base = '';
    
    if ($use_worktree) {
        $base_branch = get_current_branch();
        $original_cwd = getcwd();
        $worktree_base = File::Spec->catdir($original_cwd, '..', 'claude-worktrees');
        
        # Create worktree base directory if it doesn't exist
        unless (-d $worktree_base) {
            mkdir $worktree_base or die "Cannot create worktree base directory: $!\n";
        }
        
        print "Using git worktree mode from branch: $base_branch\n";
        print "Worktree base: $worktree_base\n";
    }
    
    print "Starting " . scalar(@$prompts) . " Claude instances";
    print " (max $max_parallel parallel)" if $max_parallel < scalar(@$prompts);
    print "...\n";
    
    my $prompt_index = 0;
    my @running_pids;
    
    while ($prompt_index < scalar(@$prompts) || @running_pids) {
        while (@running_pids < $max_parallel && $prompt_index < scalar(@$prompts)) {
            my $prompt_obj = $prompts->[$prompt_index];
            my $task_num = $prompt_index + 1;
            my $prompt_text = $prompt_obj->{prompt};
            my $transaction_id = $prompt_obj->{id};
            
            print "Starting task $task_num (ID: $transaction_id): " . substr($prompt_text, 0, 40);
            print "..." if length($prompt_text) > 40;
            print "\n";
            
            my $branch_name = '';
            my $worktree_path = '';
            
            my $task_use_worktree = $use_worktree;
            if ($task_use_worktree) {
                eval {
                    ($branch_name, $worktree_path) = create_worktree_branch($base_branch, $transaction_id, $worktree_base);
                    print "Created worktree branch: $branch_name at $worktree_path\n";
                };
                if ($@) {
                    warn "Failed to create worktree for task $task_num: $@";
                    print "Falling back to main repository execution\n";
                    $task_use_worktree = 0;
                }
            }
            
            my $pid = fork();
            if ($pid == 0) {
                # Change to worktree directory if using worktree
                if ($task_use_worktree && $worktree_path) {
                    chdir($worktree_path) or die "Cannot change to worktree directory: $!\n";
                    print "Working in worktree: $worktree_path\n";
                }
                
                my $enhanced_prompt = "Transaction ID: $transaction_id\n";
                if ($task_use_worktree && $branch_name) {
                    $enhanced_prompt .= "Working Branch: $branch_name\n";
                    $enhanced_prompt .= "Git Worktree: $worktree_path\n";
                    $enhanced_prompt .= "\nYou are working in a separate git worktree. Please commit your changes before completing the task.\n";
                }
                $enhanced_prompt .= "\n$prompt_text\n\nPlease start your response with: [ID: $transaction_id]";
                if ($task_use_worktree && $branch_name) {
                    $enhanced_prompt .= " [BRANCH: $branch_name]";
                }
                
                my @cmd = ('claude', '-p', $enhanced_prompt, '--dangerously-skip-permissions');
                exec(@cmd);
                die "exec failed: $!\n";
            } elsif ($pid > 0) {
                push @running_pids, {
                    pid => $pid,
                    task_num => $task_num,
                    prompt => $prompt_text,
                    transaction_id => $transaction_id,
                    start_time => time(),
                    branch_name => $branch_name,
                    worktree_path => $worktree_path
                };
            } else {
                die "fork failed: $!\n";
            }
            
            $prompt_index++;
        }
        
        if (@running_pids) {
            my $finished_pid = waitpid(-1, 0);
            if ($finished_pid > 0) {
                my $exit_code = $? >> 8;
                my $duration = time();
                
                @running_pids = grep { 
                    if ($_->{pid} == $finished_pid) {
                        $duration -= $_->{start_time};
                        print "Task $_->{task_num} (ID: $_->{transaction_id}) completed in ${duration}s with exit code $exit_code\n";
                        
                        my $branch_result = '';
                        if ($_->{branch_name}) {
                            $branch_result = $_->{branch_name};
                            print "Branch available for merge: $branch_result\n";
                            
                            # Cleanup worktree but keep branch
                            if ($_->{worktree_path}) {
                                cleanup_worktree($_->{worktree_path}, $_->{branch_name});
                                print "Cleaned up worktree: $_->{worktree_path}\n";
                            }
                        }
                        
                        $results{$finished_pid} = {
                            exit_code => $exit_code,
                            success => $exit_code == 0,
                            transaction_id => $_->{transaction_id},
                            task_num => $_->{task_num},
                            branch_name => $branch_result
                        };
                        
                        0;
                    } else {
                        1;
                    }
                } @running_pids;
            }
        }
    }
    
    return \%results;
}

sub wait_for_completion {
    my ($results_ref) = @_;
    my %results = %$results_ref;
    my $all_success = 1;
    my $total_tasks = scalar(keys %results);
    my $completed = 0;
    
    print "\nAll tasks completed.\n";
    
    for my $pid (sort keys %results) {
        $completed++;
        my $exit_code = $results{$pid}->{exit_code};
        my $success = $exit_code == 0;
        my $transaction_id = $results{$pid}->{transaction_id};
        my $task_num = $results{$pid}->{task_num};
        my $branch_name = $results{$pid}->{branch_name} || '';
        $all_success = 0 if $exit_code != 0;
        
        my $status_msg = $success ? "SUCCESS" : "FAILED";
        my $branch_info = $branch_name ? " [BRANCH: $branch_name]" : "";
        print "[$completed/$total_tasks] Task $task_num (ID: $transaction_id) Process $pid: $status_msg$branch_info\n";
    }
    
    return ($all_success, $results_ref);
}

sub print_summary {
    my ($success, $results, $start_time, $use_worktree) = @_;
    my $duration = time() - $start_time;
    my $total = scalar(keys %$results);
    my $successful = grep { $_->{success} } values %$results;
    my $failed = $total - $successful;
    
    print "\n" . "=" x 50 . "\n";
    print "EXECUTION SUMMARY\n";
    print "=" x 50 . "\n";
    print "Total tasks: $total\n";
    print "Successful: $successful\n";
    print "Failed: $failed\n";
    print "Total time: ${duration}s\n";
    print "Overall status: " . ($success ? "SUCCESS" : "FAILED") . "\n";
    print "=" x 50 . "\n";
    
    # Add merge instructions for AI if using worktree mode
    if ($use_worktree && $successful > 0) {
        my @successful_branches = grep { $_->{success} && $_->{branch_name} } values %$results;
        
        if (@successful_branches) {
            print "\n" . "🤖 AI MERGE INSTRUCTIONS\n";
            print "=" x 50 . "\n";
            print "The following branches are ready for merging:\n\n";
            
            for my $result (@successful_branches) {
                print "  • $result->{branch_name}\n";
            }
            
            print "\nTo merge these branches, run:\n";
            for my $result (@successful_branches) {
                print "  git merge $result->{branch_name}\n";
            }
            
            print "\nOr to merge all successful branches at once:\n";
            my $branch_list = join(' ', map { $_->{branch_name} } @successful_branches);
            print "  git merge $branch_list\n";
            
            print "\nAfter merging, you can clean up the branches with:\n";
            for my $result (@successful_branches) {
                print "  git branch -d $result->{branch_name}\n";
            }
            
            print "\n" . "=" x 50 . "\n";
        }
    }
}

sub generate_session_id {
    return generate_uuid();
}

sub create_session_dir {
    my ($session_id) = @_;
    my $results_dir = File::Spec->catdir('.', 'results', "session-$session_id");
    
    unless (-d 'results') {
        mkdir 'results' or die "Cannot create results directory: $!\n";
    }
    
    unless (-d $results_dir) {
        mkdir $results_dir or die "Cannot create session directory $results_dir: $!\n";
    }
    
    return $results_dir;
}

sub update_session_status {
    my ($session_dir, $status_data) = @_;
    my $status_file = File::Spec->catfile($session_dir, 'status.json');
    
    open my $fh, '>', $status_file or die "Cannot write to $status_file: $!\n";
    print $fh encode_json($status_data);
    close $fh;
}

sub get_session_status {
    my ($session_id) = @_;
    my $session_dir = File::Spec->catdir('.', 'results', "session-$session_id");
    my $status_file = File::Spec->catfile($session_dir, 'status.json');
    
    unless (-f $status_file) {
        die "Session $session_id not found or no status available\n";
    }
    
    open my $fh, '<', $status_file or die "Cannot read $status_file: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    
    return decode_json($content);
}

sub show_session_status {
    my ($session_id) = @_;
    my $status = get_session_status($session_id);
    
    print "Session: $session_id\n";
    print "Status: $status->{overall_status}\n";
    print "Started: $status->{start_time}\n";
    print "Tasks: $status->{completed}/$status->{total}\n";
    
    if ($status->{overall_status} eq 'completed') {
        print "Completed: $status->{end_time}\n";
        print "Duration: " . ($status->{end_time} - $status->{start_time}) . "s\n";
        print "Success: $status->{successful}/$status->{total}\n";
    }
    
    print "\nTasks:\n";
    for my $task (@{$status->{tasks}}) {
        my $status_icon = $task->{status} eq 'completed' ? 
            ($task->{success} ? '✅' : '❌') : '⏳';
        print "  $status_icon Task $task->{task_num} (ID: $task->{transaction_id}): $task->{status}\n";
    }
}

sub show_session_results {
    my ($session_id) = @_;
    my $session_dir = File::Spec->catdir('.', 'results', "session-$session_id");
    
    unless (-d $session_dir) {
        die "Session $session_id not found\n";
    }
    
    my $status = get_session_status($session_id);
    print "Session: $session_id\n";
    print "=" x 50 . "\n";
    
    for my $task (@{$status->{tasks}}) {
        my $task_file = File::Spec->catfile($session_dir, "task-$task->{transaction_id}.txt");
        print "\nTask $task->{task_num} (ID: $task->{transaction_id}):\n";
        print "-" x 30 . "\n";
        
        if (-f $task_file) {
            open my $fh, '<', $task_file or next;
            print <$fh>;
            close $fh;
        } else {
            print "No results available yet.\n";
        }
    }
}

sub run_claude_parallel_async {
    my ($prompts, $options, $session_dir, $status_ref) = @_;
    my %results;
    my $max_parallel = $options->{max_parallel} || scalar(@$prompts);
    my $batch_size = $max_parallel < scalar(@$prompts) ? $max_parallel : scalar(@$prompts);
    
    # Git worktree setup (same as original)
    my $use_worktree = $options->{use_worktree} || 0;
    my $base_branch = '';
    my $original_cwd = '';
    my $worktree_base = '';
    
    if ($use_worktree) {
        $base_branch = get_current_branch();
        $original_cwd = getcwd();
        $worktree_base = File::Spec->catdir($original_cwd, '..', 'claude-worktrees');
        
        unless (-d $worktree_base) {
            mkdir $worktree_base or die "Cannot create worktree base directory: $!\n";
        }
    }
    
    my $prompt_index = 0;
    my @running_pids;
    
    while ($prompt_index < scalar(@$prompts) || @running_pids) {
        while (@running_pids < $max_parallel && $prompt_index < scalar(@$prompts)) {
            my $prompt_obj = $prompts->[$prompt_index];
            my $task_num = $prompt_index + 1;
            my $prompt_text = $prompt_obj->{prompt};
            my $transaction_id = $prompt_obj->{id};
            
            my $branch_name = '';
            my $worktree_path = '';
            
            my $task_use_worktree = $use_worktree;
            if ($task_use_worktree) {
                eval {
                    ($branch_name, $worktree_path) = create_worktree_branch($base_branch, $transaction_id, $worktree_base);
                };
                if ($@) {
                    $task_use_worktree = 0;
                }
            }
            
            my $pid = fork();
            if ($pid == 0) {
                # Child process - redirect output to file
                my $result_file = File::Spec->catfile($session_dir, "task-$transaction_id.txt");
                open STDOUT, '>', $result_file or die "Cannot redirect output: $!\n";
                open STDERR, '>&STDOUT' or die "Cannot redirect stderr: $!\n";
                
                if ($task_use_worktree && $worktree_path) {
                    chdir($worktree_path) or die "Cannot change to worktree directory: $!\n";
                }
                
                my $enhanced_prompt = "Transaction ID: $transaction_id\n";
                if ($task_use_worktree && $branch_name) {
                    $enhanced_prompt .= "Working Branch: $branch_name\n";
                    $enhanced_prompt .= "Git Worktree: $worktree_path\n";
                    $enhanced_prompt .= "\nYou are working in a separate git worktree. Please commit your changes before completing the task.\n";
                }
                $enhanced_prompt .= "\n$prompt_text\n\nPlease start your response with: [ID: $transaction_id]";
                if ($task_use_worktree && $branch_name) {
                    $enhanced_prompt .= " [BRANCH: $branch_name]";
                }
                
                my @cmd = ('claude', '-p', $enhanced_prompt, '--dangerously-skip-permissions');
                exec(@cmd);
                die "exec failed: $!\n";
            } elsif ($pid > 0) {
                push @running_pids, {
                    pid => $pid,
                    task_num => $task_num,
                    prompt => $prompt_text,
                    transaction_id => $transaction_id,
                    start_time => time(),
                    branch_name => $branch_name,
                    worktree_path => $worktree_path
                };
                
                # Update task status to running
                for my $task (@{$status_ref->{tasks}}) {
                    if ($task->{transaction_id} eq $transaction_id) {
                        $task->{status} = 'running';
                        last;
                    }
                }
                update_session_status($session_dir, $status_ref);
                
            } else {
                die "fork failed: $!\n";
            }
            
            $prompt_index++;
        }
        
        if (@running_pids) {
            my $finished_pid = waitpid(-1, 0);
            if ($finished_pid > 0) {
                my $exit_code = $? >> 8;
                my $duration = time();
                
                @running_pids = grep { 
                    if ($_->{pid} == $finished_pid) {
                        $duration -= $_->{start_time};
                        
                        my $branch_result = '';
                        if ($_->{branch_name}) {
                            $branch_result = $_->{branch_name};
                            if ($_->{worktree_path}) {
                                cleanup_worktree($_->{worktree_path}, $_->{branch_name});
                            }
                        }
                        
                        # Update task status
                        for my $task (@{$status_ref->{tasks}}) {
                            if ($task->{transaction_id} eq $_->{transaction_id}) {
                                $task->{status} = 'completed';
                                $task->{success} = ($exit_code == 0) ? 1 : 0;
                                $task->{duration} = $duration;
                                last;
                            }
                        }
                        
                        # Update overall status
                        $status_ref->{completed}++;
                        if ($exit_code == 0) {
                            $status_ref->{successful}++;
                        }
                        update_session_status($session_dir, $status_ref);
                        
                        $results{$finished_pid} = {
                            exit_code => $exit_code,
                            success => $exit_code == 0,
                            transaction_id => $_->{transaction_id},
                            task_num => $_->{task_num},
                            branch_name => $branch_result
                        };
                        
                        0;
                    } else {
                        1;
                    }
                } @running_pids;
            }
        }
    }
    
    return \%results;
}

sub wait_for_completion_async {
    my ($results_ref, $session_dir, $status_ref) = @_;
    my %results = %$results_ref;
    my $all_success = 1;
    
    for my $pid (keys %results) {
        my $exit_code = $results{$pid}->{exit_code};
        $all_success = 0 if $exit_code != 0;
    }
    
    return ($all_success, $results_ref);
}

sub list_all_sessions {
    my $results_dir = './results';
    
    unless (-d $results_dir) {
        print "No sessions found. Results directory doesn't exist.\n";
        return;
    }
    
    opendir(my $dh, $results_dir) or die "Cannot read results directory: $!\n";
    my @session_dirs = grep { /^session-/ && -d File::Spec->catdir($results_dir, $_) } readdir($dh);
    closedir($dh);
    
    unless (@session_dirs) {
        print "No sessions found.\n";
        return;
    }
    
    print "All Sessions:\n";
    print "=" x 60 . "\n";
    
    my @session_data;
    for my $session_dir (@session_dirs) {
        my $session_id = $session_dir;
        $session_id =~ s/^session-//;
        
        eval {
            my $status = get_session_status($session_id);
            push @session_data, {
                id => $session_id,
                status => $status->{overall_status},
                start_time => $status->{start_time},
                total => $status->{total},
                completed => $status->{completed},
                successful => $status->{successful} || 0,
                end_time => $status->{end_time} || 0
            };
        };
        if ($@) {
            push @session_data, {
                id => $session_id,
                status => 'error',
                start_time => 0,
                total => 0,
                completed => 0,
                successful => 0,
                end_time => 0
            };
        }
    }
    
    # Sort by start time (newest first)
    @session_data = sort { $b->{start_time} <=> $a->{start_time} } @session_data;
    
    for my $session (@session_data) {
        my $status_icon = $session->{status} eq 'completed' ? '✅' : 
                         $session->{status} eq 'running' ? '⏳' : '❌';
        
        my $start_str = $session->{start_time} ? 
            scalar(localtime($session->{start_time})) : 'Unknown';
        
        printf "%s %s [%s]\n", $status_icon, substr($session->{id}, 0, 8), $session->{status};
        printf "   Started: %s\n", $start_str;
        printf "   Progress: %d/%d tasks", $session->{completed}, $session->{total};
        
        if ($session->{status} eq 'completed') {
            printf " (%d successful)", $session->{successful};
            if ($session->{end_time}) {
                my $duration = $session->{end_time} - $session->{start_time};
                printf " - Duration: %ds", $duration;
            }
        }
        print "\n\n";
    }
    
    print "Use --status SESSION_ID to see details\n";
    print "Use --results SESSION_ID to see output\n";
}

sub show_overview {
    my $results_dir = './results';
    
    unless (-d $results_dir) {
        print "No sessions found.\n";
        return;
    }
    
    opendir(my $dh, $results_dir) or die "Cannot read results directory: $!\n";
    my @session_dirs = grep { /^session-/ && -d File::Spec->catdir($results_dir, $_) } readdir($dh);
    closedir($dh);
    
    my $total_sessions = 0;
    my $running_sessions = 0;
    my $completed_sessions = 0;
    my $error_sessions = 0;
    my $total_tasks = 0;
    my $successful_tasks = 0;
    
    for my $session_dir (@session_dirs) {
        my $session_id = $session_dir;
        $session_id =~ s/^session-//;
        
        eval {
            my $status = get_session_status($session_id);
            $total_sessions++;
            $total_tasks += $status->{total} || 0;
            $successful_tasks += $status->{successful} || 0;
            
            if ($status->{overall_status} eq 'running') {
                $running_sessions++;
            } elsif ($status->{overall_status} eq 'completed') {
                $completed_sessions++;
            } else {
                $error_sessions++;
            }
        };
        if ($@) {
            $total_sessions++;
            $error_sessions++;
        }
    }
    
    print "📊 Session Overview\n";
    print "=" x 40 . "\n";
    print "Total Sessions: $total_sessions\n";
    print "  ⏳ Running: $running_sessions\n";
    print "  ✅ Completed: $completed_sessions\n";
    print "  ❌ Errors: $error_sessions\n";
    print "\nTotal Tasks: $total_tasks\n";
    print "Successful Tasks: $successful_tasks\n";
    
    if ($total_tasks > 0) {
        my $success_rate = sprintf("%.1f", ($successful_tasks / $total_tasks) * 100);
        print "Success Rate: ${success_rate}%\n";
    }
    
    print "\nUse --list to see all sessions\n";
}

sub show_help {
    pod2usage(-verbose => 2);
}

sub main {
    my %options = (
        help => 0,
        version => 0,
        max_parallel => 0,
        verbose => 0,
        use_worktree => 0,
        sync => 0,
        status => '',
        results => '',
        list => 0,
        overview => 0,
    );
    
    GetOptions(
        'help|h'         => \$options{help},
        'version|v'      => \$options{version},
        'max-parallel=i' => \$options{max_parallel},
        'verbose'        => \$options{verbose},
        'worktree'       => \$options{use_worktree},
        'sync'           => \$options{sync},
        'status=s'       => \$options{status},
        'results=s'      => \$options{results},
        'list'           => \$options{list},
        'overview'       => \$options{overview},
    ) or pod2usage(2);
    
    if ($options{help}) {
        show_help();
        return;
    }
    
    if ($options{version}) {
        print "Claude Parallel Runner v$VERSION\n";
        return;
    }
    
    # Handle status checking mode
    if ($options{status}) {
        show_session_status($options{status});
        return;
    }
    
    # Handle results viewing mode
    if ($options{results}) {
        show_session_results($options{results});
        return;
    }
    
    # Handle list sessions mode
    if ($options{list}) {
        list_all_sessions();
        return;
    }
    
    # Handle overview mode
    if ($options{overview}) {
        show_overview();
        return;
    }
    
    validate_claude_command();
    
    # Check if we're in a git repository and recommend worktree mode
    unless ($options{use_worktree}) {
        my $is_git_repo = system("git rev-parse --git-dir >/dev/null 2>&1") == 0;
        if ($is_git_repo) {
            print "💡 Recommendation: You are in a git repository. Consider using --worktree flag for isolated task execution.\n";
            print "   This prevents conflicts and makes branch management easier.\n";
            print "   Usage: $0 --worktree [other options] [input_file]\n\n";
        }
    }
    
    my $prompts;
    eval {
        $prompts = read_input($ARGV[0]);
    };
    if ($@) {
        die "Error reading input: $@";
    }
    
    if (!@$prompts) {
        die "No prompts provided in input\n";
    }
    
    if ($options{verbose}) {
        print "Loaded " . scalar(@$prompts) . " prompts:\n";
        for my $i (0 .. $#$prompts) {
            my $prompt_obj = $prompts->[$i];
            my $preview = substr($prompt_obj->{prompt}, 0, 50);
            $preview .= "..." if length($prompt_obj->{prompt}) > 50;
            print "  " . ($i + 1) . " (ID: $prompt_obj->{id}): $preview\n";
        }
        print "\n";
    }
    
    my $start_time = time();
    
    # Handle synchronous mode (optional)
    if ($options{sync}) {
        eval {
            my $results = run_claude_parallel($prompts, \%options);
            my ($success, $final_results) = wait_for_completion($results);
            
            print_summary($success, $final_results, $start_time, $options{use_worktree});
            
            if ($success) {
                print "\nAll Claude instances completed successfully!\n";
                exit 0;
            } else {
                print "\nSome Claude instances failed. Check the output above for details.\n";
                exit 1;
            }
        };
        if ($@) {
            die "Execution error: $@";
        }
        return;
    }
    
    # Default: Async mode
    my $session_id = generate_session_id();
    my $session_dir = create_session_dir($session_id);
    
    # Create initial status
    my $initial_status = {
        session_id => $session_id,
        overall_status => 'running',
        start_time => $start_time,
        total => scalar(@$prompts),
        completed => 0,
        successful => 0,
        tasks => [
            map {
                {
                    task_num => $_ + 1,
                    transaction_id => $prompts->[$_]{id},
                    prompt => substr($prompts->[$_]{prompt}, 0, 50) . (length($prompts->[$_]{prompt}) > 50 ? '...' : ''),
                    status => 'pending',
                    success => 0
                }
            } 0..$#$prompts
        ]
    };
    update_session_status($session_dir, $initial_status);
    
    # Fork into background
    my $bg_pid = fork();
    if ($bg_pid == 0) {
        # Child process - run in background
        eval {
            my $results = run_claude_parallel_async($prompts, \%options, $session_dir, $initial_status);
            my ($success, $final_results) = wait_for_completion_async($results, $session_dir, $initial_status);
            
            # Update final status
            $initial_status->{overall_status} = 'completed';
            $initial_status->{end_time} = time();
            $initial_status->{successful} = grep { $_->{success} } values %$final_results;
            update_session_status($session_dir, $initial_status);
            
            exit($success ? 0 : 1);
        };
        if ($@) {
            $initial_status->{overall_status} = 'error';
            $initial_status->{error} = $@;
            $initial_status->{end_time} = time();
            update_session_status($session_dir, $initial_status);
            exit 2;
        }
    } elsif ($bg_pid > 0) {
        # Parent process - return session ID and exit
        print "🚀 Started session: $session_id\n";
        print "📂 Results directory: $session_dir\n";
        print "\nUse these commands to monitor progress:\n";
        print "  $0 --status $session_id\n";
        print "  $0 --results $session_id\n";
        print "\nFor synchronous execution, use: $0 --sync [options]\n";
        exit 0;
    } else {
        die "Failed to fork background process: $!\n";
    }
}

main() unless caller;

__END__

=head1 NAME

claude-parallel-runner.pl - Run multiple Claude Code instances in parallel with async session management

=head1 SYNOPSIS

claude-parallel-runner.pl [OPTIONS] [JSON_FILE]

=head1 DESCRIPTION

This script executes multiple Claude Code instances in parallel with asynchronous session 
management. By default, all executions run in the background, returning session IDs 
immediately to solve Claude Code's 2-minute timeout limitation. Tasks can run for hours 
with persistent result storage.

=head1 EXECUTION MODES

=over 4

=item B<Default (Async Mode)>

./claude-parallel-runner.pl prompts.json

Starts tasks in background, returns session ID immediately. Use --status and --results 
commands to monitor progress.

=item B<Synchronous Mode>

./claude-parallel-runner.pl --sync prompts.json

Original behavior - waits for all tasks to complete before returning.

=back

=head1 SESSION MANAGEMENT OPTIONS

=over 4

=item B<--status=SESSION_ID>

Show detailed status of specific session including progress and task states.

=item B<--results=SESSION_ID>

View all task results from completed or running session.

=item B<--list>

List all sessions (running and completed) with status and progress information.

=item B<--overview>

Show overview statistics across all sessions including success rates.

=back

=head1 EXECUTION OPTIONS

=over 4

=item B<-h, --help>

Show this help message and exit.

=item B<-v, --version>

Show version information and exit.

=item B<--sync>

Force synchronous execution (wait for all tasks to complete).

=item B<--max-parallel=N>

Maximum number of parallel Claude instances to run simultaneously within a session.
Default: unlimited parallel execution.

=item B<--verbose>

Enable verbose output showing loaded prompts and session details.

=item B<--worktree>

Enable git worktree mode. Each task will be executed in a separate git worktree
with its own branch following the pattern: original_branch-task-uuid.
This allows for isolated development and easy branch management.

=back

=head1 INPUT FORMAT

The input must be a JSON object with a "prompts" array:

    {
        "prompts": [
            "Analyze the config.js file and suggest improvements",
            "Write unit tests for the auth.js file",
            "Refactor utils.js for better readability"
        ]
    }

=head1 USAGE EXAMPLES

=head2 Basic Execution (Async by Default)

=over 4

=item B<Start async session from JSON file:>

    ./claude-parallel-runner.pl prompts.json

=item B<Start async session from STDIN:>

    echo '{"prompts":["task1","task2"]}' | ./claude-parallel-runner.pl

=item B<Force synchronous execution:>

    ./claude-parallel-runner.pl --sync prompts.json

=back

=head2 Session Management

=over 4

=item B<Check status of specific session:>

    ./claude-parallel-runner.pl --status abc123def-456g-789h-ijkl-mnop12345678

=item B<View results of completed session:>

    ./claude-parallel-runner.pl --results abc123def-456g-789h-ijkl-mnop12345678

=item B<List all sessions:>

    ./claude-parallel-runner.pl --list

=item B<Show overview statistics:>

    ./claude-parallel-runner.pl --overview

=back

=head2 Advanced Options

=over 4

=item B<With limited parallelism:>

    ./claude-parallel-runner.pl --max-parallel=3 prompts.json

=item B<With verbose output:>

    ./claude-parallel-runner.pl --verbose prompts.json

=item B<With git worktree isolation:>

    ./claude-parallel-runner.pl --worktree prompts.json

=item B<Combined advanced options:>

    ./claude-parallel-runner.pl --worktree --max-parallel=2 --verbose prompts.json

=back

=head1 SESSION WORKFLOW

=head2 Typical Usage Pattern

=over 4

=item B<1. Start Session>

Execute prompts file to get session ID immediately:

    ./claude-parallel-runner.pl tasks.json
    # 🚀 Started session: abc123def-456g-789h-ijkl-mnop12345678

=item B<2. Monitor Progress>

Use --status to check progress:

    ./claude-parallel-runner.pl --status abc123def
    # Session: abc123def [running] Tasks: 2/5

=item B<3. View Results>

Use --results when tasks complete:

    ./claude-parallel-runner.pl --results abc123def

=item B<4. Manage Sessions>

Use --list and --overview for session management:

    ./claude-parallel-runner.pl --list
    ./claude-parallel-runner.pl --overview

=back

=head1 SESSION STORAGE

Sessions are stored in ./results/session-UUID/ with:

=over 4

=item * B<status.json> - Real-time session status and progress

=item * B<task-UUID.txt> - Individual task outputs

=back

=head1 EXIT CODES

=over 4

=item B<0>

Session started successfully (async mode) or all tasks completed (sync mode)

=item B<1>

One or more tasks failed (sync mode only)

=item B<2>

Input/validation error or Claude CLI not found

=back

=head1 REQUIREMENTS

=over 4

=item * Claude Code CLI must be installed and available in PATH

=item * Perl with JSON module

=item * Unix-like system with fork() support

=item * Git (required for --worktree mode)

=back

=head1 AUTHOR

Generated for parallel Claude Code execution

=head1 VERSION

1.0.0

=cut