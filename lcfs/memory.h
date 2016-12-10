#ifndef _MEMORY_H
#define _MEMORY_H

/* Type of malloc requests */
enum lc_memTypes {
    LC_MEMTYPE_GFS = 0,
    LC_MEMTYPE_DIRENT = 1,
    LC_MEMTYPE_ICACHE = 2,
    LC_MEMTYPE_INODE = 3,
    LC_MEMTYPE_PCACHE = 4,
    LC_MEMTYPE_ILOCK = 5,
    LC_MEMTYPE_EXTENT = 6,
    LC_MEMTYPE_BLOCK = 7,
    LC_MEMTYPE_PAGE = 8,
    LC_MEMTYPE_DATA = 9,
    LC_MEMTYPE_DPAGEHASH = 10,
    LC_MEMTYPE_HPAGE = 11,
    LC_MEMTYPE_XATTR = 12,
    LC_MEMTYPE_XATTRNAME = 13,
    LC_MEMTYPE_XATTRVALUE = 14,
    LC_MEMTYPE_XATTRBUF = 15,
    LC_MEMTYPE_XATTRINODE = 16,
    LC_MEMTYPE_STATS = 17,
    LC_MEMTYPE_MAX = 18,
};

#endif
