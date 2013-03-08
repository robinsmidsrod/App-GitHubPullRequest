use strict;
use warnings;
use feature qw(say);

package App::GitHubPullRequest;

# ABSTRACT: Command-line tool to query GitHub pull requests

use JSON qw(decode_json encode_json);
use Carp qw(croak);

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

  list [<state>] Show all pull requests (default)
                     state: open/closed (default: open)
  show <number>  Show details for the specific pull request
  patch <number> Fetch a properly formatted patch for the specific pull request
  close <number> Close the specified pull request
  open <number>  Reopen the specified pull request

  comment <number> <text> Create a comment on the specified pull request

  help           Show this page

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

Closes the specified pull request number.

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

Reopens the specified pull request number.

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
    say "Comment added. You can view it online here:\n"
      . $comment->{'html_url'};
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
    my $comments = decode_json( _fetch_url($comments_url) );
    return $comments;
}

sub _fetch_patch {
    my ($self, $number) = @_;
    my $patch_url = $self->_fetch_one($number)->{'patch_url'};
    return _fetch_url($patch_url);
}

sub _fetch_one {
    my ($self, $number) = @_;
    my $remote_repo = _find_github_remote();
    my $pr_url = "https://api.github.com/repos/$remote_repo/pulls/$number";
    my $pr = decode_json( _fetch_url($pr_url) );
    return $pr;
}

sub _fetch_all {
    my ($self, $state) = @_;
    $state ||= 'open';
    my $remote_repo = _find_github_remote();
    my $pulls_url = "https://api.github.com/repos/$remote_repo/pulls?state=$state";
    my $pull_requests = decode_json( _fetch_url($pulls_url) );
    return {
        "repo"           => $remote_repo,
        "state"          => $state,
        "pull_requests"  => $pull_requests,
    };
}

sub _find_github_remote {
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
    my $repo_info = decode_json( _fetch_url( $repo_url ) );
    die("Unable to fetch repo information for $repo_url.\n")
        unless $repo_info;

    # Return the parent repo if repo is a fork
    return $repo_info->{'parent'}->{'full_name'}
        if $repo_info->{'fork'};

    # Not a fork, use this repo
    return $repo;
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

# Fetch the content of a URL
# If URL starts with https://api.github.com/, use github user+password from
# your ~/.gitconfig
sub _fetch_url {
    my ($url) = @_;
    croak("Please specify a URL") unless $url;

    # See if we should use credentials
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        my $user = qx{git config github.user};
        my $password = qx{git config github.password};
        chomp $user;
        chomp $password;
        if ( $user and $password ) {
            $credentials = qq{-u "$user:$password"};
        }
    }

    # Fetch information
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

# Send a PATCH request to a URL
# If URL starts with https://api.github.com/, use github user+password from
# your ~/.gitconfig
sub _patch_url {
    my ($url, $mimetype, $data) = @_;
    croak("Please specify a URL") unless $url;
    croak("Please specify a mimetype") unless $mimetype;
    croak("Please specify some data") unless $data;

    # See if we should use credentials
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        my $user = qx{git config github.user};
        my $password = qx{git config github.password};
        chomp $user;
        chomp $password;
        die("You must set 'git config github.user' and 'git config github.password' to modify pull requests.\n")
            unless $user and $password;
        $credentials = qq{-u "$user:$password"};
    }

    # Prepare modification request
    my $mime = qq{-H "Content-Type: $mimetype"};
    $data =~ s{'}{\\'}; # Escape single quotes
    my $datatosend = qq{-d '$data'};

    # Send modification request
    my $cmd = qq{curl -s -w '\%{http_code}' -X PATCH $credentials $mime $datatosend "$url"};
    warn("$cmd\n") if DEBUG;
    my $content = qx{$cmd};
    my $rc = $? >> 8; # see perldoc perlvar $? entry for details
    die("curl failed to patch $url with code $rc.\n") if $rc != 0;
    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("Patching URL $url failed with code $code:\n$content");
    }
    return $content;
}

# Send a POST request to a URL
# If URL starts with https://api.github.com/, use github user+password from
# your ~/.gitconfig
sub _post_url {
    my ($url, $mimetype, $data) = @_;
    croak("Please specify a URL") unless $url;
    croak("Please specify a mimetype") unless $mimetype;
    croak("Please specify some data") unless $data;

    # See if we should use credentials
    my $credentials = "";
    if ( $url =~ m{^https://api.github.com/} ) {
        my $user = qx{git config github.user};
        my $password = qx{git config github.password};
        chomp $user;
        chomp $password;
        die("You must set 'git config github.user' and 'git config github.password' to modify pull requests.\n")
            unless $user and $password;
        $credentials = qq{-u "$user:$password"};
    }

    # Prepare modification request
    my $mime = qq{-H "Content-Type: $mimetype"};
    $data =~ s{'}{\\'}; # Escape single quotes
    my $datatosend = qq{-d '$data'};

    # Send modification request
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
    $ prq close 7
    $ prq open 7
    $ prq comment 7 "This is good stuff!"
    $ prq help


=head1 INSTALLATION

Install it by just typing in these few lines in your shell:

    $ curl -L http://cpanmin.us | perl - --self-upgrade
    $ cpanm App::GitHubPullRequest


=head1 CAVEATS

If you don't have C<git config github.user> and C<git config github.password>
set in your git config, it will use unauthenticated API requests, which has
a rate-limit of 60 requests. If you add your user + password info it should
allow 5000 requests before you hit the limit.

You must be standing in a directory that is a git dir and that directory must
have a remote that points to github.com for the tool to work.


=head1 SEE ALSO

=for :list
* L<prq>


=head1 SEMANTIC VERSIONING

This module uses semantic versioning concepts from L<http://semver.org/>.


=cut
