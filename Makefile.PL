################################################################################
#
#   File name: Makefile.PL
#   Project: Cache::Mmap
#   Description: Makefile creator
#
#   Author: Peter Haworth
#   Date created: 28/06/2000
#
#   sccs version: 1.2    last changed: 07/12/00
#
#   Copyright Institute of Physics Publishing 2000
#   You may distribute under the terms of the GPL or the Artistic License,
#   as distributed with Perl, with the exception that it cannot be placed
#   on a CD-ROM or similar media for commercial distribution without the
#   prior approval of the author.
#
################################################################################

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME => 'Cache::Mmap',
  VERSION_FROM => 'Mmap.pm',
  PREREQ_PM => {
    Fcntl => 0,
    Carp => 0,
    Mmap => '0.10',
    Storable => 0,
  },
  dist => {
    COMPRESS => 'gzip -9f',
    SUFFIX => 'gz',
    DIST_DEFAULT => 'all tardist',
  },
  $ExtUtils::MakeMaker::VERSION >= 5.4301 ? (
    ABSTRACT => "Shared cache using mmap'd file",
    AUTHOR => 'Peter Haworth (pmh@edison.ioppublishing.com)',
  ) : (),
);

