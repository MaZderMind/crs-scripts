package CRS::Executor;

=head1 NAME

CRS::Executor - Library for executing Tracker XML Jobfiles

=head1 VERSION

Version 1.0rc1

=head1 SYNOPSIS

Generic usage:

    use CRS::Executor;
    my $executor = new CRS::Executor($jobxml);
    $ex->execute();

=head1 DESCRIPTION

The CRS tracker uses a well-defined XML schema to describe commands that shall be executed by workers.
This library "unpacks" those XML job files and actually executes the commands, thereby handling things
like managing input and output files and directories, correct encoding etc.

=head1 METHODS

=head2 new ($jobfile)

Create a new instance, giving it an XML jobfile. The parameter can be either a string containing XML or
a string containing the absolute full path to an XML file.

=head2 execute ($jobtype)

Actually execute the commands described in the XML jobfile. The optional jobtype argument can be used to
execute other tasks than the default jobtype of 'encoding'.

Returns undef on error (or dies on fatal error), returns 1 if all tasks were executed successfully.

=head2 getOutput ()

Returns the output of the executed commands together with informational output from the library as array.

=head2 getErrors ()

Returns the errors of the library.

=cut

use strict;
use warnings;
use charnames ':full';

use File::Spec;
use File::Which qw(which);
use XML::Simple qw(:strict);
use Encode;
use Carp::Always;

use constant FILE_OK => 0;

sub new {
	shift;
	my $jobxml = shift;
	my $self;

	$self->{jobxml} = $jobxml;
	$self->{job} = load_job($jobxml);

	# do not create instance if jobxml is faulty
	return unless defined $self->{job};

	$self->{locenc} = 'ascii';
	$self->{locenc} = `locale charmap`;
	
	$self->{outfilemap} = {};
	$self->{tmpfilemap} = {};
	$self->{output} = [];
	$self->{errors} = [];

	bless $self;
	return $self;
}

sub print {
	my ($self, $text) = @_;
	push @{$self->{output}}, $text;
	print "$text\n";
}

sub error {
	my ($self, $text) = @_;
	push @{$self->{errors}}, $text;
	print STDERR "$text\n";
}

sub fatal {
	my ($self, $text) = @_;
	push @{$self->{errors}}, $text;
	die "$text\n";
}

# static method, convert Unicode to ASCII, as callback from Encode
sub asciify {
    my ($ord) = @_;

    # is ASCII -> change nothing
    if ($ord < 128) {
        return chr($ord);
    }
    my $name = charnames::viacode($ord);
    my ($main, $with) = $name =~ m{^(.+)\sWITH\s(.*)}o;
    if (defined $with) {
        if (($with eq 'DIAERESIS') and ($main =~ m{\b[aou]\b}oi)) {
            return chr(charnames::vianame($main)) ."e";
        }
        return chr(charnames::vianame($main));
    }
    return "ss" if ($name eq 'LATIN SMALL LETTER SHARP S');
    return "?";
}

# static method, load job XML into object
sub load_job {

    my $jobfile = shift;
    die 'You need to supply a job!' unless $jobfile;

    my $job = XMLin(
        $jobfile,
        ForceArray => [
            'option',
            'task',
            'tasks',
        ],
        KeyAttr => ['id'],
    );
    return $job;
}

# static method, escape/remove shell quotes
sub replacequotes {
    my ($toquote) = @_;

    # contains quotes
    if ($^O eq 'linux') {
        # escape them on Linux
        $toquote =~ s{"}{\\"}og;
    } else {
        # strip them
        $toquote =~ s{"}{}og;
    }

    return $toquote;
}

# search a file
sub check_file {
	my ($self, $name, $type) = @_;

	# executable lookup
	if ($type eq 'exe') {
		return ($name, FILE_OK) if -x $name;
		my $path = which $name;
		$self->fatal ("Executable $name cannot be found!") unless defined($path);
		$self->fatal ("Executable $name is not executable!") unless -x $path;
		return ($name, FILE_OK);
	}

	# all other files must be given with absolute paths:
	if (not File::Spec->file_name_is_absolute($name)) {
		 $self->fatal ("Non-absolute filename given: '$name'!");
	}

	# input and config files must exist
	if ($type eq 'in' or $type eq 'cfg') {
		return ($name, FILE_OK) if -r $name;

		# maybe it is a file that is produced during this execution?
		if (defined($self->{outfilemap}->{$name})) {
			return ($self->{outfilemap}->{$name}, FILE_OK);
		}
		# try harder to find: asciify filename
		$name = encode('ascii', $name, \&asciify);
		return ($name, FILE_OK) if -r $name;

		$self->fatal ("Fatal: File $name is missing!");
	}

	# output files must not exist. if they do, they are deleted and deletion is checked
	if ($type eq 'out' || $type eq 'tmp') {
		if (-e $name) {
			$self->print ("Output or temporary file exists: '$name', deleting file.");
			unlink $name;
			$self->fatal ("Cannot delete '$name'!") if -e $name;
		}
		# check that the directory of the output file exists and is writable. if it
		# does not exist, try to create it.
		my(undef,$outputdir,undef) = File::Spec->splitpath($name);
		if (not -d $outputdir) {
			$self->print ("Output path '$outputdir' does not exist, trying to create");
			qx ( mkdir -p $outputdir );
			$self->fatal ("Cannot create directory '$outputdir'!") if (not -d $outputdir);
		}
		$self->fatal ("Output path '$outputdir' is not writable!") unless (-w $outputdir or -k $outputdir);

		# store real output filename, return unique temp filename instead
		if (defined($self->{outfilemap}->{$name})) {
			return ($self->{outfilemap}->{$name}, FILE_OK);
		}
		if (defined($self->{tmpfilemap}->{$name})) {
			return ($self->{tmpfilemap}->{$name}, FILE_OK);
		}
		my $safety = 10;
		do {
			my $tempname = $name . '.' . int(rand(32767));
			$self->{outfilemap}->{$name} = $tempname if $type eq 'out';
			$self->{tmpfilemap}->{$name} = $tempname if $type eq 'tmp';
			return ($tempname, FILE_OK) unless -e $tempname;
		} while ($safety--);
		$self->fatal ("Unable to produce random tempname!");
	}

	# do not allow unknown filetypes
	$self->fatal ("Unknown file type in jobfile: $type");
}

# create command 
sub parse_cmd {
	my ($self, $options) = @_;

	my $cmd = '';
	my $filerr = 0;
	my @outfiles;

	CONSTRUCT: foreach my $option (@$options) {
		my $cmdpart = '';
		if (ref \$option ne 'SCALAR') {
			if ($option->{filetype}) {
				# check locations and re-write file name 
				my $type = $option->{filetype};
				my $error;
				($cmdpart, $error) = $self->check_file($option->{content}, $type);

				# remember file problems
				$filerr = $error if $error;
			} else {
				# check for quoting option
				if (defined($option->{'quoted'}) && $option->{'quoted'} eq 'no') {
					$cmd .= ' ' . $option->{content} . ' ';
				} else {
					# just copy value
					$cmdpart = $option->{content};
				}
			}
		} else {
			$cmdpart = $option
		}
		next unless defined($cmdpart);

		if ($cmdpart =~ m{[ \[\]\(\)\s]}o) {
			# escape or remove existing quotes
			$cmdpart = replacequotes($cmdpart) if $cmdpart =~ m{"}o;
			# replace $ in cmds
			$cmdpart =~ s/\$/\\\$/g;
			# quote everything with regular double quotes
			if ($cmd =~ m{=$}o) {
				$cmd .= '"'. $cmdpart .'"';
			} else {
				$cmd .= ' "'. $cmdpart .'"';
			}
		} else {
			$cmdpart = replacequotes($cmdpart) if $cmdpart =~ m{"}o;
			if ($cmd =~ m{=$}o) {
				$cmd .= $cmdpart;
			} else {
				$cmd .= ' '. $cmdpart;
			}
		}
	}

	$cmd =~ s{^ }{}o;
	return $cmd;
}

sub run_cmd {
	my ($self, $cmd, $cmdencoding) = @_;

	# set encoding on STDOUT so program output can be re-printed without errors
	binmode STDOUT, ":encoding($self->{locenc})";

	$self->print ("running: \n$cmd\n\n");
	# The encoding in which the command is run is configurable, e.g. you want 
	# utf8 encoded metadata as parameter to FFmpeg also on a non-utf8 shell.
	$cmdencoding = 'UTF-8' unless defined($cmdencoding);
	$cmd = encode($cmdencoding, $cmd);

	my $handle;
	open ($handle, '-|', $cmd . ' 2>&1') or $self->fatal ("Cannot execute command");
	while (<$handle>) {
		my $line = decode($cmdencoding, $_);
		print $line;
		chomp $line;
		push @{$self->{output}}, $line;
	}
	close ($handle);

	# reset encoding layer
	binmode STDOUT;

	# check return code
	if ($?) {
		$self->print ("Task exited with code $?");
		return 0;
	}
	return 1;
}

sub task_loop {
	my $self = shift;

	my @tasks = ( ) ;
	foreach(@{$self->{job}->{tasks}}) {
		foreach(@{$_->{task}}) {
			push @tasks, $_ if $_->{type} eq $self->{filter};
		}
	}

	my $num_tasks = scalar @tasks;
	my $successful = 1;
	TASK: for (my $task_id = 0; $task_id < $num_tasks; ++$task_id) {

		# parse XML and print cmd
		my $cmd = $self->parse_cmd($tasks[$task_id]->{option});
		$self->print ("now executing task " . ($task_id + 1) . " of $num_tasks");

		$successful = $self->run_cmd($cmd, $tasks[$task_id]->{encoding});
		#check output files for existence if command claimed to be successfull
		if ($successful) {
			foreach (keys %{$self->{outfilemap}}) {
				next if -e $self->{outfilemap}->{$_};
				$successful = 0;
				$self->print ("output file missing: $_");
			}
		}

		# call hook
		if ($successful && defined($self->{precb})) {
			$successful = $self->{precb}->($self);
			if ($successful == 0) {
				# abort, but don't delete files
				$self->error('preTaskComplete callback signaled termination');
				return;
			}
		}

		#rename output files to real filenames after successful execution, delete them otherwise
		foreach (keys %{$self->{outfilemap}}) {
			my ($src, $dest) = ($self->{outfilemap}->{$_},$_);
			if ($successful) {
				$self->print ("renaming '$src' to '$dest'");
				rename ($src, $dest);
			} else {
				$self->print ("deleting '$src'");
				unlink $src;
			}
			delete ($self->{outfilemap}->{$_});
		}

		last unless $successful;
	}
	#delete other temporary files
	foreach (keys %{$self->{tmpfilemap}}) {
		unlink $self->{tmpfilemap}->{$_};
		delete ($self->{tmpfilemap}->{$_});
	}
	return $successful;
}

sub execute {
	my ($self, $filter) = @_;

	$self->{filter} = $filter if defined($filter);
	$self->{filter} = 'encoding' unless defined($filter);
	return $self->task_loop();
}

sub getOutput {
	my $self = shift;
	return @{$self->{output}};
}

sub getErrors {
	my $self = shift;
	return @{$self->{errors}};
}

=head2 setPreTaskFinishCallback (sub reference)

Register a callback that is called after a task has been finished but before the output files 
are renamed to their actual names. The callback gets one parameter, the calling Executor instance.

The return value of this callback is important.
If it returns 1, execution continues.
If it returns 0, execution will not continue.
If it returns -1, execution will not continue and the temporary output files are deleted.

=cut

sub setPreTaskFinishCallback {
	my $self = shift;
	my $cb = shift;
	unless (ref $cb) {
		$self->error("not a callback reference: ".Dumper($cb));
		return;
	}
	$self->{precb} = $cb;
}

=head2 getTemporaryFiles ()

This method returns an array containing all absolute full paths of the temporary 
files that have been created in the execution phase.

=cut

sub getTemporaryFiles {
	my $self = shift;
	my @ret = ();

	foreach (keys %{$self->{outfilemap}}) {
		push @ret, $self->{outfilemap}->{$_};
	}
	return @ret;
}

1;
