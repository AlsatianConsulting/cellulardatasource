/* config.h.  Generated from config.h.in by configure.  */
/* config.h.in.  Generated from configure.ac by autoheader.  */

/* Define if building universal (internal helper macro) */
/* #undef AC_APPLE_UNIVERSAL_BUILD */

/* backtrace stack support */
#define BACKWARD_HAS_BACKTRACE 0

/* backtrace stack support */
#define BACKWARD_HAS_BACKTRACE_SYMBOL 1

/* libbfd for stack printing */
/* #undef BACKWARD_HAS_BFD */

/* libdl for stack printing */
/* #undef BACKWARD_HAS_DW */

/* unwind stack support */
#define BACKWARD_HAS_UNWIND 1

/* system binary directory */
#define BIN_LOC "/usr/local/bin"

/* system data directory */
#define DATA_LOC "/usr/local/share"

/* Named mutex debugging */
#define DEBUG_MUTEX_NAME 1

/* disabled by configure arguments */
/* #undef DISABLE_BACKWARD */

/* Remove mutex deadlock timeout protection */
/* #undef DISABLE_MUTEX_TIMEOUT */

/* gcc version */
#define GCC_VERSION_MAJOR 11

/* gcc version */
#define GCC_VERSION_MINOR 0

/* gcc version */
#define GCC_VERSION_PATCH 0

/* Define to 1 if you have the <bfd.h> header file. */
/* #undef HAVE_BFD_H */

/* BSD radiotap packet headers */
/* #undef HAVE_BSD_SYS_RADIOTAP */

/* Define to 1 if you have the <btbb.h> header file. */
/* #undef HAVE_BTBB_H */

/* kernel capability support */
#undef HAVE_CAPABILITY

/* CPP17 parallel functions work */
/* #undef HAVE_CPP17_PARALLEL */

/* cpp11 available */
#define HAVE_CXX11 1

/* cpp14 available */
#define HAVE_CXX14 1

/* cpp17 available */
#define HAVE_CXX17 1

/* cpp20 available */
#define HAVE_CXX20 1

/* Define to 1 if you have the <dwarf.h> header file. */
/* #undef HAVE_DWARF_H */

/* Define to 1 if you have the <elfutils/libdwfl.h> header file. */
/* #undef HAVE_ELFUTILS_LIBDWFL_H */

/* Define to 1 if you have the <elfutils/libdw.h> header file. */
/* #undef HAVE_ELFUTILS_LIBDW_H */

/* Define to 1 if you have the <execinfo.h> header file. */
#define HAVE_EXECINFO_H 1

/* GPS support will be built. */
#define HAVE_GPS 1

/* inttypes.h is present */
#define HAVE_INTTYPES_H 1

/* libbladerf */
/* #undef HAVE_LIBBLADERF */

/* Define to 1 if you have the `cap' library (-lcap). */
#define HAVE_LIBCAP 1

/* libmosquitto */
#define HAVE_LIBMOSQUITTO 1

/* libnl netlink library */
/* #undef HAVE_LIBNL */

/* libnl netlink library */
/* #undef HAVE_LIBNL10 */

/* libnl-2.0 netlink library */
/* #undef HAVE_LIBNL20 */

/* libnl-3.0 netlink library */
/* #undef HAVE_LIBNL30 */

/* libnl-2.0 netlink library */
/* #undef HAVE_LIBNLTINY */

/* libnltiny headers present */
/* #undef HAVE_LIBNLTINY_HEADERS */

/* NetworkManager interface library */
/* #undef HAVE_LIBNM */

/* libpcap packet capture lib */
#define HAVE_LIBPCAP 1

/* libpcre1 regex support */
/* #undef HAVE_LIBPCRE */

/* libpcre2 regex support */
#define HAVE_LIBPCRE2 1

/* librtlsdr bias-tee support */
#define HAVE_LIBRTLSDR_BIAS_T 1

/* librtlsdr bias-tee-gpio support */
#define HAVE_LIBRTLSDR_BIAS_T_GPIO 1

/* libsqlite3 database support */
#define HAVE_LIBSQLITE3 1

/* libubertooth has ubertooth_count */
/* #undef HAVE_LIBUBERTOOTH_UBERTOOTH_COUNT */

/* Define to 1 if you have the <libutil.h> header file. */
/* #undef HAVE_LIBUTIL_H */

/* libwebsockets */
#undef HAVE_LIBWEBSOCKETS

/* Linux wireless iwfreq.flag */
#define HAVE_LINUX_IWFREQFLAG 1

/* Netlink works */
/* #undef HAVE_LINUX_NETLINK */

/* Linux wireless extentions present */
#define HAVE_LINUX_WIRELESS 1

/* local radiotap packet headers */
#define HAVE_LOCAL_RADIOTAP 1

/* openssl library present */
#define HAVE_OPENSSL 1

/* pcap/pcap.h */
/* #undef HAVE_PCAPPCAP_H */

/* libpcap header */
/* #undef HAVE_PCAP_H */

/* System has pipe2 */
#define HAVE_PIPE2 1

/* google protobufs */
/* #undef HAVE_PROTOBUF_CPP */

/* Define to 1 if you have the `pstat' function. */
/* #undef HAVE_PSTAT */

/* have pthread timelock */
#define HAVE_PTHREAD_TIMELOCK 1

/* Define to 1 if you have the <sensors/sensors.h> header file. */
#define HAVE_SENSORS_SENSORS_H 1

/* Define to 1 if you have the `setproctitle' function. */
/* #undef HAVE_SETPROCTITLE */

/* accept() takes type socklen_t for addrlen */
#define HAVE_SOCKLEN_T 1

/* stdint.h is present */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdio.h> header file. */
#define HAVE_STDIO_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the <sys/pstat.h> header file. */
/* #undef HAVE_SYS_PSTAT_H */

/* Define to 1 if you have the <sys/stat.h> header file. */
#define HAVE_SYS_STAT_H 1

/* Define to 1 if you have the <sys/types.h> header file. */
#define HAVE_SYS_TYPES_H 1

/* Define to 1 if you have the <ubertooth.h> header file. */
/* #undef HAVE_UBERTOOTH_H */

/* ubertooth.h in ubertooth dir */
/* #undef HAVE_UBERTOOTH_UBERTOOTH_H */

/* Define to 1 if you have the <unistd.h> header file. */
#define HAVE_UNISTD_H 1

/* Define to 1 if you have the <unwind.h> header file. */
#define HAVE_UNWIND_H 1

/* __PROGNAME glibc macro available */
#define HAVE___PROGNAME 1

/* system library directory */
#define LIB_LOC "/usr/local/lib"

/* system state directory */
#define LOCALSTATE_DIR "/usr/local/var"

/* we need to shim isnan */
/* #undef MISSING_STD_ISNAN */

/* we need to shim std snprintf */
/* #undef MISSING_STD_SNPRINTF */

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT ""

/* Define to the full name of this package. */
#define PACKAGE_NAME ""

/* Define to the full name and version of this package. */
#define PACKAGE_STRING ""

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME ""

/* Define to the home page for this package. */
#define PACKAGE_URL ""

/* Define to the version of this package. */
#define PACKAGE_VERSION ""

/* writeable argv type */
#define PF_ARGV_TYPE PF_ARGV_WRITEABLE

/* Define to 1 if all of the C90 standard headers exist (not just the ones
   required in a freestanding environment). This macro is provided for
   backward compatibility; new code need not use it. */
#define STDC_HEADERS 1

/* strerror_r return type */
#define STRERROR_R_T char *

/* system config directory */
#define SYSCONF_LOC "/usr/local/etc"

/* Compiling for OSX/Darwin */
/* #undef SYS_DARWIN */

/* Compiling for FreeBSD */
/* #undef SYS_FREEBSD */

/* Compiling for Linux OS */
#define SYS_LINUX 1

/* Compiling for NetBSD */
/* #undef SYS_NETBSD */

/* Compiling for OpenBSD */
/* #undef SYS_OPENBSD */

/* Do not enforce runtime type safety */
#define TE_TYPE_SAFETY 0

/* Define WORDS_BIGENDIAN to 1 if your processor stores words with the most
   significant byte first (like Motorola and SPARC, unlike Intel). */
#if defined AC_APPLE_UNIVERSAL_BUILD
# if defined __BIG_ENDIAN__
#  define WORDS_BIGENDIAN 1
# endif
#else
# ifndef WORDS_BIGENDIAN
/* #  undef WORDS_BIGENDIAN */
# endif
#endif

/* Number of bits in a file offset, on hosts where this is settable. */
/* #undef _FILE_OFFSET_BITS */

/* Define for large files, on AIX-style hosts. */
/* #undef _LARGE_FILES */
/* proftpd argv stuff */
#define PF_ARGV_NONE        0
#define PF_ARGV_NEW     	1
#define PF_ARGV_WRITEABLE   2
#define PF_ARGV_PSTAT       3
#define PF_ARGV_PSSTRINGS   4

/* Maximum number of characters in the status line */
#define STATUS_MAX 1024

/* Stupid ncurses */
#define NCURSES_NOMACROS

/* Number of hex pairs in a key */
#define WEPKEY_MAX 32

/* String length of a key */
#define WEPKEYSTR_MAX ((WEPKEY_MAX * 2) + WEPKEY_MAX)

/* system min isn't reliable */
#define kismin(x,y) ((x) < (y) ? (x) : (y))
#define kismax(x,y) ((x) > (y) ? (x) : (y))

/* Timer slices per second */
#define SERVER_TIMESLICES_SEC 10

/* Max chars in SSID */
#define MAX_SSID_LEN    255

#ifndef _
#define _(x) x
#endif

/* asio global defs */
#define ASIO_HAS_STD_CHRONO
#define ASIO_HAS_MOVE
