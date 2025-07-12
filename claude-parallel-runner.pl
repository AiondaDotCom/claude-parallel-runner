#!/usr/bin/env perl

use strict;
use warnings;
use JSON;
use POSIX ":sys_wait_h";
use Getopt::Long;
use Pod::Usage;

our $VERSION = '1.0.0';

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
    
    return $data->{prompts};
}

sub validate_claude_command {
    my $claude_path = `which claude 2>/dev/null`;
    chomp $claude_path;
    
    unless ($claude_path && -x $claude_path) {
        die "Claude Code CLI not found in PATH. Please install Claude Code first.\n";
    }
    
    return $claude_path;
}

sub run_claude_parallel {
    my ($prompts, $options) = @_;
    my @pids;
    my $max_parallel = $options->{max_parallel} || scalar(@$prompts);
    my $batch_size = $max_parallel < scalar(@$prompts) ? $max_parallel : scalar(@$prompts);
    
    print "Starting " . scalar(@$prompts) . " Claude instances";
    print " (max $max_parallel parallel)" if $max_parallel < scalar(@$prompts);
    print "...\n";
    
    my $prompt_index = 0;
    my @running_pids;
    
    while ($prompt_index < scalar(@$prompts) || @running_pids) {
        while (@running_pids < $max_parallel && $prompt_index < scalar(@$prompts)) {
            my $prompt = $prompts->[$prompt_index];
            my $task_num = $prompt_index + 1;
            
            print "Starting task $task_num: " . substr($prompt, 0, 50);
            print "..." if length($prompt) > 50;
            print "\n";
            
            my $pid = fork();
            if ($pid == 0) {
                my @cmd = ('claude', '-p', $prompt, '--dangerously-skip-permissions');
                exec(@cmd);
                die "exec failed: $!\n";
            } elsif ($pid > 0) {
                push @running_pids, {
                    pid => $pid,
                    task_num => $task_num,
                    prompt => $prompt,
                    start_time => time()
                };
                push @pids, $pid;
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
                        print "Task $_->{task_num} completed in ${duration}s with exit code $exit_code\n";
                        0;
                    } else {
                        1;
                    }
                } @running_pids;
            }
        }
    }
    
    return @pids;
}

sub wait_for_completion {
    my (@pids) = @_;
    my %results;
    my $all_success = 1;
    my $total_tasks = scalar(@pids);
    my $completed = 0;
    
    print "\nWaiting for all tasks to complete...\n";
    
    for my $pid (@pids) {
        my $status = waitpid($pid, 0);
        my $exit_code = $? >> 8;
        $completed++;
        
        $results{$pid} = {
            exit_code => $exit_code,
            success => $exit_code == 0
        };
        
        $all_success = 0 if $exit_code != 0;
        
        my $status_msg = $exit_code == 0 ? "SUCCESS" : "FAILED";
        print "[$completed/$total_tasks] Process $pid: $status_msg\n";
    }
    
    return ($all_success, \%results);
}

sub print_summary {
    my ($success, $results, $start_time) = @_;
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
    );
    
    GetOptions(
        'help|h'         => \$options{help},
        'version|v'      => \$options{version},
        'max-parallel=i' => \$options{max_parallel},
        'verbose'        => \$options{verbose},
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
            my $preview = substr($prompts->[$i], 0, 60);
            $preview .= "..." if length($prompts->[$i]) > 60;
            print "  " . ($i + 1) . ": $preview\n";
        }
        print "\n";
    }
    
    my $start_time = time();
    
    eval {
        my @pids = run_claude_parallel($prompts, \%options);
        my ($success, $results) = wait_for_completion(@pids);
        
        print_summary($success, $results, $start_time);
        
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

=back

=head1 AUTHOR

Generated for parallel Claude Code execution

=head1 VERSION

1.0.0

=cut