#!/usr/bin/env perl
#
# Copyright (c) 2009-2015 Cisco Systems, Inc.  All rights reserved.
# Copyright (c) 2010      Oracle and/or its affiliates.  All rights reserved.
# Copyright (c) 2013      Mellanox Technologies, Inc.
#                         All rights reserved.
# Copyright (c) 2013-2016 Intel, Inc.  All rights reserved.
# Copyright (c) 2015      Research Organization for Information Science
#                         and Technology (RIST). All rights reserved.
# Copyright (c) 2015      IBM Corporation.  All rights reserved.
#
# $COPYRIGHT$
#
# Additional copyrights may follow
#
# $HEADER$
#

use strict;

use Cwd;
use File::Basename;
use File::Find;
use Data::Dumper;
use Getopt::Long;

#
# Global variables
#

# Sentinel file to remove if we fail
my $sentinel;

# The m4 file we'll write at the end
my $m4_output_file = "config/autogen_found_items.m4";
my $m4;
# Sanity check file
my $topdir_file = "include/pmix.h";
my $dnl_line = "dnl ---------------------------------------------------------------------------";

# Data structures to fill up with all the stuff we find
my $mca_found;
my @subdirs;

# Command line parameters
my $quiet_arg = 0;
my $debug_arg = 0;
my $help_arg = 0;
my $include_arg = 0;
my $exclude_arg = 0;
my $force_arg = 0;

# Include/exclude lists
my $include_list;
my $exclude_list;

# Minimum versions
my $ompi_automake_version = "1.12.2";
my $ompi_autoconf_version = "2.69";
my $ompi_libtool_version = "2.4.2";

# Search paths
my $ompi_autoconf_search = "autoconf";
my $ompi_automake_search = "automake";
my $ompi_libtoolize_search = "libtoolize;glibtoolize";

# One-time setup
my $username;
my $hostname;
my $full_hostname;

$username = getpwuid($>);
$full_hostname = `hostname`;
chomp($full_hostname);
$hostname = $full_hostname;
$hostname =~ s/^([\w\-]+)\..+/\1/;

##############################################################################

sub my_die {
    unlink($sentinel)
        if ($sentinel);
    die @_;
}

sub my_exit {
    my ($ret) = @_;
    unlink($sentinel)
        if ($sentinel && $ret != 0);
    exit($ret);
}

##############################################################################

sub verbose {
    print @_
        if (!$quiet_arg);
}

sub debug {
    print @_
        if ($debug_arg);
}

sub debug_dump {
    my $d = new Data::Dumper([@_]);
    $d->Purity(1)->Indent(1);
    debug $d->Dump;
}

##############################################################################

# Process a "subdir", meaning that the directory isn't a component or
# an extension; it probably just needs an autoreconf, autogen, etc.
sub process_subdir {
    my ($dir) = @_;

    # Chdir to the subdir
    print "\n=== Processing subdir: $dir\n";
    my $start = Cwd::cwd();
    chdir($dir);

    # Run an action depending on what we find in that subdir
    if (-x "autogen.pl") {
        print "--- Found autogen.pl; running...\n";
        safe_system("./autogen.pl");
    } elsif (-x "autogen.sh") {
        print "--- Found autogen.sh; running...\n";
        safe_system("./autogen.sh");
    } elsif (-f "configure.in" || -f "configure.ac") {
        print "--- Found configure.in|ac; running autoreconf...\n";
        safe_system("autoreconf -ivf");
        print "--- Patching autotools output... :-(\n";
    } else {
        my_die "Found subdir, but no autogen.sh or configure.in|ac to do anything";
    }

    # Ensure that we got a good configure executable.
    my_die "Did not generate a \"configure\" executable in $dir.\n"
        if (! -x "configure");

    # Fix known issues in Autotools output
    patch_autotools_output($start);

    # Chdir back to where we came from
    chdir($start);
}

##############################################################################

sub mca_process_component {
    my ($topdir, $project, $framework, $component) = @_;

    my $pname = $project->{name};
    my $pdir = $project->{dir};
    my $cdir = "$topdir/$pdir/mca/$framework/$component";

    return
        if (! -d $cdir);

    # Process this directory (pretty much the same treatment as for
    # mpiext, so it's in a sub).
    my $found_component;

    # Does this directory have a configure.m4 file?
    if (-f "$cdir/configure.m4") {
        $found_component->{"configure.m4"} = 1;
        verbose "    Found configure.m4 file\n";
    }

    $found_component = {
        name => $component,
        framework_name => $framework,
        project_name => $pname,
        project_dir => $pdir,
        abs_dir => $cdir,
    };

    # Push the results onto the $mca_found hash array
    push(@{$mca_found->{$pname}->{$framework}->{"components"}},
         $found_component);

}

##############################################################################

sub ignored {
    my ($dir) = @_;

    # If this directory does not have .pmix_ignore, or if it has a
    # .pmix_unignore that has my username in it, then add it to the
    # list of components.
    my $ignored = 0;

    if (-f "$dir/.pmix_ignore") {
        $ignored = 1;
    }
    if (-f "$dir/.pmix_unignore") {
        open(UNIGNORE, "$dir/.pmix_unignore") ||
            my_die "Can't open $dir/.pmix_unignore file";
        my $unignore;
        $unignore .= $_
            while (<UNIGNORE>);
        close(UNIGNORE);

        $ignored = 0
            if ($unignore =~ /^$username$/m ||
                $unignore =~ /^$username\@$hostname$/m ||
                $unignore =~ /^$username\@$full_hostname$/m);
    }

    return $ignored;
}

##############################################################################

sub mca_process_framework {
    my ($topdir, $project, $framework) = @_;

    my $pname = $project->{name};
    my $pdir = $project->{dir};

    # Does this framework have a configure.m4 file?
    my $dir = "$topdir/$pdir/mca/$framework";
    if (-f "$dir/configure.m4") {
        $mca_found->{$pname}->{$framework}->{"configure.m4"} = 1;
        verbose "    Found framework configure.m4 file\n";
    }

    # Did we exclude all components for this framework?
    if (exists($exclude_list->{$framework}) &&
        $exclude_list->{$framework}[0] eq "AGEN_EXCLUDE_ALL") {
        verbose "    => Excluded\n";
    } else {
        # Look for component directories in this framework
        if (-d $dir) {
            $mca_found->{$pname}->{$framework}->{found} = 1;
            opendir(DIR, $dir) ||
                my_die "Can't open $dir directory";
            foreach my $d (readdir(DIR)) {
                # Skip any non-directory, "base", or any dir that
                # begins with "."
                next
                    if (! -d "$dir/$d" || $d eq "base" ||
                        substr($d, 0, 1) eq ".");

                # Skip any component that doesn't have a configure.m4
                # or Makefile.am as we couldn't build it anyway
                if (! -f "$dir/$d/configure.m4" &&
                    ! -f "$dir/$d/Makefile.am" &&
                    ! -f "$dir/$d/configure.ac" &&
                    ! -f "$dir/$d/configure.in") {
                     verbose "    => No sentinel file found in $dir/$d -> Excluded\n";
                     next;
                }

                verbose "--- Found $pname / $framework / $d component: $pdir/mca/$framework/$d\n";

                # Skip if specifically excluded
                if (exists($exclude_list->{$framework}) &&
                    $exclude_list->{$framework}[0] eq $d) {
                    verbose "    => Excluded\n";
                    next;
                }

                # Skip if the framework is on the include list, but
                # doesn't contain this component
                if (exists($include_list->{$framework})) {
                    my $tst = 0;
                    foreach my $ck (@{$include_list->{$framework}}) {
                        if ($ck ne $d) {
                            verbose "    => Not included\n";
                            $tst = 1;
                            last;
                        }
                    }
                    if ($tst) {
                        next;
                    }
                }

                # Check ignore status
                if (ignored("$dir/$d")) {
                    verbose "    => Ignored (found .pmix_ignore file)\n";
                } else {
                    mca_process_component($topdir, $project, $framework, $d);
                }
            }
        }
        closedir(DIR);
    }
}

##############################################################################

sub mca_generate_framework_header(\$\@) {
    my ($project, @frameworks) = @_;
    my $framework_array_output="";
    my $framework_decl_output="";

    foreach my $framework (@frameworks) {
        # There is no common framework object
        if ($framework ne "common") {
            my $framework_name = "${project}_${framework}_base_framework";
            $framework_array_output .= "    &$framework_name,\n";
            $framework_decl_output .= "extern mca_base_framework_t $framework_name;\n";
        }
    }

    my $ifdef_string = uc "${project}_FRAMEWORKS_H";
    open(FRAMEWORKS_OUT, ">$project/include/$project/frameworks.h");
    printf FRAMEWORKS_OUT "%s", "/*
 * This file is autogenerated by autogen.pl. Do not edit this file by hand.
 */
#ifndef $ifdef_string
#define $ifdef_string

#include <pmix/mca/base/mca_base_framework.h>

$framework_decl_output
static mca_base_framework_t *${project}_frameworks[] = {
$framework_array_output    NULL
};

#endif /* $ifdef_string */\n\n";
    close(FRAMEWORKS_OUT);
}

##############################################################################

sub mca_process_project {
    my ($topdir, $project) = @_;

    my $pname = $project->{name};
    my $pdir = $project->{dir};

    # Does this project have a configure.m4 file?
    if (-f "$topdir/$pdir/configure.m4") {
        $mca_found->{$pname}->{"configure.m4"} = 1;
        verbose "    Found $topdir/$pdir/configure.m4 file\n";
    }

    # Look for framework directories in this project
    my $dir = "$topdir/$pdir/mca";
    if (-d $dir) {
        opendir(DIR, $dir) ||
            my_die "Can't open $dir directory";
        my @my_dirs = readdir(DIR);
        @my_dirs = sort(@my_dirs);

        foreach my $d (@my_dirs) {
            # Skip any non-directory, "base", or any dir that begins with "."
            next
                if (! -d "$dir/$d" || $d eq "base" || substr($d, 0, 1) eq ".");

            # If this directory has a $dir.h file and a base/
            # subdirectory, or its name is "common", then it's a
            # framework.
            if ("common" eq $d || !$project->{need_base} ||
                (-f "$dir/$d/$d.h" && -d "$dir/$d/base")) {
                verbose "\n=== Found $pname / $d framework: $pdir/mca/$d\n";
                mca_process_framework($topdir, $project, $d);
            }
        }
        closedir(DIR);
    }
}

##############################################################################

sub mca_run_global {
    my ($projects) = @_;

    # For each project, go find a list of frameworks, and for each of
    # those, go find a list of components.
    my $topdir = Cwd::cwd();
    foreach my $p (@$projects) {
        if (-d "$topdir/$p->{dir}") {
            verbose "\n*** Found $p->{name} project\n";
            mca_process_project($topdir, $p);
        }
    }

    # Debugging output
    debug_dump($mca_found);

    # Save (just) the list of MCA projects in the m4 file
    my $str;
    foreach my $p (@$projects) {
        my $pname = $p->{name};
        # Check if this project is an MCA project (contains MCA framework)
        if (exists($mca_found->{$pname})) {
            $str .= "$p->{name}, $p->{dir}, ";
        }
    }
    $str =~ s/, $//;
    $m4 .= "\ndnl List of MCA projects found by autogen.pl
m4_define([mca_project_list], [$str])\n";
    #-----------------------------------------------------------------------

    $m4 .= "\n$dnl_line
$dnl_line
$dnl_line

dnl MCA information\n";

    # Array for all the m4_includes that we'll need to pick up the
    # configure.m4's.
    my @includes;

    # Next, for each project, write the list of frameworks
    foreach my $p (@$projects) {

        my $pname = $p->{name};
        my $pdir = $p->{dir};

        if (exists($mca_found->{$pname})) {
            my $frameworks_comma;

            # Does this project have a configure.m4 file?
            push(@includes, "$pdir/configure.m4")
                if (exists($mca_found->{$p}->{"configure.m4"}));

            # Print out project-level info
            my @mykeys = keys(%{$mca_found->{$pname}});
            @mykeys = sort(@mykeys);

            # Ensure that the "common" framework is listed first
            # (if it exists)
            my @tmp;
            push(@tmp, "common")
                if (grep(/common/, @mykeys));
            foreach my $f (@mykeys) {
                push(@tmp, $f)
                    if ($f ne "common");
            }
            @mykeys = @tmp;

            foreach my $f (@mykeys) {
                $frameworks_comma .= ", $f";

                # Does this framework have a configure.m4 file?
                push(@includes, "$pdir/mca/$f/configure.m4")
                    if (exists($mca_found->{$pname}->{$f}->{"configure.m4"}));

                # This framework does have a Makefile.am (or at least,
                # it should!)
                my_die "Missing $pdir/mca/$f/Makefile.am"
                    if (! -f "$pdir/mca/$f/Makefile.am");
            }
            $frameworks_comma =~ s/^, //;

            &mca_generate_framework_header($pname, @mykeys);

            $m4 .= "$dnl_line

dnl Frameworks in the $pname project and their corresponding directories
m4_define([mca_${pname}_framework_list], [$frameworks_comma])

";

            # Print out framework-level info
            foreach my $f (@mykeys) {
                my $components;
                my $m4_config_component_list;
                my $no_config_component_list;

                # Troll through each of the found components
                foreach my $comp (@{$mca_found->{$pname}->{$f}->{components}}) {
                    my $c = $comp->{name};
                    $components .= "$c ";

                    # Does this component have a configure.m4 file?
                    if (exists($comp->{"configure.m4"})) {
                        push(@includes, "$pdir/mca/$f/$c/configure.m4");
                        $m4_config_component_list .= ", $c";
                    } else {
                        $no_config_component_list .= ", $c";
                    }
                }
                $m4_config_component_list =~ s/^, //;
                $no_config_component_list =~ s/^, //;

                $m4 .= "dnl Components in the $pname / $f framework
m4_define([mca_${pname}_${f}_m4_config_component_list], [$m4_config_component_list])
m4_define([mca_${pname}_${f}_no_config_component_list], [$no_config_component_list])

";
            }
        }
    }

    # List out all the m4_include
    $m4 .= "$dnl_line

dnl List of configure.m4 files to include\n";
    foreach my $i (@includes) {
        $m4 .= "m4_include([$i])\n";
    }
}


##############################################################################
# Find and remove stale files

sub find_and_delete {
    foreach my $file (@_) {
        my $removed = 0;
        if (-f $file) {
            unlink($file);
            $removed = 1;
        }
        if (-f "config/$file") {
            unlink("config/$file");
            $removed = 1;
        }
        debug "    Removed stale copy of $file\n"
            if ($removed);
    }
}

##############################################################################
# Find a specific executable and ensure that it is a recent enough
# version.

sub find_and_check {
    my ($app, $app_name, $req_version) = @_;

    my @search_path = split(/;/, $app_name);
    my @min_version = split(/\./, $req_version);
    my @versions_found = ();

    foreach (@search_path) {
        verbose "   Searching for $_\n";
        my $version = `$_ --version`;
        if (!defined($version)) {
            verbose "  $_ not found\n";
            next;
        }

	# Matches a version string with 1 or more parts possibly prefixed with a letter (ex:
	# v2.2) or followed by a letter (ex: 2.2.6b). This regex assumes there is a space
	# before the version string and that the version is ok if there is no version.
	if (!($version =~ m/\s[vV]?(\d[\d\.]*\w?)/m)) {
	    verbose "  WARNING: $_ does not appear to support --version. Assuming it is ok\n";

	    return;
	}

	$version = $1;

        verbose "     Found $_ version $version; checking version...\n";
        push(@versions_found, $version);

        my @parts = split(/\./, $version);
        my $i = 0;
        # Check every component of the version number
        while ($i <= $#min_version) {
            verbose "       Found version component $parts[$i] -- need $min_version[$i]\n";

            # Check to see if there are any characters (!) in the
            # version number (e.g., Libtool's "2.2.6b" -- #%@#$%!!!).
            # Do separate comparisons between the number and any
            # trailing digits.  You can't just "lt" compare the whole
            # string because "10 lt 2b" will return true.  #@$@#$#@$
            # Libtool!!
            $parts[$i] =~ m/(\d+)([a-z]*)/i;
            my $pn = $1;
            my $pa = $2;
            $min_version[$i] =~ m/(\d+)([a-z]*)/i;
            my $mn = $1;
            my $ma = $2;

            # If the version is higher, we're done.
            if ($pn > $mn) {
                verbose "     ==> ACCEPTED\n";
                return;
            }
            # If the version is lower, we're done.
            elsif ($pn < $mn ||
                ($pn == $mn && $pa lt $ma)) {
                verbose "     ==> Too low!  Skipping this version\n";
                last;
            }

            # If the version was equal, keep checking.
            ++$i;
        }

        # If we found a good version, return.
        if ($i > $#min_version) {
            verbose "     ==> ACCEPTED\n";
            return;
        }
    }

    # if no acceptable version found, reject it
    print "
=================================================================
I could not find a recent enough copy of $app.
I need at least $req_version, but only found the following versions:\n\n";

    my $i = 0;
    foreach (@search_path) {
        print "    $_: $versions_found[$i]\n";
        $i++;
    }

    print "\nI am gonna abort.  :-(

Please make sure you are using at least the following versions of the
tools:

    GNU Autoconf: $ompi_autoconf_version
    GNU Automake: $ompi_automake_version
    GNU Libtool: $ompi_libtool_version
=================================================================\n";
    my_exit(1);
}

##############################################################################

sub safe_system {
    print "Running: " . join(/ /, @_) . "\n";
    my $ret = system(@_);
    $ret >>= 8;
    if (0 != $ret) {
        print "Command failed: @_\n";
        my_exit($ret);
    }
    $ret;
}

##############################################################################

sub in_tarball {
    my $tarball = 0;
    open(IN, "VERSION") || my_die "Can't open VERSION";
    # If repo_rev is not an empty string, we are in a tarball
    while (<IN>) {
          my $line = $_;
          my @fields = split(/=/,$line);
          if ($fields[0] eq "repo_rev") {
              if ($fields[1] ne "\n") {
                  $tarball = 1;
                  last;
              }
          }
    }
    close(IN);
    return $tarball;
}

##############################################################################
##############################################################################
## main - do the real work...
##############################################################################
##############################################################################

# Command line parameters

my $ok = Getopt::Long::GetOptions("quiet|q" => \$quiet_arg,
                                  "debug|d" => \$debug_arg,
                                  "help|h" => \$help_arg,
                                  "include=s" => \$include_arg,
                                  "exclude=s" => \$exclude_arg,
                                  "force|f" => \$force_arg,
    );

if (!$ok || $help_arg) {
    print "Invalid command line argument.\n\n"
        if (!$ok);
    print "Options:
  --quiet | -q                  Do not display normal verbose output
  --debug | -d                  Output lots of debug information
  --help | -h                   This help list
  --include | -i                Comma-separated list of framework-component pairs
                                to be exclusively built - i.e., all other components
                                will be ignored and only those specified will be marked
                                to build
  --exclude | -e                Comma-separated list of framework or framework-component
                                to be excluded from the build
  --force | -f                  Run even if invoked from the source tree of an expanded
                                distribution tarball\n";
    my_exit($ok ? 0 : 1);
}

#---------------------------------------------------------------------------

# Check for project existence
my $project_name_long = "PMIx";
my $project_name_short = "PMIx";

#---------------------------------------------------------------------------

$full_hostname = `hostname`;
chomp($full_hostname);

$m4 = "dnl
dnl \$HEADER\$
dnl
$dnl_line
dnl This file is automatically created by autogen.pl; it should not
dnl be edited by hand!!
dnl
dnl Generated by $username at " . localtime(time) . "
dnl on $full_hostname.
$dnl_line\n\n";

#---------------------------------------------------------------------------

# Verify that we're in the PMIx root directorty by checking for a token file.

my_die "Not at the root directory of an PMIx source tree"
    if (! -f "config/pmix_mca.m4");

my_die "autogen.pl has been invoked in the source tree of a PMIx distribution tarball; aborting...
You likely do not need to invoke \"autogen.pl\" -- you can probably run \"configure\" directly.
If you really know what you are doing, and really need to run autogen.pl, use the \"--force\" flag."
    if (!$force_arg && in_tarball());

# Now that we've verified that we're in the top-level OMPI directory,
# set the sentinel file to remove if we abort.
$sentinel = Cwd::cwd() . "/configure";

#---------------------------------------------------------------------------

my $step = 1;
verbose "PMIx autogen (buckle up!)

$step. Checking tool versions\n\n";

# Check the autotools revision levels
&find_and_check("autoconf", $ompi_autoconf_search, $ompi_autoconf_version);
&find_and_check("libtool", $ompi_libtoolize_search, $ompi_libtool_version);
&find_and_check("automake", $ompi_automake_search, $ompi_automake_version);

#---------------------------------------------------------------------------

# No platform file -- write an empty list
$m4 .= "m4_define([autogen_platform_file], [])\n\n";

if ($exclude_arg) {
    debug "Using exclude list: $exclude_arg";
    my @list = split(/,/, $exclude_arg);
    foreach (@list) {
        my @pairs = split(/-/, $_);
        if (exists($pairs[1])) {
        # Remove any trailing newlines
            chomp($pairs[1]);
            debug "    Adding ".$pairs[0]."->".$pairs[1]." to exclude list\n";
            push(@{$exclude_list->{$pairs[0]}}, $pairs[1]);
        } else {
            debug "    Adding $pairs[0] to exclude list\n";
            push(@{$exclude_list->{$pairs[0]}}, "AGEN_EXCLUDE_ALL");
        }
    }
}
if ($include_arg) {
    debug "Using include list: $include_arg";
    my @list = split(/,/, $include_arg);
    foreach (@list) {
        my @pairs = split(/-/, $_);
        if (exists($pairs[1])) {
        # Remove any trailing newlines
            chomp($pairs[1]);
            debug "    Adding ".$pairs[0]."->".$pairs[1]." to include list\n";
            push(@{$include_list->{$pairs[0]}}, $pairs[1]);
        }
        # NOTE: it makes no sense to include all as that is the default
        # so ignore that scenario here, if given
    }
}

#---------------------------------------------------------------------------

# Find projects, frameworks, components
++$step;
verbose "\n$step. Searching for projects, MCA frameworks, and MCA components\n";

my $ret;

# Figure out if we're at the top level of the PMIx tree or not.
if (! (-f "VERSION" && -f "configure.ac" && -f $topdir_file)) {
    print("\n\nYou must run this script from the top-level directory of the PMIx tree.\n\n");
    my_exit(1);
}

# Top-level projects to examine
my $projects;
push(@{$projects}, { name => "pmix", dir => "src", need_base => 1 });

$m4 .= "dnl Separate m4 define for each project\n";
foreach my $p (@$projects) {
    $m4 .= "m4_define([project_$p->{name}], [1])\n";
}

$m4 .= "\ndnl Project names
m4_define([project_name_long], [$project_name_long])
m4_define([project_name_short], [$project_name_short])\n";

# Setup MCA
debug_dump($projects);
mca_run_global($projects);

#---------------------------------------------------------------------------

# Process all subdirs that we found in previous steps
++$step;
verbose "\n$step. Processing autogen.subdirs directories\n";

if ($#subdirs >= 0) {
    foreach my $d (@subdirs) {
        process_subdir($d);
    }
} else {
    print "<none found>\n";
}

#---------------------------------------------------------------------------

# If we got here, all was good.  Run the auto tools.
++$step;
verbose "\n$step. Running autotools on top-level tree\n\n";

# Remove old versions of the files (this is probably overkill, but...)
verbose "==> Remove stale files\n";
find_and_delete(qw/config.guess config.sub depcomp compile install-sh ltconfig
    ltmain.sh missing mkinstalldirs libtool/);

# Remove the old m4 file and write the new one
verbose "==> Writing m4 file with autogen.pl results\n";
unlink($m4_output_file);
open(M4, ">$m4_output_file") ||
    my_die "Can't open $m4_output_file";
print M4 $m4;
close(M4);

# Run autoreconf
verbose "==> Running autoreconf\n";
my $cmd = "autoreconf -ivf --warnings=all,no-obsolete,no-override -I config";
safe_system($cmd);

#---------------------------------------------------------------------------

verbose "
================================================
PMIx autogen: completed successfully.  w00t!
================================================\n\n";

# Done!
exit(0);
