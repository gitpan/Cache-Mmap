################################################################################
#
#   File name: Mmap.pm
#   Project: Cache::Mmap
#   Description: Shared mmap cache
#
#   Author: Peter Haworth
#   Date created: 28/06/2000
#
#   $Id: Mmap.pm,v 1.9 2003/06/17 18:39:14 pmh Exp $
#
#   Copyright Institute of Physics Publishing 2002
#   You may distribute under the terms of the GPL or the Artistic License,
#   as distributed with Perl
#
################################################################################

package Cache::Mmap;

use constant has_utf8 => $^V ge "\5\6\0";
use DynaLoader();
use Storable qw(freeze thaw);
use Fcntl;
use Symbol();
use IO::Seekable qw(SEEK_SET SEEK_END);
use Carp qw(croak);
use integer;
use strict;
use vars qw(
  $VERSION @ISA
);

$VERSION='0.07';
@ISA=qw(DynaLoader);

__PACKAGE__->bootstrap($VERSION);

# Default cache options
my %def_options=(
  buckets => 13,	# Number of buckets
  bucketsize => 1024,	# Size of each bucket
  pagesize => 1024,	# Bucket alignment
  strings => 0,		# Store strings, rather than refs
  expiry => 0,		# Number of seconds to hold values, 0==forever
#  context => undef,	# Context to pass to read and write subs
  permissions => 0600,	# Permissions for new file creation
# read => sub called as ($found,$val)/$val=$read->($key,$context)
  cachenegative  => 0,	# true:  Cache not-found values
			# false: Don't cache not-found values
# write => sub called as $write->($key,$oval,$context)
			# Leave out for no writing to underlying data
  writethrough => 1,	# true:  Write when value is added to cache
			# false: Write when value expires or is pushed out
# delete => sub called as $delete->($key,$oval,$context)
			# Leave out for no deleting of underlying data
);

# Bit positions for cache-level flags
use constant flag_strings => 0x0001;
# Names for cache-level flags
my %bool_opts=(
  strings => flag_strings,
);

# Bit positions for element flags
use constant elem_dirty => 0x0001;

use constant magic => 0x15ACACE;# Cache file magic number
use constant filevers => 1;	# File format version number supported


my $headsize=4*10;  # File: magic, buckets, bucketsize, pagesize, flags,
		    #       file format version
my $bheadsize=4*10; # Bucket: filled
my $eheadsize=4*10; # Element: size, time, klen, vlen, flags
my $maxheadsize=$headsize > $bheadsize ? $headsize : $bheadsize;
$maxheadsize=$eheadsize if $eheadsize > $maxheadsize;

################################################################################
# Class method: new($filename,\%options)
# Description: Open a shared cache file, creating it if necessary
#	THIS ROUTINE DIES ON FAILURE
# Author: Peter Haworth
sub new{
  my($class,$filename,$options)=@_;
  my $self={
    %def_options,
    %{$options || {}},
  };

  # Check options for sensible values
  foreach(qw(buckets bucketsize pagesize permissions)){
    $self->{$_}=~/^[1-9]\d*$/s
      or croak "'$_' option for $class must be a positive integer";
  }
  $self->{pagesize}>=$maxheadsize
    or croak "'pagesize' options for $class must be at least $maxheadsize";
  foreach(qw(read write delete)){
    !$self->{$_} || ref $self->{$_} eq 'CODE'
      or croak "'$_' option for $class must be a CODE ref or empty";
  }

  # Align bucketsize
  {
    no integer;
    my $n_pages=$self->{bucketsize}/$self->{pagesize};
    if((my $i_pages=int $n_pages)!=$n_pages){
      $self->{bucketsize}=($i_pages+1)*$self->{pagesize};
    }
  }

  # Try to open a file
  my $fh=Symbol::gensym;
  sysopen($fh,$filename,O_RDWR|O_CREAT,$self->{permissions})
    or croak "Can't open cache file $filename: $!";
  
  # Create cache object
  bless $self,$class;
  $self->{_filename}=$filename;
  $self->{_fh}=$fh;

  # Set options
  $self->_set_options;

  $self;
}

################################################################################
# Internal method: _set_options()
# Description: Set options for a new cache, or read existing options
#	THIS ROUTINE DIES ON FAILURE
# Author: Peter Haworth
sub _set_options{
  my($self)=@_;

  # Lock file, so only one process sets the size
  $self->_lock(0)
    or croak "Can't lock cache file: $!";
  
  my $err;
  eval{
    local $SIG{__DIE__};

    # If the file is big enough to contain a header, attempt to read one
    my $size_cur= -s $self->{_fh};
    my $magic_ok;
    if($size_cur>=$headsize){
      my $head;
      if((my $bytes=sysread($self->{_fh},$head,$headsize))!=$headsize){
	croak "Expecting $headsize bytes, read $bytes from cache header\n";
      }
      my($mg,$buckets,$bucketsize,$pagesize,$flags,$format)=unpack('l6',$head);
      $mg==magic
        or croak "$self->{_filename} is not a Cache::Mmap file";
      ($format+=0)==filevers
        or croak "$self->{_filename} uses v$format data structures. Cache::Mmap $VERSION only supports v".filevers." data structures";

      $self->{buckets}=$buckets;
      $self->{bucketsize}=$bucketsize;
      $self->{pagesize}=$pagesize;
      while(my($opt,$bit)=each %bool_opts){
	$self->{$opt}=!!($flags&$bit);
      }
      $magic_ok=1;
    }

    # Make sure the file is big enough for the whole cache
    my $size=$self->{pagesize}+$self->{buckets}*$self->{bucketsize};
    if($size_cur < $size){
      my $pad="\0" x 1024;
      sysseek $self->{_fh},SEEK_END,0
	or croak "Can't seek to end of file: $!\n";
      while($size_cur < $size){
	my $len=syswrite($self->{_fh},$pad,1024)
	  or croak "Can't pad file: $!";
	$size_cur+=$len;
      }
      -s $self->{_fh} >= $size
	or croak "Failed to set correct file size\n";
    }

    # Write file header if it's not already done
    if(!$magic_ok){
      my $flags=0;
      while(my($opt,$bit)=each %bool_opts){
	$flags|=$bit if $self->{$opt};
      }
      my $head=pack("l6x$headsize",
	magic,@$self{'buckets','bucketsize','pagesize'},$flags,filevers
      );
      sysseek $self->{_fh},SEEK_SET,0
	or croak "Can't seek to beginning: $!";
      syswrite($self->{_fh},$head,$headsize)==$headsize
	or croak "Can't write file header: $!";
    }

    mmap($self->{_mmap}='',$size,$self->{_fh})
      or do{
	delete $self->{_mmap};
	croak "Can't mmap $self->{_filename}: $!";
      };

    1;
  } or $err=1;

  # Unlock file before returning
  $self->_unlock;

  # Return success or die
  die $@ if $err;
}

################################################################################
# Method: quick_clear()
# Description: Clear the entire cache, without writing dirty entries
# Author: Peter Haworth
sub quick_clear{
  my($self)=@_;

  $self->_lock(0)
    or croak "Can't lock cache file: $!";
  
  my $err;
  eval{
    local $SIG{__DIE__};

    my $buckets=$self->buckets;
    my $bucketsize=$self->bucketsize;
    my $pagesize=$self->pagesize;
    my $empty="\0" x $bucketsize;

    for(0..$buckets-1){
      substr($self->{_mmap},$pagesize+$bucketsize*$_,$bucketsize)=$empty;
    }

    1;
  } or $err=1;

  $self->_unlock;

  die $@ if $err;
}

################################################################################
# Destructor
# Description: unmap and close the file
# Author: Peter Haworth
sub DESTROY{
  my($self)=@_;

  munmap($self->{_mmap}) if exists $self->{_mmap};
  close $self->{_fh};
}

################################################################################
# Method: buckets()
# Description: Return the number of buckets the cache has
# Author: Peter Haworth
sub buckets{
  my($self)=@_;

  $self->{buckets};
}

################################################################################
# Method: bucketsize()
# Description: Return the bucket size of the cache
# Author: Peter Haworth
sub bucketsize{
  my($self)=@_;

  $self->{bucketsize};
}

################################################################################
# Method: pagesize()
# Description: Return the page size of the cache
# Author: Peter Haworth
sub pagesize{
  my($self)=@_;

  $self->{pagesize};
}

################################################################################
# Method: strings()
# Description: Return true if the cache stores strings, rather than refs
# Author: Peter Haworth
sub strings{
  my($self)=@_;

  $self->{strings};
}

################################################################################
# Method: expiry()
# Description: Return the number of seconds values are cached for
# Author: Peter Haworth
sub expiry{
  my($self)=@_;

  $self->{expiry};
}

################################################################################
# Method: writethrough()
# Description: Return true if writes go directly to the underlying data
# Author: Peter Haworth
sub writethrough{
  my($self)=@_;

  $self->{writethrough};
}

################################################################################
# Method: cachenegative()
# Description: Return true if not-found values are cached
# Author: Peter Haworth
sub cachenegative{
  my($self)=@_;

  $self->{cachenegative};
}

################################################################################
# Method: context([$context])
# Description: Get or set the read/write context
# Author: Peter Haworth
sub context{
  my $self=shift;

  @_ ? ($self->{context}=$_[0]) : $self->{context};
}

################################################################################
# Internal method: _lock($offset)
# Description: Lock the cache file.
#	If $offset is zero, lock the file header
#	Otherwise, lock the bucket starting at $offset
# XXX This also needs to create an internal lock if threading
# Author: Peter Haworth
sub _lock{
  my($self,$offset)=@_;
  my $length=$offset ? $self->{bucketsize} : $headsize;

  _lock_xs($self->{_fh},$offset,$length,1);
}

################################################################################
# Internal method: _unlock()
# Description: Remove all locks from the file
# XXX This needs to unlock internal lock and take an offset arg if threading
# Author: Peter Haworth
sub _unlock{
  my($self)=@_;

  _lock_xs($self->{_fh},0,0,0);
}

################################################################################
# Method: entries([$details])
# Description: Return a list of keys stored in the cache
#	Returns hashrefs with extra info if $details is true, values if 2
#	Note that since the cache could be shared, this list may not match
#		the cache contents by the time it is used
# Author: Peter Haworth
sub entries{
  my($self,$details)=@_;
  $details=defined($details) && $details+0;

  my $buckets=$self->buckets;
  my $bucketsize=$self->bucketsize;
  my $pagesize=$self->pagesize;
  my $expiry=$self->expiry;

  my @entries;
  for(0..$buckets-1){
    my $bucket=$pagesize+$bucketsize*$_;
    $self->_lock($bucket);

    my $err;
    eval{
      local $SIG{__DIE__};

      my($filled)=unpack 'l',substr($self->{_mmap},$bucket,$bheadsize);
      my $off=$bucket+$bheadsize;
      my $end=$off+$filled;
      my $size;
      while($off<$end){
	($size,my($time,$klen,$vlen,$flags))
	  =unpack 'l5',substr $self->{_mmap},$off,$eheadsize;
	if(!$size){
	  my $part=substr($self->{_mmap},$off,$end-$off);
	  $part=~s/\\/\\\\/g;
	  $part=~s/([^\040-\176])/sprintf '\\%02x',ord $1/ge;
	  die "Zero-sized entry in $self->{_filename}, offset $off! Remaining bucket contents: $part";
	}
	next if $expiry && time()-$time > $expiry;

	my $key=$self->_decode(substr($self->{_mmap},$off+$eheadsize,$klen),1);
        if($details){
	  push @entries,{
	    key => $key,
	    'time' => $time,
	    dirty => $flags & elem_dirty,
	    $details>1 ? (
	      value => $self->_decode(
		substr($self->{_mmap},$off+$eheadsize+$klen,$vlen),0
	      ),
	    ) : (),
	  };
	}else{
	  push @entries,$key;
	}
      }continue{
	$off+=$size;
      }
	  
      1;
    } or $err=1;
    $self->_unlock;

    die $@ if $err;
  }

  @entries;
}

################################################################################
# Method: read($key)
# Description: Read data from the cache (or from the underlying data)
# Returns: wantarray ? ($found,$val) : $val
# Author: Peter Haworth
sub read{
  my($self,$key)=@_;
  my $bucket=$self->_bucket($key);
  my $ekey=$self->_encode($key,1);

  # Lock the bucket. This is a write lock, even for reading, since we may
  # move items within the bucket
  $self->_lock($bucket);

  my($found,$val,$err);
  eval{
    local $SIG{__DIE__};

    ($found,my($expired,$poff,$off,$size,$klen,$vlen,$flags))
      =$self->_find($bucket,$key);
    if($found){{
      # Remove expired item, and pretend we didn't find it
      # XXX What about dirty expired items???
      if($expired && !($flags & elem_dirty)){
	# No need to write underlying data, because it's not dirty
	my $b_end=$bucket+$self->{bucketsize};
	substr($self->{_mmap},$off,$b_end-$off)
	  =substr($self->{_mmap},$off+$size,$b_end-$off-$size).("\0" x $size);
	my($filled)=unpack 'l',substr($self->{_mmap},$bucket,$bheadsize);
	$filled-=$size;
	substr($self->{_mmap},$bucket,$bheadsize)
	  =substr(pack("lx$bheadsize",$filled),0,$bheadsize);
	$found=0;
	last;
      }
      # Swap with previous item unless at head of bucket
      if($poff){
	my $psize=$off-$poff;
	substr($self->{_mmap},$poff,$psize+$size)
	  =substr($self->{_mmap},$off,$size)
	  .substr($self->{_mmap},$poff,$psize);
	$off=$poff;
      }
      $val=$self->_decode(substr($self->{_mmap},$off+$eheadsize+$klen,$vlen),0);
    }}
    if(!$found){
      my @_read=$self->{read}
	? $self->{read}->($key,$self->{context}) : ();
      ($found,$val)=@_read==1 ? (defined($_read[0]),$_read[0]) : @_read;

      # Store value in cache
      if($found || $self->{cachenegative}){
	my $eval=$self->_encode($val,0);

	$self->_insert($bucket,$ekey,$eval,0);
      }
    }

    1;
  } or $err=1;
  $self->_unlock;

  # Propagate errors
  die $@ if $err;

  return ($found,$val);
}

################################################################################
# Method: write($key,$val)
# Description: Write the specified item into the cache (and underlying data)
# Returns: $val
# Author: Peter Haworth
sub write{
  my($self,$key,$val)=@_;
  my $ekey=$self->_encode($key,1);
  my $klen=length $ekey;
  my $eval=$self->_encode($val,0);
  my $vlen=length $eval;
  my $size=$eheadsize+$klen+$vlen;
  my $bsize=$self->{bucketsize}-$bheadsize;

  if($size<=$bsize){
    # The item will fit in a cache bucket, so store it
    my $bucket=$self->_bucket($key);
    $self->_lock($bucket);
    my $err;
    eval{
      local $SIG{__DIE__};
      my($found,$expired,$poff,$off,$_size,$_klen,$_vlen,$flags)
	=$self->_find($bucket,$key);

      # Remove the old version
      if($found){
	my($filled)=unpack 'l',substr($self->{_mmap},$bucket,$bheadsize);
	my $pre=substr $self->{_mmap},
	    $bucket+$bheadsize,$off-($bucket+$bheadsize);
	my $post=substr $self->{_mmap},
	    $off+$_size,$bucket+$bheadsize+$filled-$off-$_size;
        my $new_filled=length($pre.$post);
	my $bhead=substr(pack("lx$bheadsize",$new_filled),0,$bheadsize);

	substr($self->{_mmap},$bucket,$bheadsize+$new_filled)
	  =$bhead.$pre.$post;
      }

      # Generate new bucket contents
      $self->_insert($bucket,$ekey,$eval,1);

      # Write to underlying data
      if($self->{writethrough} and my $write=$self->{write}){
	$write->($key,$val,$self->{context});
      }

      1;
    } or $err=1;
    $self->_unlock;
    die $@ if $err;
  }elsif(my $wsub=$self->{write}){
    # It won't fit in a cache bucket, but we can update the underlying data
    $self->delete($key);
    $wsub->($key,$val,$self->{context});
  }else{
    # It won't fit, and we can't update the data
    # XXX Should we blow up here?
    # Probably not, since an item may be removed from the cache at any time
  }

  1;
}

################################################################################
# Internal Method: _insert($bucket,$ekey,$eval,$write)
# Description: Insert the key/value pair into the bucket
#	$write is true if this is a cache write
# Author: Peter Haworth
sub _insert{
  my($self,$bucket,$ekey,$eval,$write)=@_;
  my $klen=length $ekey;
  my $vlen=length $eval;
  my $size=$eheadsize+$klen+$vlen;
  my $bsize=$self->{bucketsize}-$bheadsize;
  return if $size>$bsize;

  my $ehead=substr(pack("l5x$eheadsize",
    $size,time(),$klen,$vlen,($write && !$self->{writethrough} && elem_dirty),
  ),0,$eheadsize);
  my($filled)=unpack 'l',substr($self->{_mmap},$bucket,4);
  my $content=$ehead.$ekey.$eval
    .substr($self->{_mmap},$bucket+$bheadsize,$filled);
  $filled=length $content;

  # Trim down to fit into bucket
  if($filled > $bsize){
    # Find all items which fit in the bucket
    my $poff=my $off=$size;
    while($off<=$bsize){
      $poff=$off;
      last if $poff>=$filled;
      my($size)=unpack 'l',substr($content,$off,4);
      $off+=$size;
    }

    # Write remaining items back to underlying data if dirty
    if(my $wsub=$self->{write} && !$self->{writethrough}){
      for($off=$poff;$off<$filled;){
	my($size,$time,$vlen,$klen,$flags)
	  =unpack 'l5',substr($content,$off,$eheadsize);
	if(!$size){
	  my $part=substr($content,$off,length($content)-$off);
	  my $off=$bucket+$off;
	  $part=~s/\\/\\\\/g;
	  $part=~s/([^\040-\176])/sprintf '\\%02x',ord $1/ge;
	  die "Zero-size entry in $self->{_filename}, offset $off! [ekey=$ekey] Remaining bucket contents: $part";
	  return;
	}
	if($flags & elem_dirty){
	  my $key=$self->_decode(substr($content,$off+$eheadsize,$klen),1);
	  my $val=$self->_decode(
	    substr($content,$off+$eheadsize+$klen,$vlen),0);
	  $wsub->($key,$val,$self->{content});
	}
	$off+=$size;
      }
    }

    # Remove dead items
    $filled=$poff;
    substr($content,$filled)=''; # Chop off the end of the string
  }

  # Write the bucket
  my $bhead=substr(pack("lx$bheadsize",$filled),0,$bheadsize);
  substr($self->{_mmap},$bucket,$bheadsize+$filled)=$bhead.$content;
}

################################################################################
# Method: delete($key)
# Description: Delete the specified item from the cache
# Returns: wantarray ? ($found,$val) : $val
# Author: Peter Haworth
sub delete{
  my($self,$key)=@_;
  my $bucket=$self->_bucket($key);

  # Lock the bucket
  $self->_lock($bucket);

  my($found,$val,$err);
  eval{
    local $SIG{__DIE__};

    ($found,my($expired,$poff,$off,$size,$klen,$vlen,$flags))
      =$self->_find($bucket,$key);
    
    if($found){
      $val=$self->_decode(substr($self->{_mmap},$off+$eheadsize+$klen,$vlen),0);
      if(my $dsub=$self->{delete} and !($flags & elem_dirty)){
	$dsub->($key,$val,$self->{context});
      }
      my($filled)=unpack 'l',substr($self->{_mmap},$bucket,$bheadsize);
      my $new_filled=$filled-$size;
      substr($self->{_mmap},$bucket,$bheadsize)
	=substr(pack("lx$bheadsize",$new_filled),0,$bheadsize);

      my $fill_end=$bucket+$bheadsize+$filled;
      my $elem_end=$off+$size;
      substr($self->{_mmap},$off,$fill_end-$elem_end)
        =substr($self->{_mmap},$elem_end,$fill_end-$elem_end);
    }

    1;
  } or $err=1;
  $self->_unlock;

  # Propagate errors
  die $@ if $err;

  return ($found,$val);
}

################################################################################
# Internal method: _bucket($key)
# Description: Return the offset of the bucket which would hold $key
# Author: Peter Haworth
sub _bucket{
  my($self,$key)=@_;

  my $hash=0;
  while($key=~/(.)/gs){
    $hash*=33;
    $hash+=ord $1;
  }

  my $bucket=do{ no integer; $hash % $self->{buckets}; };
  return $self->{pagesize}+$bucket*$self->{bucketsize};
}

################################################################################
# Internal method: _find($bucket,$key)
# Description: Locate the item keyed by $key in the bucket starting at $bucket
# Returns: ($found,$expired,$poff,$off,$size,$klen,$vlen,$flags)
sub _find{
  my($self,$bucket,$key)=@_;
#  my $_klen=length $key;
  my($filled)=unpack 'l',substr($self->{_mmap},$bucket,$bheadsize);
  my $off=$bucket+$bheadsize;
  my $end=$off+$filled;
  my $b_end=$bucket+$self->bucketsize;

  my($found,$size,$time,$klen,$vlen,$flags,$poff);
  while($off<$end){
    if($off>=$b_end){
      die "Super-sized entry in $self->{_filename}, offset $poff! [size=$size, finding key=$key]";
    }
    ($size,$time,$klen,$vlen,$flags)
      =unpack 'l5',substr $self->{_mmap},$off,$eheadsize;
    if(!$size){
      my $part=substr($self->{_mmap},$off,$end-$off);
      $part=~s/\\/\\\\/g;
      $part=~s/([^\040-\176])/sprintf '\\%02x',ord $1/ge;
      my $prev;
      if($poff){
	$prev=" [poff=$poff]";
      }
      die "Zero-sized entry in $self->{_filename}, offset $off! [bucket=$bucket][key=$key]$prev Remaining bucket contents: $part";
    }
    if($self->_decode(substr($self->{_mmap},$off+$eheadsize,$klen),1) eq $key){
      $found=1;
      last;
    }
    $poff=$off;
    $off+=$size;
  }

  return unless $found;

  my $expired;
  if(my $exp=$self->expiry){
    $expired=time-$time>$exp;
  }

  return ($found,$expired,$poff,$off,$size,$klen,$vlen,$flags);
}
    
################################################################################
# Internal method: _encode($value,$is_key)
# Description: Encodes the given value into a string
# Author: Peter Haworth
sub _encode{
  my($self,$value,$is_key)=@_;

  if(!defined $value){
    return '';
  }elsif($self->{strings} || $is_key){
    if(has_utf8){
      my $eval=pack 'a*',$value;
      if($eval eq $value){
        return " $eval";
      }else{
        return "U$eval";
      }
    }else{
      return " $value";
    }
  }else{
    return ' '.freeze($value);
  }
}

################################################################################
# Internal method: _decode($value,$is_key)
# Description: Decodes the given string value
# Author: Peter Haworth
sub _decode{
  my($self,$value,$is_key)=@_;

  if($value eq ''){
    return undef;
  }else{
    $value=~s/^(.)//s;
    my $code=$1;
    if($code eq 'U'){
      if(has_utf8){
        utf8::decode($value);
	return $value;
      }else{
        croak "UTF8 encoded value in $self->{_filename} detected\n";
      }
    }elsif($self->{strings} || $is_key){
      return $value;
    }else{
      return thaw($value);
    }
  }
}



################################################################################
# Return true to require
1;


__END__

=head1 NAME

Cache::Mmap - Shared data cache using memory mapped files

=head1 SYNOPSIS

  use Cache::Mmap;

  $cache=Cache::Mmap->new($filename,\%options);

  $val1=$cache->read($key1);
  $cache->write($key2,$val2);
  $cache->delete($key3);

=head1 DESCRIPTION

This module implements a shared data cache, using memory mapped files.
If routines are provided which interact with the underlying data, access to
the cache is completely transparent, and the module handles all the details of
refreshing cache contents, and updating underlying data, if necessary.

Cache entries are assigned to "buckets" within the cache file, depending on
the key. Within each bucket, entries are stored apporximately in order of last
access, so that frequently accessed entries will move to the head of the
bucket, thus decreasing access time. Concurrent accesses to the same bucket are
prevented by file locking of the relevent section of the cache file.

=head1 METHODS

=over 4

=item Cache::Mmap->new($filename,\%options)

Creates a new cache object. If the file named by C<$filename> does not already
exist, it will be created.  Various options may be set in C<%options>, which
affect the behaviour of the cache (defaults in parentheses):

=over 8

=item permissions (0600)

Sets the file permissions for the cache file if it doesn't already exist.

=item buckets (13)

Sets the number of buckets inside the cache file. A larger number of buckets
will give better performance for a cache with many accesses, as there will be
less chance of concurrent access to the same bucket.

=item bucketsize (1024)

Sets the size of each bucket, in bytes. A larger bucket size will be needed to
store large cache entries. If the bucketsize is not large enough to hold a
particular entry, it will still be passed between the underlying data and the
application in its entirety, but will not be stored in the cache.

=item pagesize (1024)

Sets the alignment of buckets within the file. The file header will be extended
to this size, and bucket sizes will be rounded up to the nearest multiple.
Choosing a pagesize equal to the virtual memory page size of the host system
should improve performance.

=item strings (0)

If true, cache entries are treated as strings, rather than references. This
will help performance for string-only caches, as no time will be taken to
serialize cache entries.

=item expiry (0)

If non-zero, sets the length of time, in seconds, which cache entries are
considered valid. A new entry will be fetched from the underlying data if
an expired cache entry would otherwise have been returned.

=item context (undef)

This value is passed to the read/write/delete routines below, to provide
context. This will typically be a database handle, used to fetch data from.

=item read (undef)

Provides a code reference to a routine which will fetch entries from the
underlying data. Called as C<$read-E<gt>($key,$context)>, this routine should
return a list C<($found,$value)>, where C<$found> is true if the entry could
be found in the underlying data, and C<$value> is the value to cache, or
C<undef> if not found. If this routine is not provided, only values already
in the cache will ever be returned.

=item cachenegative (0)

If true, even unsuccessful fetches from the underlying data are cached. This
can be useful to only search the underlying data once for each required key.

=item write (undef)

Provides a code reference to a routine which will write cache entries into the
underlying data. This routine will be called after C<$cache-E<gt>write()> is
called, to synchronise the underlying data with the cache. Called as
C<$write-E<gt>($key,$val,$context)>. If the routine is not provided, the
underlying data will not be synchronised after cache writes.

=item writethrough (1)

If true, the C<write> routine above will be called as soon as
C<$cache-E<gt>write()> is called. This provides immediate synchronisation of
underlying data and cache contents.

If false, the C<write> routine will
be called for each cache entry which no longer fits in its bucket after a
cache read or write. This provides a write-as-necessary behaviour, which may
be more efficient than the writethrough behaviour. However, only data fetched
through the cache will reflect these changes.

=item delete (undef)

Provides a code reference to a routine which will delete items from the
underlying data. This routine will be called after C<$cache->delete()> is
called, to synchronise the underlying data with the cache. Called as
C<$cache-E<gt>delete($key,$cval,$context)>, where C<$cval> is the value
currently stored in the cache. If this routine is not provided, entries
deleted from the cache have no effect on the underlying data.

=back

An alternative to supplying a C<write> routine, is to call
C<$cache-E<gt>delete()> after updating the underlying data. Note however, that
in the case of databases, this should be done after committing the update, so
that a concurrent process doesn't reload the cache between being the entry
being deleted, and the database updates being committed.

=item $cache->buckets()

Returns the number of buckets in the cache file. Note that this may be
different to the number passed to C<new()>, since an existing cache file may
have been created with different options.

=item $cache->bucketsize()

Returns the size of buckets in the cache file. May be different to C<new()>
parameter.

=item $cache->pagesize()

Returns the page size of the cache file. May be different to C<new()> parameter.

=item $cache->strings()

Returns true if the cache stores strings rather than references. May be
different to C<new()> parameter.

=item $cache->expiry()

Returns the time in seconds cache entries are considered valid for, or zero
for indefinite validity. May be different to C<new()> parameter.

=item $cache->writethrough()

Returns true if items written to the cache are immediately written to the
underlying data. May be different to C<new()> parameter.

=item $cache->cachenegative()

Returns true if items not found in the underlying data are cached anyway. May
be different to C<new()> parameter.

=item $cache->context()

Returns the context data for reads and writes to the underlying data.

=item $cache->context($context)

Provides new context data for reads and writes to the underlying data.

=item $cache->read($key)

Reads an entry from the cache, or from the underlying data if not cached.
Returns the value in scalar context, and C<($found,$value)> in list context,
where C<$found> is true if the item was found in either the cache or the
underlying data.

=item $cache->write($key,$val)

Writes an entry into the cache, and depending on C<new()> options, into the
underlying data.

=item $cache->delete($key)

Deletes an entry from the cache, and depending on C<new()> options, from the
underlying data.

=item $cache->entries()

=item $cache->entries(0)

Returns a list of the keys of entries held in the cache. Note that this list
may be immediately out of date, due to the shared nature of the cache. Entries
may be added or removed by other processes between this list being generated
and when it is used.

=item $cache->entries(1)

Returns a list of hashrefs representing entries held in the cache. The
following keys are present in each hashref:

  key    The key used to identify the entry
  time   The time the entry was stored (seconds since the epoch)
  dirty  Whether the entry needs writing to the underlying data

The same caveat applies to the currency of this information as above.

=item $cache->entries(2)

As C<$cache-E<gt>entries(1)>, with the addition of a C<value> element in each
hashref, holding the value stored in the cache entry.

=back

=head1 AUTHOR

Peter Haworth E<lt>pmh@edison.ioppublishing.comE<gt>

