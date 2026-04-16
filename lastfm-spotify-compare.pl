#!/usr/bin/env perl

use YAML::Tiny;
use LWP::UserAgent;
use JSON;
use File::Path qw(make_path);
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);
use strict;
use warnings;

my $config_file   = 'conf/config.yaml';
my $cache_dir     = 'cache';
my $lastfm_cache  = "$cache_dir/lastfm.json";
my $spotify_cache = "$cache_dir/spotify.json";
my $token_cache   = "$cache_dir/spotify_token.json";

# Load config
my $yaml = YAML::Tiny->read($config_file)
    or die "Cannot read config: " . YAML::Tiny->errstr;
my $config = $yaml->[0];

my $ua = LWP::UserAgent->new();

make_path($cache_dir);

# --- Last.fm ---

my @lastfm_tracks;
if (-f $lastfm_cache && prompt_use_cache('Last.fm', $lastfm_cache)) {
    @lastfm_tracks = @{ load_cache($lastfm_cache) };
    print "Loaded " . scalar(@lastfm_tracks) . " tracks from Last.fm cache.\n";
} else {
    print "Fetching Last.fm loved tracks for $config->{lastfm}{username}...\n";
    @lastfm_tracks = fetch_lastfm_tracks($ua, $config);
    print "Fetched " . scalar(@lastfm_tracks) . " loved tracks.\n";
    write_cache($lastfm_cache, \@lastfm_tracks);
    print "Cache written to $lastfm_cache\n";
}

# --- Spotify ---

print "\n";

my @spotify_tracks;
if (-f $spotify_cache && prompt_use_cache('Spotify', $spotify_cache)) {
    @spotify_tracks = @{ load_cache($spotify_cache) };
    print "Loaded " . scalar(@spotify_tracks) . " tracks from Spotify cache.\n";
} else {
    print "Fetching Spotify liked tracks...\n";
    my $access_token = get_spotify_token($config, $token_cache);
    @spotify_tracks  = fetch_spotify_tracks($ua, $access_token);
    print "Fetched " . scalar(@spotify_tracks) . " liked tracks.\n";
    write_cache($spotify_cache, \@spotify_tracks);
    print "Cache written to $spotify_cache\n";
}

sub prompt_use_cache {
    my ($label, $cache_file) = @_;

    my $mtime = (stat($cache_file))[9];
    my $age   = time() - $mtime;
    my $age_str = $age < 3600
        ? int($age / 60) . " minutes"
        : int($age / 3600) . " hours";

    print "$label cache exists (age: $age_str). Use cached data? [y/n] ";
    chomp(my $answer = <STDIN>);
    return lc($answer) eq 'y';
}

sub load_cache {
    my ($cache_file) = @_;

    open my $fh, '<', $cache_file or die "Cannot read cache $cache_file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    return decode_json($json);
}

sub write_cache {
    my ($cache_file, $data) = @_;

    open my $fh, '>', $cache_file or die "Cannot write cache $cache_file: $!";
    print $fh encode_json($data);
    close $fh;
}

sub fetch_lastfm_tracks {
    my ($ua, $config) = @_;

    my $api_key  = $config->{lastfm}{api_key};
    my $username = $config->{lastfm}{username};

    my @tracks;
    my $page        = 1;
    my $total_pages = 1;

    while ($page <= $total_pages) {
        my $url = "https://ws.audioscrobbler.com/2.0/"
                . "?method=user.getlovedtracks"
                . "&user=$username"
                . "&api_key=$api_key"
                . "&format=json"
                . "&limit=200"
                . "&page=$page";

        my $response = $ua->get($url);
        die "Last.fm API error: " . $response->status_line()
            unless $response->is_success();

        my $data = decode_json($response->content());

        $total_pages = $data->{lovedtracks}{'@attr'}{totalPages};
        my $total    = $data->{lovedtracks}{'@attr'}{total};

        print "Page $page of $total_pages ($total total tracks)\n";

        for my $track (@{ $data->{lovedtracks}{track} }) {
            push @tracks, {
                artist => $track->{artist}{name},
                title  => $track->{name},
            };
        }

        $page++;
    }

    return @tracks;
}

sub get_spotify_token {
    my ($config, $token_cache) = @_;

    if (-f $token_cache) {
        open my $fh, '<', $token_cache or die "Cannot read token cache: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        my $token_data = decode_json($json);

        if ($token_data->{expires_at} > time() + 60) {
            print "Using cached Spotify token.\n";
            return $token_data->{access_token};
        }

        if ($token_data->{refresh_token}) {
            print "Refreshing Spotify token...\n";
            return refresh_spotify_token($config, $token_data->{refresh_token}, $token_cache);
        }
    }

    return do_spotify_oauth($config, $token_cache);
}

sub do_spotify_oauth {
    my ($config, $token_cache) = @_;

    my $client_id    = $config->{spotify}{client_id};
    my $redirect_uri = $config->{spotify}{redirect_uri};
    my $scope        = 'user-library-read';

    my $auth_url = "https://accounts.spotify.com/authorize"
                 . "?client_id=$client_id"
                 . "&response_type=code"
                 . "&redirect_uri=$redirect_uri"
                 . "&scope=$scope";

    print "Opening Spotify authorization in browser...\n";
    print "If it doesn't open automatically, visit:\n$auth_url\n\n";
    system('open', $auth_url);

    my $code = capture_oauth_callback();
    die "No authorization code received" unless $code;

    return exchange_code_for_token($config, $code, $token_cache);
}

sub capture_oauth_callback {
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 8888,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Cannot start callback server on port 8888: $!";

    print "Waiting for Spotify authorization callback...\n";

    my $client  = $server->accept();
    my $request = '';
    while (my $line = <$client>) {
        $request .= $line;
        last if $line =~ /^\r?\n$/;
    }

    my ($code) = $request =~ /GET \/callback\?code=([^\s&]+)/;

    print $client "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    print $client "<html><body><h1>Authorization successful! You can close this tab.</h1></body></html>\r\n";

    close $client;
    close $server;

    return $code;
}

sub exchange_code_for_token {
    my ($config, $code, $token_cache) = @_;

    my $client_id     = $config->{spotify}{client_id};
    my $client_secret = $config->{spotify}{client_secret};
    my $redirect_uri  = $config->{spotify}{redirect_uri};
    my $credentials   = encode_base64("$client_id:$client_secret", '');

    my $response = $ua->post(
        'https://accounts.spotify.com/api/token',
        Authorization => "Basic $credentials",
        Content => [
            grant_type   => 'authorization_code',
            code         => $code,
            redirect_uri => $redirect_uri,
        ],
    );

    die "Token exchange failed: " . $response->status_line()
        unless $response->is_success();

    my $token_data = decode_json($response->content());
    save_token($token_data, $token_cache);

    return $token_data->{access_token};
}

sub refresh_spotify_token {
    my ($config, $refresh_token, $token_cache) = @_;

    my $client_id     = $config->{spotify}{client_id};
    my $client_secret = $config->{spotify}{client_secret};
    my $credentials   = encode_base64("$client_id:$client_secret", '');

    my $response = $ua->post(
        'https://accounts.spotify.com/api/token',
        Authorization => "Basic $credentials",
        Content => [
            grant_type    => 'refresh_token',
            refresh_token => $refresh_token,
        ],
    );

    die "Token refresh failed: " . $response->status_line()
        unless $response->is_success();

    my $token_data = decode_json($response->content());
    $token_data->{refresh_token} //= $refresh_token;
    save_token($token_data, $token_cache);

    return $token_data->{access_token};
}

sub save_token {
    my ($token_data, $token_cache) = @_;

    $token_data->{expires_at} = time() + $token_data->{expires_in};
    open my $fh, '>', $token_cache or die "Cannot write token cache: $!";
    print $fh encode_json($token_data);
    close $fh;
}

sub fetch_spotify_tracks {
    my ($ua, $access_token) = @_;

    my @tracks;
    my $url = 'https://api.spotify.com/v1/me/tracks?limit=50';

    while ($url) {
        my $response = $ua->get(
            $url,
            Authorization => "Bearer $access_token",
        );

        die "Spotify API error: " . $response->status_line()
            unless $response->is_success();

        my $data = decode_json($response->content());

        my $from = scalar(@tracks) + 1;
        my $to   = scalar(@tracks) + scalar(@{ $data->{items} });
        print "Fetching tracks $from - $to of $data->{total}\n";

        for my $item (@{ $data->{items} }) {
            my $track = $item->{track};
            push @tracks, {
                artist => $track->{artists}[0]{name},
                title  => $track->{name},
            };
        }

        $url = $data->{next};
    }

    return @tracks;
}
