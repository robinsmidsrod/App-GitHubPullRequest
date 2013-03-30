#!perl

use strict;
use warnings;
use feature qw(say state);

package App::GitHubPullRequest;

# ABSTRACT: Command-line tool to query GitHub pull requests

use JSON qw(decode_json encode_json);
use Carp qw(croak);
use Encode qw(encode_utf8);
use File::Spec;

use constant DEBUG => $ENV{'GIT_PR_DEBUG'} || 0;

=method new

Constructor. Takes no parameters.

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=method run(@args)

Calls any of the other listed public methods with specified arguments. This
is usually called automatically when you invoke L<git-pr>.

=cut

sub run {
    my ($self, @args) = @_;
    my $cmd = scalar @args ? shift @args : 'list';
    my $method = $self->can($cmd);
    return $self->$method(@args) if $method;
    return $self->help(@args);
}

=cmd help

Displays some help.

=cut

sub help {
    my ($self, @args) = @_;
    print <<"EOM";
$0 [<command> <args> ...]

Where command is one of these:

  help              Show this page
  list [<state>]    Show all pull requests (state: open/closed)
  show <number>     Show details for the specified pull request
  patch <number>    Fetch a properly formatted patch for specified pull request
  checkout <number> Create tracking branch for specified pull request

  login [<user>] [<password>] Login to GitHub and receive an access token
  comment <number> [<text>]   Create a comment on the specified pull request
  close <number>              Close the specified pull request
  open <number>               Reopen the specified pull request

EOM
    return 1;
}

=cmd list [<state>]

Shows all pull requests in the given state. State can be either C<open> or
C<closed>.  The default state is C<open>.  This is the default command if
none is specified.

=cut

sub list {
    my ($self, $state) = @_;
    $state ||= 'open';
    my $remote_repo = _find_github_remote();
    my $prs = _api_read("/repos/$remote_repo/pulls?state=$state");
    say ucfirst($state) . " pull requests for '$remote_repo':";
    unless ( @$prs ) {
        say "No pull requests found.";
        return 0;
    }
    foreach my $pr ( @$prs ) {
        my $number = $pr->{"number"};
        my $title = encode_utf8( $pr->{"title"} );
        my $date = $pr->{"updated_at"} || $pr->{'created_at'};
        say join(" ", $number, $date, $title);
    }
    return 0;
}

=cmd show <number>

Shows details about the specified pull request number. Also includes
comments.

=cut

sub show {
    my ($self, $number, @args) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $pr = $self->_fetch_one($number);
    die("Unable to fetch pull request $number.\n")
        unless defined $pr;
    {
        my $user = $pr->{'user'}->{'login'};
        my $title = encode_utf8( $pr->{"title"} );
        my $body = encode_utf8( $pr->{"body"} );
        my $date = $pr->{"updated_at"} || $pr->{'created_at'};
        say "Date:    $date";
        say "From:    $user";
        say "Subject: $title";
        say "Number:  $number";
        say "\n$body\n" if $body;
    }
    my $comments = _api_read( $pr->{'comments_url'} );
    foreach my $comment (@$comments) {
        my $user = $comment->{'user'}->{'login'};
        my $date = $comment->{'updated_at'} || $comment->{'created_at'};
        my $body = encode_utf8( $comment->{'body'} );
        say "-" x 79;
        say "Date: $date";
        say "From: $user";
        say "\n$body\n";
    }
    return 0;
}

=cmd patch <number>

Shows the patch associated with the specified pull request number.

=cut

sub patch {
    my ($self, $number) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $patch = _get_url(
        $self->_fetch_one($number)->{'patch_url'}
    );
    die("Unable to fetch patch for pull request $number.\n")
        unless defined $patch;
    print $patch;
    return 0;
}

=cmd checkout <number>

Checks out the specified pull request in a dedicated tracking branch.
If the remote repo is not already specified in your git config, it will be
added and the branch in question will be fetched.

=cut

sub checkout {
    my ($self, $number) = @_;
    my $pr;
    $number =~ s{[^\d]}{}g if defined $number;
    if ($number) {
        $pr = $self->_fetch_one($number);
        die("Unable to fetch pull request $number.\n")
            unless defined $pr;
    } else {
        die("Please specify a pull request number.\n");
    }

    # Get required contributor branch info
    my $head_repo   = $pr->{'head'}->{'repo'}->{'git_url'};
    my $head_branch = $pr->{'head'}->{'ref'};
    my $head_user   = $pr->{'head'}->{'user'}->{'login'};

    # Check if the remote already exists in our repo
    my $head_remote;
    foreach my $line ( _qx("git", "remote -v") ) {
        my ($remote, $url, $type) = split /\s+/, $line;
        next unless $type eq '(fetch)'; # only consider fetch remotes
        if ( $url eq $head_repo ) {
            $head_remote = $remote;
            last;
        }
    }

    if ( $head_remote ) {
        # Remote already exists, try to update its state
        unless ( _qx(qw(git branch --list -r), qq{"$head_remote/$head_branch"}) ) {
            # Create a new tracking branch, because one doesn't already exist
            my ($content, $rc) = _run_ext(
                qw(git remote set-branches),
                '--add',        # don't remove any other existing tracking branches
                $head_remote,   # our remote's name/alias
                $head_branch,   # the ref we want to track
            );
            die("git failed with error $rc when trying to add tracking branch"
              . " to existing remote.\n")
                if $rc != 0;
        }

        # Fetch changes from just added remote
        say "Fetching changes from '$head_remote/$head_branch'";
        my ($content, $rc) = _run_ext(
            qw(git fetch),
            $head_remote,
        );
        die("git failed with error $rc when trying to update remote.\n")
            if $rc != 0;
    }
    else {
        # Create and fetch the branch info if it doesn't exist already
        $head_remote = $head_user;
        my ($content, $rc) = _run_ext(
            qw(git remote add),
            '-f',                    # only fetch specific refs
            '-t', $head_branch,      # add only a ref for this ref, not all
            $head_remote,            # what we'll name our remote
            $head_repo,              # URL to the head repo
        );
        die("git failed with error $rc when trying to add remote.\n")
            if $rc != 0;
    }

    # Actually checkout the ref we just updated as pr/<number>
    my ($content, $rc) = _run_ext(
        qw(git checkout),
        '-b', "pr/$number",
        '--track', "$head_remote/$head_branch",
    );
    die("git failed with error $rc when trying to check out branch.\n")
        if $rc != 0;

    return 0;
}

=cmd close <number>

Closes the specified pull request number. Be aware, you can't close a pull
request that has already been merged.  If you try to, you'll get an obscure
C<Validation Failed> error message from the GitHub API.

=cut

sub close { ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($self, $number) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $pr = $self->_state($number, 'closed');
    die("Unable to close pull request $number.\n")
        unless defined $pr;
    say "Pull request $number now in state: " . $pr->{'state'};
    return 0;
}

=cmd open <number>

Reopens the specified pull request number. Be aware, you can't reopen a pull
request that has already been merged or closed by the repo owner.  If you
try to, you'll get an obscure C<Validation Failed> error message from the
GitHub API.

=cut

sub open { ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($self, $number) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $pr = $self->_state($number, 'open');
    die("Unable to open pull request $number.\n")
        unless defined $pr;
    say "Pull request $number now in state: " . $pr->{'state'};
    return 0;
}

=cmd comment <number> [<text>]

Creates a comment on the specified pull request with the specified text. If
text is not specified, an editor will be opened for you to type in the text.

If your C<EDITOR> environment variable has been set, that editor is used to
edit the text.  If it has not been set, it will try to use the L<editor(1)>
external program.  This is usually a symlink set up by your operating system
to the most recently installed text editor.

The text must be encoded using UTF-8.
=cut

sub comment {
    my ($self, $number, $text) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $remote_repo = _find_github_remote();
    my $filename;
    unless ( $text ) {
        $filename = _tmpfile("$remote_repo-$number");
        # Find and execute editor on temporary file
        my $editor = $ENV{'EDITOR'};
        unless ( $editor ) {
            _require_binary('editor');
            $editor = 'editor';
        }
        system($editor, $filename);
        # Fetch text just edited (if any)
        if ( -r $filename ) {
            CORE::open my $fh, "<:encoding(UTF-8)", $filename or die "Can't open $filename: $!";
            $text = join "", <$fh>;
            CORE::close $fh;
        }
        # Abort if no text found
        unless ( $text ) {
            unlink $filename;
            die("Your comment is empty. Command aborted.\n");
        }
    }
    my $comment = eval {
        _api_create(
            "/repos/$remote_repo/issues/$number/comments",
            { "body" => $text },
        );
    };
    die($@ . ( defined $filename ? "Comment text saved in '$filename'. Please remove it manually." : "" ) ."\n")
        if $@; # most likely network error
    die("Unable to add comment on pull request $number.\n")
        unless defined $comment;
    say "Comment added. You can view it online here: " . $comment->{'html_url'};

    # Remove temporary file if everything went well
    if ( defined $filename and -e $filename ) {
        my $count = unlink $filename;
        warn("Unable to remove temporary file $filename: $!\n")
            unless $count;
    }

    return 0;
}

=cmd login [<user>] [<password>]

Logs you in to GitHub and creates a new access token used instead of your
password.  If you don't specify either of the options, they are looked up in
your git config github section.  If none of those are found, you'll be
prompted for them.

=cut

sub login {
    my ($self, $user, $password) = @_;

    # Try to fetch user/password from git config (or prompt)
    $user     ||= _qx('git', "config github.user")     || _prompt('GitHub username');
    $password ||= _qx('git', "config github.password") || _prompt('GitHub password', 'hidden');
    die("Please specify a user name.\n") unless $user;
    die("Please specify a password.\n")  unless $password;

    # Perform authentication
    my $auth = _api_create(
        "/authorizations",
        {
            "scopes"   => [qw( public_repo repo )],
            "note"     => __PACKAGE__,
            "note_url" => 'https://metacpan/module/' . __PACKAGE__,
        },
        $user,
        $password,
    );
    die("Unable to authenticate with GitHub.\n")
        unless defined $auth;
    my $token = $auth->{'token'};
    die("Authentication data does not include a token.\n")
        unless $token;

    # Store successful authorization token
    my ($content, $rc) = _run_ext(qw(git config --global github.pr-token), $token);
    die("git config returned message '$content' and code $rc when trying to store your token.\n")
        if $rc != 0;
    say "Access token stored successfully. Go to https://github.com/settings/applications to revoke access.";
    return 0;
}

sub _state {
    my ($self, $number, $state) = @_;
    croak("Please specify a pull request number") unless $number;
    croak("Please specify a pull request state") unless $state;
    my $remote_repo = _find_github_remote();
    return _api_update(
        "/repos/$remote_repo/pulls/$number",
        { "state" => $state },
    );
}

sub _fetch_one {
    my ($self, $number) = @_;
    my $remote_repo = _find_github_remote();
    return _api_read("/repos/$remote_repo/pulls/$number");
}

sub _find_github_remote {
    # Parse lines from git and use first found github repo
    my $repo;
    foreach my $line ( _qx('git', 'remote -v') ) {
        my ($remote, $url, $type) = split /\s+/, $line;
        next unless $type eq '(fetch)'; # only consider fetch remotes
        next unless $url =~ m/github\.com/; # only consider remotes to github
        if ( $url =~ m{github.com[:/](.+?)(?:\.git)?$} ) {
            $repo = $1;
            last;
        }
    }

    # Allow override for testing
    $repo = $ENV{"GITHUB_REPO"} if $ENV{'GITHUB_REPO'};
    die("No valid GitHub remote repo found.\n")
        unless $repo;

    # Fetch repo information
    my $repo_info = _api_read("/repos/$repo");

    # Return the parent repo if repo is a fork
    return $repo_info->{'parent'}->{'full_name'}
        if $repo_info->{'fork'};

    # Not a fork, use this repo
    return $repo;
}

# Ask the user for some information
# Disable local echo if $hide_echo is true (for passwords)
sub _prompt {
    my ($label, $hide_echo) = @_;
    _echo('off') if $hide_echo;
    print "$label: " if defined $label;
    my $input = scalar <STDIN>;
    chomp $input;
    print "\n";
    _echo('on') if $hide_echo;
    return $input;
}

# Turn local echo on or off (Unix only for now)
sub _echo {
    my ($state) = @_;
    croak("Please specify an echo state of on or off") unless $state;

    # Test if we're on Unix (snatched from Platform::Unix)
    my $is_unix = $^O =~ /^(Linux|.*BSD.*|.*UNIX.*|Darwin|Solaris|SunOS|Haiku|Next|dec_osf|svr4|sco_sv|unicos.*|.*x)$/i;

    if ( $is_unix ) {
        return _run_ext(qw{stty -echo}) if $state eq 'off';
        return _run_ext(qw{stty echo})  if $state eq 'on';
    }

    # Don't know how to turn local echo on or off on other platforms.
    # If you happen to know how, please send a pull request with a fix
    return;
}

# Generate a random temporary filename with the given prefix
sub _tmpfile {
    my ($prefix) = @_;
    $prefix = defined $prefix ? "${prefix}-" : '';
    $prefix =~ s{[^A-Za-z0-9_-]}{-}g;
    srand($$ + time);
    my $random = $$;
    $random .= int(rand(10)) for 1..10;
    return "/tmp/git-pr-$prefix$random";
}

# Return stdout from external program
# If called in list context, each line will be chomped
# In scalar context, only last line will be chomped
sub _qx {
    my ($cmd, @rest) = @_;
    _require_binary($cmd);
    $cmd .= " " . join(" ", @rest) if @rest;
    warn("_qx: $cmd\n") if DEBUG;
    return map { chomp; $_ } qx{$cmd}
        if wantarray;
    my $content = qx{$cmd};
    chomp $content;
    return $content;
}

# Run an external command and return STDOUT and exit code
## no critic (Subroutines::RequireArgUnpacking)
sub _run_ext {
    croak("Please specify a command line") unless @_;
    my $cmd = join(" ", @_);
    my $prg = $_[0];
    warn("_run_ext: $cmd\n") if DEBUG;
    _require_binary($prg);
    CORE::open my $fh, "-|", @_ or die("Can't run command '$cmd': $!");
    my $stdout = join("", <$fh>);
    CORE::close $fh;
    my $rc = $? >> 8; # exit code, see perldoc perlvar for details
    return $stdout, $rc;
}
## use critic

# Make sure a program is present in path
sub _require_binary {
    my ($bin) = @_;
    croak("Please specify program to require") unless $bin;
    state %cache;
    unless (exists $cache{$bin}) {
        # Cache miss, let's see if we can find that program
        warn("Checking if '$bin' exists in path\n") if DEBUG;
        # Figure out path elements in a cross-platform way and go through
        # each and check if it has the executable program in it
        my @path = File::Spec->path();
        while (my $dir = shift @path) {
            my $file = File::Spec->catfile($dir, $bin);
            warn("Looking for executable bit on '$file'\n") if DEBUG;
            ## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements)
            $cache{$bin} = $file, last if -x $file;
            ## use critic
            $cache{$bin} = 0;
        }
        warn("'$bin' was found at '$cache{$bin}'\n") if DEBUG and $cache{$bin};
    }
    return 1 if $cache{$bin};
    die("You need the program '$bin' in your path to use this feature.\n");
}

# Return the base GitHub API URL as mentioned
# on http://developer.github.com/v3/
sub _api_url {
    my ($url) = @_;
    my $prefix = 'https://api.github.com/';
    # If no URL specified, just return the API URL
    return $prefix unless defined $url;
    # If URL already looks like a GitHub API URL, do nothing
    return $url if _is_api_url($url);
    # Create an API URL out of a partial URL as
    $url =~ s{^/*}{}; # Remove initial slashes, if any
    return $prefix . $url;
}

# Check if a URL is a GitHub API URL
sub _is_api_url {
    my ($url) = @_;
    croak("Please specify a URL to verify") unless $url;
    my $prefix = _api_url();
    return 1 if index($url, $prefix) == 0;
    return 0;
}

# Perform an API GET request
sub _api_read {
    my ($url) = @_;
    return decode_json(
        _get_url(
            _api_url($url),
        )
    );
}

# Perform an API POST request
sub _api_create {
    my ($url, $data, @rest) = @_;
    return decode_json(
        _post_url(
            _api_url($url),
            'application/json',
            encode_json($data),
            @rest,
        )
    );
}

# Perform an API PATCH request
sub _api_update {
    my ($url, $data) = @_;
    return decode_json(
        _patch_url(
            _api_url($url),
            'application/json',
            encode_json($data),
        )
    );
}

# Perform HTTP GET
sub _get_url {
    my ($url) = @_;
    croak("Please specify a URL") unless $url;

    # See if we should use credentials
    my @credentials;
    if ( _is_api_url($url) ) {
        my $token = _qx('git', 'config github.pr-token');
        @credentials = ( '-H', "Authorization: token $token" ) if $token;
    }

    # Send request
    my ($content, $rc) = _run_ext(
        'curl',
        '-s',                            # be silent
        '-w', '%{http_code}',            # include HTTP status code at end of stdout
        @credentials,                    # Logon credentials, if any
        $url,                            # The URL we're GETing
    );
    die("curl failed to fetch $url with code $rc.\n") if $rc != 0;

    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("Fetching URL $url failed with code $code:\n$content");
    }

    return $content;
}

# Perform HTTP PATCH
sub _patch_url {
    my ($url, $mimetype, $data) = @_;
    croak("Please specify a URL") unless $url;
    croak("Please specify a mimetype") unless $mimetype;
    croak("Please specify some data") unless $data;

    # See if we should use credentials
    my @credentials;
    if ( _is_api_url($url) ) {
        my $token = _qx('git', 'config github.pr-token');
        die("You must login before you can modify information.\n")
            unless $token;
        @credentials = ( '-H', "Authorization: token $token" );
    }

    # Send request
    my ($content, $rc) = _run_ext(
        'curl',
        '-s',                            # be silent
        '-w', '%{http_code}',            # include HTTP status code at end of stdout
        '-X', 'PATCH',                   # perform an HTTP PATCH
        '-H', "Content-Type: $mimetype", # What kind of data we're sending
        '-d', $data,                     # Our data
        @credentials,                    # Logon credentials, if any
        $url,                            # The URL we're PATCHing
    );
    die("curl failed to patch $url with code $rc.\n") if $rc != 0;

    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("If you get 'Validation Failed' error without any reason,"
          . " most likely the pull request has already been merged or closed by the repo owner.\n"
          . "URL: $url\n"
          . "Code: $code\n"
          . $content
        ) if $code == 422;
        die("Patching URL $url failed with code $code:\n$content");
    }

    return $content;
}

# Perform HTTP POST
sub _post_url {
    my ($url, $mimetype, $data, $user, $password) = @_;
    croak("Please specify a URL") unless $url;
    croak("Please specify a mimetype") unless $mimetype;
    croak("Please specify some data") unless $data;

    # See if we should use credentials
    my @credentials;
    if ( _is_api_url($url) ) {
        my $token = _qx('git', 'config github.pr-token');
        die("You must login before you can modify information.\n")
            unless $token or ( $user and $password );
        if ( $user and $password ) {
            @credentials = ( '-u', "$user:$password" );
        }
        else {
            @credentials = ( '-H', "Authorization: token $token" ) if $token;
        }
    }

    # Send request
    my ($content, $rc) = _run_ext(
        'curl',
        '-s',                            # be silent
        '-w', '%{http_code}',            # include HTTP status code at end of stdout
        '-X', 'POST',                    # perform an HTTP POST
        '-H', "Content-Type: $mimetype", # What kind of data we're sending
        '-d', $data,                     # Our data
        @credentials,                    # Logon credentials, if any
        $url,                            # The URL we're POSTing to
    );
    die("curl failed to post to $url with code $rc.\n") if $rc != 0;

    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("Posting to URL $url failed with code $code:\n$content");
    }

    return $content;
}

1;

=head1 SYNOPSIS

    $ git pr
    $ git pr list closed # not shown by default
    $ git pr show 7      # also includes comments
    $ git pr patch 7     # can be piped to colordiff if you like colors
    $ git pr checkout 7  # create upstream tracking branch pr/7
    $ git pr help

    $ git pr login       # Get access token for commands below
    $ git pr close 7
    $ git pr open 7
    $ git pr comment 7 'This is good stuff!'


=head1 INSTALLATION

Install it by just typing in these few lines in your shell:

    $ curl -L http://cpanmin.us | perl - --self-upgrade
    $ cpanm App::GitHubPullRequest

The following external programs are required:

=for :list
* L<git(1)>
* L<curl(1)>
* L<stty(1)>


=head1 DEBUGGING

Set the environment variable GIT_PR_DEBUG to a non-zero value to see more
details, like each API command being executed.

If you want to interact with another GitHub repo than the one in your
current directory, set the environment variable GITHUB_REPO to the name of
the repo in question. Example:

    GITHUB_REPO=robinsmidsrod/App-GitHubPullRequest git pr list

Be aware, that if that repo is a fork, the program will look for its parent.


=head1 CAVEATS

If you don't authenticate with GitHub using the login command, it will use
unauthenticated API requests where possible, which has a rate-limit of 60
requests.  If you login first it should allow 5000 requests before you hit
the limit.

You must be standing in a directory that is a git dir and that directory must
have a remote that points to github.com for the tool to work.


=head1 SEE ALSO

=for :list
* L<git-pr>
* L<GitHub Pull Request documentation|https://help.github.com/articles/using-pull-requests>
* L<GitHub Pull Request API documentation|http://developer.github.com/v3/pulls/>

=head1 SEMANTIC VERSIONING

This module uses semantic versioning concepts from L<http://semver.org/>.


=cut
