package package Amiseq::App::Utility::ConfigManager;
 
use strict;

use warnings;
 
use JSON::MaybeXS;

use File::Slurp qw(read_file);

use FindBin;
 
sub new {

    my ($class, $config_file) = @_;
 
    # Save only the file path, nothing else

    my $self = {

        config_file => $config_file || "$FindBin::Bin/MyConfig.json",

    };
 
    return bless $self, $class;

}
 
# ----------------------------

# Method 1 : Config Reader

# ----------------------------

# Reads JSON file

# Converts to hashref

# Returns full config

sub read_config {

    my ($self) = @_;
 
    # Read file contents as text

    my $json_text = read_file($self->{config_file});
 
    # Decode JSON into perl structure

    my $config = decode_json($json_text);
 
    # Return full config

    return $config;

}
 
1;

 