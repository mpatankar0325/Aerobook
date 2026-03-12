//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//
//


// zlib — used by JeppesenImportTemplate for raw-deflate XLSX decompression.
// inflateInit2() with windowBits=-15 is the only correct way to decompress
// XLSX ZIP entries on iOS (COMPRESSION_ZLIB and NSData.decompressed both
// require a zlib header that XLSX files do not have).
#include <zlib.h>
