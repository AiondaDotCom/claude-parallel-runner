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
    );
    
    GetOptions(
        'help|h'         => \$options{help},
        'version|v'      => \$options{version},
        'max-parallel=i' => \$options{max_parallel},
        'verbose'        => \$options{verbose},
        'worktree'       => \$options{use_worktree},
    ) or pod2usage(2);
    
    if ($options{help}) {
        show_help();
        return;
    }
    
    if ($options{version}) {
        print "Claude Parallel Runner v$VERSION\n";
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
}

main() unless caller;

__END__

=head1 NAME

claude-parallel-runner.pl - Run multiple Claude Code instances in parallel

=head1 SYNOPSIS

claude-parallel-runner.pl [OPTIONS] [JSON_FILE]

=head1 DESCRIPTION

This script executes multiple Claude Code instances in parallel based on a list of prompts
provided either via a JSON file or STDIN. Each prompt is executed as a separate Claude
process using the --dangerously-skip-permissions flag.

=head1 OPTIONS

=over 4

=item B<-h, --help>

Show this help message and exit.

=item B<-v, --version>

Show version information and exit.

=item B<--max-parallel=N>

Maximum number of parallel Claude instances to run simultaneously.
Default: run all prompts in parallel.

=item B<--verbose>

Enable verbose output showing loaded prompts and additional information.

=item B<--worktree>

Enable git worktree mode. Each task will be executed in a separate git worktree
with its own branch following the pattern: original_branch/task-uuid.
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

=over 4

=item B<From JSON file:>

    ./claude-parallel-runner.pl prompts.json

=item B<From STDIN:>

    echo '{"prompts":["task1","task2"]}' | ./claude-parallel-runner.pl

=item B<With limited parallelism:>

    ./claude-parallel-runner.pl --max-parallel=3 prompts.json

=item B<With verbose output:>

    ./claude-parallel-runner.pl --verbose prompts.json

=item B<With git worktree mode:>

    ./claude-parallel-runner.pl --worktree prompts.json

=item B<Combined options:>

    ./claude-parallel-runner.pl --worktree --max-parallel=2 --verbose prompts.json

=back

=head1 EXIT CODES

=over 4

=item B<0>

All Claude instances completed successfully

=item B<1>

One or more Claude instances failed

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