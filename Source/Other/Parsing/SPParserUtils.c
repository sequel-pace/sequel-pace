//
//  SPParserUtils.c
//  sequel-pro
//
//  Created by Max Lohrmann on 27.01.15.
//  Relocated from existing files. Previous copyright applies.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//
//  More info at <https://github.com/sequelpro/sequelpro>

#include "SPParserUtils.h"
#include <stdint.h>

#define SIZET (sizeof(size_t))
#define SIZET1 (SIZET - 1)
#define SBYTE (SIZET1 * 8)

#define ONEMASK ((size_t)(-1) / 0xFF)
#define ONEMASK8 (ONEMASK * 0x80)
#define FMASK ((size_t)(-1)*(ONEMASK*0xf)-1)

// adapted from http://www.daemonology.net/blog/2008-06-05-faster-utf8-strlen.html
size_t utf8strlen(const char * _s)
{
	
	/* Due to [NSString length] behaviour for chars > 0xFFFF {length = 2}
	 "correct" the variable 'count' by subtraction the number
	 of occurrences of the start byte 0xF0 (4-byte UTF-8 char).
	 Here we assume that only up to 4-byte UTF-8 chars
	 are allowed [latest UTF-8 specification].
	 
	 Marked in the source code by "CORRECT".
	 */
	
	const char * s;
	long count = 0;
	unsigned char b;
	
	
	/* Process all bytes. The original word-at-a-time block read caused an ASAN
	   heap-buffer-overflow when the allocation ended at the null terminator and the
	   aligned word read extended past it (GitHub issue #792). Replaced with a safe
	   byte-by-byte loop that produces identical results. */
	for (s = _s; ; s++) {
		b = *s;

		/* Exit if we hit a zero byte. */
		if (b == '\0')
			goto done;

		/* Is this byte NOT the first byte of a character? */
		count += (b >> 7) & ((~b) >> 6);

		/* CORRECT: adjust for 4-byte UTF-8 sequences which NSString counts as length 2 */
		count -= (b & 0xf0) == 0xf0;
	}
	
done:
	return ((s - _s) - count);
}
