/* All the mmap() stuff is copied from Malcolm Beattie's Mmap.pm */
#ifdef __cplusplus
  extern "C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
  }
#endif
#include <sys/mman.h>

#ifndef MMAP_RETTYPE
#  define _POSIX_C_SOURCE 199309
#  ifdef _POSIX_VERSION
#    if _POSIX_VERSION >= 199309
#      define MMAP_RETTYPE void *
#    endif
#  endif
#endif

#ifndef MMAP_RETTYPE
#  define MMAP_RETTYPE caddr_t
#endif

#ifndef MAP_FAILED
#  define MAP_FAILED ((caddr_t)-1)
#endif

/* Required stuff for fcntl locking */
#include <fcntl.h>

/* Stay backwards compatible */
#include "ppport.h"

MODULE = Cache::Mmap		PACKAGE = Cache::Mmap

void
mmap(var,len,fh)
	SV *var
	size_t len
	FILE *fh
	int fd = NO_INIT
	MMAP_RETTYPE addr = NO_INIT
    PROTOTYPE: $$$
    CODE:
	ST(0)=&PL_sv_undef;
	/* XXX Use new perlio stuff to get fd */
	fd=fileno(fh);
	if(fd<0)
	  return;

	addr=mmap(0,len,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
	if(addr==MAP_FAILED)
	  return;

	SvUPGRADE(var,SVt_PV);
	SvPVX(var)=(char*)addr;
	SvCUR_set(var,len);
	SvLEN_set(var,0);
	SvPOK_only(var);
	ST(0)=&PL_sv_yes;

void
munmap(var)
	SV *var
    PROTOTYPE: $
    CODE:
	ST(0)=&PL_sv_undef;
	if(munmap((MMAP_RETTYPE)SvPVX(var),SvCUR(var))==-1)
	  return;

	SvREADONLY_off(var);
	SvPVX(var)=0;
	SvCUR_set(var,0);
	SvLEN_set(var,0);
	SvOK_off(var);
	ST(0)=&PL_sv_yes;

void
_lock_xs(fh,off,len,mode)
	FILE *fh
	off_t off
	size_t len
	int mode
	int fd = NO_INIT
	struct flock fl = NO_INIT
    PROTOTYPE: $$$
    CODE:
	ST(0)=&PL_sv_undef;
	/* XXX Use new perlio stuff to get fd */
	fd=fileno(fh);
	if(fd<0)
	  return;

	fl.l_whence=SEEK_SET;
	fl.l_start=off;
	fl.l_len=len;
	fl.l_type=mode ? F_WRLCK : F_UNLCK;
        if(fcntl(fd,F_SETLKW,&fl)>=0)
	  ST(0)=&PL_sv_yes;

