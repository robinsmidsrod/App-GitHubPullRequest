use strict;
use warnings;
use feature qw(say);

package App::GitHubPullRequest;

# ABSTRACT: Command-line tool to query GitHub pull requests

use JSON qw(decode_json);
use Data::Dumper qw(Dumper);

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

sub run {
    my ($self, @args) = @_;
    my $cmd = scalar @args ? shift @args : 'list';
    my $method = $self->can($cmd);
    return $self->$method(@args) if $method;
    return $self->help(@args);
}

sub help {
    my ($self, @args) = @_;
    print <<"EOM";
$0 [<command> <args> ...]

Where command is one of these:

  list [<state>] Show all pull requests (default)
                     state: open/closed (default: open)
  show <number>  Show details for a specific pull request
  patch <number> Fetch a properly formatted patch for specific pull request
  help           Show this page

EOM
    return 1;
}

sub patch {
    my ($self, $number) = @_;
    die("Please specify a pull request number.\n") unless $number;
    my $patch = $self->_fetch_patch($number);
    die("Unable to fetch patch for pull request $number.\n")
        unless defined $patch;
    print $patch;
    return 0;
}

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
    my $comments = $self->_fetch_comments($number);
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

sub _fetch_comments {
    my ($self, $number) = @_;
    my $pr = $self->_fetch_one($number);
    die("Unable to fetch comments for pull request $number.\n") unless $pr;
    my $comments_url = $pr->{'comments_url'};
    my $comments = decode_json( _fetch_url($comments_url) );
    return $comments;
}

sub _fetch_patch {
    my ($self, $number) = @_;
    my $remote_repo = _find_github_remote();
    my $patch_url = $self->_fetch_one($number)->{'patch_url'};
    return _fetch_url($patch_url);
}

sub _fetch_one {
    my ($self, $number) = @_;
    my $remote_repo = _find_github_remote();
    my $pr_url = 'https://api.github.com/repos/' . $remote_repo . '/pulls/' . $number;
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
        next unless $url =~ m/github\.com:/; # only consider remotes to github
        if ( $url =~ m/github.com:(.+)\.git$/ ) {
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

    my $content = qx{curl -s -w '\%{http_code}' $credentials "$url"};
    my $rc = $? >> 8; # see perldoc perlvar $? entry for details
    die("curl failed to fetch $url with code $rc.\n") if $rc != 0;
    my $code = substr($content, -3, 3, '');
    if ( $code >= 400 ) {
        die("Fetching URL $url failed with code $code:\n$content\n");
    }
    return $content;
}

1;
