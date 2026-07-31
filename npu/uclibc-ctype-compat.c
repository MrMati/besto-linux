/* SPDX-License-Identifier: MIT
 *
 * Rockchip publishes the RV1103/RV1106 micro runtime (librknnmrt) as a uClibc
 * build only -- there is no glibc .so anywhere in rknn-toolkit2. The archive,
 * however, is almost libc-agnostic: out of everything it imports, exactly two
 * symbols are uClibc-private.
 *
 *   const uint16_t *__ctype_b;        character class mask, one per char
 *   const int16_t  *__ctype_tolower;  lowercase translation, one per char
 *
 * uClibc-ng copied glibc's bit layout for the class mask, so both tables can be
 * rebuilt at load time from glibc's own locale tables. glibc's tolower table is
 * 32 bits wide, hence the narrowing copy. Both are indexed from -128 to 255, so
 * the exported pointers sit 128 entries into the backing storage.
 *
 * Link this into librknnmrt.a with --whole-archive and the result is an
 * ordinary, fully resolved glibc shared library.
 */

#include <ctype.h>
#include <stdint.h>

#define TABLE_LO   128
#define TABLE_LEN  (TABLE_LO + 256)

static uint16_t ctype_b_table[TABLE_LEN];
static int16_t  ctype_tolower_table[TABLE_LEN];

const uint16_t *__ctype_b        = &ctype_b_table[TABLE_LO];
const int16_t  *__ctype_tolower  = &ctype_tolower_table[TABLE_LO];

__attribute__((constructor))
static void rknnmrt_init_uclibc_ctype_tables(void)
{
	const unsigned short *b  = *__ctype_b_loc();
	const int32_t        *tl = *__ctype_tolower_loc();
	int i;

	for (i = -TABLE_LO; i < 256; ++i) {
		ctype_b_table[i + TABLE_LO]       = (uint16_t)b[i];
		ctype_tolower_table[i + TABLE_LO] = (int16_t)tl[i];
	}
}
