use strict;
use warnings;
use feature qw(say);

package App::GitHubPullRequest;

# ABSTRACT: Command-line tool to query GitHub pull requests

use JSON qw(decode_json encode_json);
use Carp qw(croak);

sub DEBUG;

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=method run(@args)

Calls any of the other listed public methods with specified arguments. This
is usually called automatically when you invoke L<prq>.

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

  help           Show this page
  list [<state>] Show all pull requests (state: open/closed)
  show <number>  Show details for the specific pull request
  patch <number> Fetch a properly formatted patch for the specific pull request
  comment <number> <text> Create a comment on the specified pull request

  login [<user>] [<password>] Login to GitHub and receive an access token
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
    my $prs = $self->_fetch_all($state);
    say ucfirst($prs->{'state'}) . " pull requests for '" . $prs->{"repo"} . "':";
    unless ( $prs->{'pull_requests'} and @{ $prs->{'pull_requests'} } ) {
        say "No pull requests found.";
        return 0;
    }
    foreach my $pr ( @{ $prs->{"pull_requests"} } ) {
        my $number = $pr->{"number"};
        my $title = $pr->{"title"};
        my $body = $pr->{"body"};
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
        my $title = $pr->{"title"};
        my $body = $pr->{"body"};
        my $date = $pr->{"updated_at"} || $pr->{'created_at'};
        say "Date:    $date";
        say "From:    $user";
        say "Subject: $title";
        say "Number:  $number";
        say "\n$body\n" if $body;
    }
    my $comments = $self->_fetch_comments($pr);
    foreach my $comment (@$comments) {
        my $user = $comment->{'user'}->{'login'};
        my $date = $comment->{'updated_at'} || $comment->{'created_at'};
        my $body = $comment->{'body'};
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
    my $patch = $self->_fetch_patch($number);
    die("Unable to fetch patch for pull request $number.\n")
        unless defined $patch;
    print $patch;
    return 0;
}

=cmd close <number>

Closes the specified pull request number. Be aware, you can't close a pull
request that has already been merged.  If you try to, you'll get an obscure
C<Validation Failed> error message from the GitHub API.

=cut

sub close {
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

sub open {
    my ($self, $number) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $pr = $self->_state($number, 'open');
    die("Unable to open pull request $number.\n")
        unless defined $pr;
    say "Pull request $number now in state: " . $pr->{'state'};
    return 0;
}

=cmd comment <number> <text>

Creates a comment on the specified pull request with the specified text.

=cut

sub comment {
    my ($self, $number, $text) = @_;
    die("Please specify a pull request number.\n") unless $number;
    die("Please specify some text.\n") unless $text;
    my $remote_repo = _find_github_remote();
    my $url = "https://api.github.com/repos/$remote_repo/issues/$number/comments";
    my $mimetype = 'application/json';
    my $data = encode_json({ "body" => $text });
    my $comment = decode_json( _post_url($url, $mimetype, $data) );
    die("Unable to add comment on pull request $number.\n")
        unless defined $comment;
    say "Comment added. You can view it online here: " . $comment->{'html_url'};
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
    _require_binary('git');
    $user     ||= qx{git config github.user}     || _prompt('GitHub username');
    $password ||= qx{git config github.password} || _prompt('GitHub password', 'hidden');
    chomp $user;
    chomp $password;
    die("Please specify a user name.\n") unless $user;
    die("Please specify a password.\n")  unless $password;
    my $url = "https://api.github.com/authorizations";
    my $mimetype = 'application/json';
    my $data = encode_json({
        "scopes"   => [qw( public_repo repo )],
        "note"     => __PACKAGE__,
        "note_url" => 'https://metacpan/module/' . __PACKAGE__,
    });
    my $auth = decode_json( _post_url($url, $mimetype, $data, $user, $password) );
    die("Unable to authenticate with GitHub.\n")
        unless defined $auth;
    my $token = $auth->{'token'};
    die("Authentication data does not include a token.\n")
        unless $token;
    my $content = qx{git config --global github.prq-token '$token'};
    my $rc = $? >> 8; # turn into exit code
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
    my $url = "https://api.github.com/repos/$remote_repo/pulls/$number";
    my $mimetype = 'application/json';
    my $data = encode_json({ "state" => $state });
    my $pr = decode_json( _patch_url($url, $mimetype, $data) );
    return $pr;
}

sub _fetch_comments {
    my ($self, $pr) = @_;
    croak("Please specify a pull request") unless $pr;
    my $comments_url = $pr->{'comments_url'};
    my $comments = decode_json( _get_url($comments_url) );
    return $comments;
}

sub _fetch_patch {
    my ($self, $number) = @_;
    my $patch_url = $self->_fetch_one($number)->{'patch_url'};
    return _get_url($patch_url);
}

sub _fetch_one {
    my ($self, $number) = @_;
    my $remote_repo = _find_github_remote();
    my $pr_url = "https://api.github.com/repos/$remote_repo/pulls/$number";
    my $pr = decode_json( _get_url($pr_url) );
    return $pr;
}

sub _fetch_all {
    my ($self, $state) = @_;
    $state ||= 'open';
    my $remote_repo = _find_github_remote();
    my $pulls_url = "https://api.github.com/repos/$remote_repo/pulls?state=$state";
    my $pull_requests = decode_json( _get_url($pulls_url) );
    return {
        "repo"           => $remote_repo,
        "state"          => $state,
        "pull_requests"  => $pull_requests,
    };
}

sub _find_github_remote {
    _require_binary('git');
    # Fetch remotes using git
    my @lines = grep { chomp } qx{git remote -v};
    my $repo;

    # Parse lines from git and use first found github repo
    foreach my $line (@lines) {
        my ($remote, $url, $type) = split /\s+/, $line;
        next unless $type eq '(fetch)'; # only consider fetch remotes
        next unless $url =~ m/github\.com/; # only consider remotes to github
        if ( $url =~ m{github.com[:/](.+)\.git$} ) {
            $repo = $1;
            last;
        }
    }

    # Allow override for testing
    $repo = $ENV{"GITHUB_REPO"} if $ENV{'GITHUB_REPO'};
    die("No valid GitHub remote repo found.\n")
        unless $repo;

    # Fetch repo information
    my $repo_url = "https://api.github.com/repos/$repo";
    my $repo_info = decode_json( _get_url( $repo_url ) );
    die("Unable to fetch repo information for $repo_url.\n")
        unless $repo_info;

    # Return the parent repo if repo is a fork
    return $repo_info->{'parent'}->{'full_name'}
        if $repo_info->{'fork'};

    # Not a fork, use this repo
    return $repo;
}

# Ask the user for some information
sub _prompt {
    my ($label, $hide_echo) = @_;
    print "$label: " if defined $label;
    _require_binary('stty') if $hide_echo;
    system("stty -echo") if $hide_echo;
    my $input = scalar <STDIN>;
    system("stty echo") if $hide_echo;
    chomp $input;
    return $input;
}

# Make sure a program is present in path
sub _require_binary {
    my ($bin) = @_;
    croak("Please specify program to require") unless $bin;
    system("which $bin >/dev/null");
    return 1 if $? >> 8 == 0; # exit code is 0
    die("You need the program '$bin' in your path to use this feature.\n");
}

=head1 DEBUGGING

Set the environment variable PRQ_DEBUG to a non-zero value to see more
details, like each API command being executed.

If you want to interact with another GitHub repo than the one in your
current directory, set the environment variable GITHUB_REPO to the name of
the repo in question. Example:

    GITHUB_REPO=robinsmidsrod/App-GitHubPullRequest prq list

Be aware, that if that repo is a fork, the program will look for its parent.

=cut

sub DEBUG {
    return $ENV{'PRQ_DEBUG'} || 0;
}

# Perform HTTP GET
sub _get_url {
    my ($url) = @_;
    croak("Please specify a URL") unless $url;

    # See if we should use credentials
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        _require_binary('git');
        my $token = qx{git config github.prq-token};
        chomp $token;
        $credentials = qq{-H 'Authorization: token $token'} if $token;
    }

    # Fetch information
    _require_binary('curl');
    my $cmd = qq{curl -s -w '\%{http_code}' $credentials "$url"};
    warn("$cmd\n") if DEBUG;
    my $content = qx{$cmd};
    my $rc = $? >> 8; # see perldoc perlvar $? entry for details
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
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        _require_binary('git');
        my $token = qx{git config github.prq-token};
        chomp $token;
        die("You must aquire a token with the login command before you can modify information.\n")
            unless $token;
        $credentials = qq{-H 'Authorization: token $token'};
    }

    # Prepare modification request
    my $mime = qq{-H "Content-Type: $mimetype"};
    $data =~ s{"}{\\"}g; # Escape all double quotes
    my $datatosend = qq{-d "$data"};

    # Send modification request
    _require_binary('curl');
    my $cmd = qq{curl -s -w '\%{http_code}' -X PATCH $credentials $mime $datatosend "$url"};
    warn("$cmd\n") if DEBUG;
    my $content = qx{$cmd};
    my $rc = $? >> 8; # see perldoc perlvar $? entry for details
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
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        _require_binary('git');
        my $token = qx{git config github.prq-token};
        chomp $token;
        die("You must set 'git config github.prq-token' by using the login command to modify pull requests.\n")
            unless $token or ( $user and $password );
        if ( $user and $password ) {
            $credentials = qq{-u "$user:$password"};
        }
        else {
            $credentials = qq{-H 'Authorization: token $token'} if $token;
        }
    }

    # Prepare modification request
    my $mime = qq{-H "Content-Type: $mimetype"};
    $data =~ s{"}{\\"}g; # Escape all double quotes
    my $datatosend = qq{-d "$data"};

    # Send modification request
    _require_binary('curl');
    my $cmd = qq{curl -s -w '\%{http_code}' -X POST $credentials $mime $datatosend "$url"};
    warn("$cmd\n") if DEBUG;
    my $content = qx{$cmd};
    my $rc = $? >> 8; # see perldoc perlvar $? entry for details
    die("curl failed to post to $url with code $rc.\n") if $rc != 0;

    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("Posting to URL $url failed with code $code:\n$content");
    }

    return $content;
}

1;

=head1 SYNOPSIS

    $ prq
    $ prq list closed # not shown by default
    $ prq show 7      # also includes comments
    $ prq patch 7     # can be piped to colordiff if you like colors
    $ prq help

    $ prq login       # Get access token for commands below
    $ prq close 7
    $ prq open 7
    $ prq comment 7 'This is good stuff!'


=head1 INSTALLATION

Install it by just typing in these few lines in your shell:

    $ curl -L http://cpanmin.us | perl - --self-upgrade
    $ cpanm App::GitHubPullRequest

The following external programs are required:

=for :list
* L<git(1)>
* L<curl(1)>
* L<stty(1)>


=head1 CAVEATS

If you don't authenticate with GitHub using the login command, it will use
unauthenticated API requests where possible, which has a rate-limit of 60
requests.  If you login first it should allow 5000 requests before you hit
the limit.

You must be standing in a directory that is a git dir and that directory must
have a remote that points to github.com for the tool to work.


=head1 SEE ALSO

=for :list
* L<prq>
* L<GitHub Pull Request documentation|https://help.github.com/articles/using-pull-requests>
* L<GitHub Pull Request API documentation|http://developer.github.com/v3/pulls/>

=head1 SEMANTIC VERSIONING

This module uses semantic versioning concepts from L<http://semver.org/>.


=cut
