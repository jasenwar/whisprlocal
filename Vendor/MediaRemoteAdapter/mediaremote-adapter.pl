#!/usr/bin/perl

# Adapted from ungive/mediaremote-adapter v0.7.6, used by OpenWhispr.
# The framework is intentionally loaded through Apple's /usr/bin/perl because
# MediaRemote is unavailable to ordinary application processes on modern macOS.

use strict;
use warnings;
use DynaLoader;
use File::Basename;
use File::Spec;

sub fail {
    my ($message) = @_;
    print STDERR "$message\n";
    exit 1;
}

@ARGV == 2 or fail(
    "Usage: mediaremote-adapter.pl FRAMEWORK_PATH "
    . "{state|pause-if-playing|play}"
);

my $framework_path = shift @ARGV;
my $command = shift @ARGV;
$framework_path = File::Spec->rel2abs($framework_path);

my %symbols = (
    "state" => "whisprlocal_media_state",
    "pause-if-playing" => "whisprlocal_media_pause_if_playing",
    "play" => "whisprlocal_media_play",
);

exists $symbols{$command} or fail("Unsupported command: $command");

my $framework_name = File::Basename::basename($framework_path);
$framework_name =~ s/\.framework$//
    or fail("Provided path is not a framework: $framework_path");

my $framework = File::Spec->catfile($framework_path, $framework_name);
-e $framework or fail("Framework executable not found: $framework");

my $handle = DynaLoader::dl_load_file($framework, 0)
    or fail("Failed to load framework: $framework");
my $symbol_name = $symbols{$command};
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name)
    or fail("Symbol '$symbol_name' not found in $framework");

DynaLoader::dl_install_xsub("main::invoke_adapter", $symbol);

eval {
    invoke_adapter();
};
fail("Adapter command failed: $@") if $@;
