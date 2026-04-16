#!/usr/bin/env perl
use strict;
use warnings;
use YAML::Tiny;
use LWP::UserAgent;
use JSON;
use File::Path qw(make_path);

my $config_file  = 'conf/config.yaml';
my $cache_dir    = 'cache';
my $lastfm_cache = "$cache_dir/lastfm.json";

# Load config
my $yaml = YAML::Tiny->read($config_file)
    or die "Cannot read config: " . YAML::Tiny->errstr;
my $config = $yaml->[0];

my $api_key  = $config->{lastfm}{api_key};
my $username = $config->{lastfm}{username};

# Fetch Last.fm loved tracks
print "Fetching Last.fm loved tracks for $username...\n";

my $ua = LWP::UserAgent->new();
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

print "Fetched " . scalar(@tracks) . " loved tracks.\n";

# Write cache
make_path($cache_dir);
open my $fh, '>', $lastfm_cache or die "Cannot write cache: $!";
print $fh encode_json(\@tracks);
close $fh;

print "Cache written to $lastfm_cache\n";
