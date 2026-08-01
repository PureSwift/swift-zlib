/* Differential conformance program.
 *
 * Compiled twice — once against the reference libz, once against this library — and the two
 * outputs diffed. Anything that must agree exactly is printed as a value. Anything that is
 * allowed to differ, which is only the size of compressed output, is printed with a SIZE:
 * prefix so the runner can report it as a delta rather than a failure.
 *
 * The point of building it this way is that neither library is trusted to describe itself: the
 * comparison is between what each one actually did, on the same inputs, through the same code.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

/* Deterministic pseudo-random bytes, so both builds see byte-for-byte the same corpus without
 * either needing a seed file. xorshift32. */
static void fill_pseudo_random(unsigned char *buf, size_t len, unsigned int state) {
    for (size_t i = 0; i < len; i++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        buf[i] = (unsigned char)state;
    }
}

struct corpus {
    const char *name;
    unsigned char *data;
    size_t len;
};

static void checksums(const struct corpus *c) {
    printf("adler32      %-12s %08lx\n", c->name, adler32(1, c->data, (uInt)c->len));
    printf("adler32_z    %-12s %08lx\n", c->name, adler32_z(1, c->data, c->len));
    printf("crc32        %-12s %08lx\n", c->name, crc32(0, c->data, (uInt)c->len));
    printf("crc32_z      %-12s %08lx\n", c->name, crc32_z(0, c->data, c->len));

    /* Running values: feeding the same bytes in two pieces must reach the same answer as one,
     * which is what every caller streaming a file depends on. */
    if (c->len >= 4) {
        size_t half = c->len / 2;
        uLong a = adler32(1, c->data, (uInt)half);
        a = adler32(a, c->data + half, (uInt)(c->len - half));
        printf("adler32 split%-12s %08lx\n", c->name, a);

        uLong r = crc32(0, c->data, (uInt)half);
        r = crc32(r, c->data + half, (uInt)(c->len - half));
        printf("crc32 split  %-12s %08lx\n", c->name, r);

        /* And combining, which reaches the same place without having the bytes. */
        uLong a1 = adler32(1, c->data, (uInt)half);
        uLong a2 = adler32(1, c->data + half, (uInt)(c->len - half));
        printf("adler32_comb %-12s %08lx\n", c->name,
               adler32_combine(a1, a2, (z_off_t)(c->len - half)));

        uLong r1 = crc32(0, c->data, (uInt)half);
        uLong r2 = crc32(0, c->data + half, (uInt)(c->len - half));
        printf("crc32_comb   %-12s %08lx\n", c->name,
               crc32_combine(r1, r2, (z_off_t)(c->len - half)));

        uLong op = crc32_combine_gen((z_off_t)(c->len - half));
        printf("crc32_gen+op %-12s %08lx %08lx\n", c->name, op,
               crc32_combine_op(r1, r2, op));
    }
}

static void roundtrip(const struct corpus *c, int level) {
    uLong bound = compressBound((uLong)c->len);
    unsigned char *packed = malloc(bound ? bound : 1);
    unsigned char *back = malloc(c->len ? c->len : 1);

    if (!packed || !back) {
        printf("ALLOC FAILED %s\n", c->name);
        exit(1);
    }

    uLong packed_len = bound;
    int rc = compress2(packed, &packed_len, c->data, (uLong)c->len, level);
    printf("compress2 rc %-12s L%d %d\n", c->name, level, rc);

    if (rc == Z_OK) {
        /* The bound is a promise to the caller; breaking it overruns a buffer they sized. */
        printf("within bound %-12s L%d %d\n", c->name, level, packed_len <= bound);
        printf("SIZE: %-12s L%d %lu (bound %lu)\n", c->name, level, packed_len, bound);

        uLong back_len = (uLong)c->len;
        int rc2 = uncompress(back, &back_len, packed, packed_len);
        printf("uncompress rc%-12s L%d %d\n", c->name, level, rc2);
        printf("recovered    %-12s L%d %lu %08lx\n", c->name, level, back_len,
               back_len ? crc32(0, back, (uInt)back_len) : 0);
        printf("identical    %-12s L%d %d\n", c->name, level,
               back_len == c->len && memcmp(back, c->data, c->len) == 0);
    }

    free(packed);
    free(back);
}

/* The error paths a caller actually hits: too small a buffer, and garbage input. */
static void error_paths(void) {
    unsigned char src[256];
    fill_pseudo_random(src, sizeof src, 0x1234);

    unsigned char tiny[4];
    uLong tiny_len = sizeof tiny;
    printf("compress tiny dest %d\n", compress(tiny, &tiny_len, src, sizeof src));

    unsigned char out[512];
    uLong out_len = sizeof out;
    printf("uncompress garbage %d\n", uncompress(out, &out_len, src, sizeof src));

    /* A truncated but otherwise valid stream: the data is not wrong, there is just not
     * enough of it, and the two are different answers. */
    unsigned char packed[512];
    uLong packed_len = sizeof packed;
    if (compress(packed, &packed_len, src, sizeof src) == Z_OK && packed_len > 6) {
        out_len = sizeof out;
        printf("uncompress truncated %d\n",
               uncompress(out, &out_len, packed, packed_len - 3));
    }

    printf("compressBound 0 %lu\n", compressBound(0));
    printf("compressBound 1 %lu\n", compressBound(1));
    printf("compressBound 1k %lu\n", compressBound(1024));
    printf("compressBound 1M %lu\n", compressBound(1048576));
    printf("compressBound 1G %lu\n", compressBound(1073741824UL));
}

int main(void) {
    printf("zlibVersion %s\n", zlibVersion());
    printf("zlibCompileFlags %lx\n", zlibCompileFlags());

    for (int e = 2; e >= -6; e--) {
        printf("zError %d %s\n", e, zError(e));
    }

    static unsigned char empty[1];
    static unsigned char one[1] = { 'x' };
    static unsigned char text[] =
        "The quick brown fox jumps over the lazy dog. "
        "The quick brown fox jumps over the lazy dog. "
        "The quick brown fox jumps over the lazy dog.";

    size_t random_len = 200000;
    unsigned char *random_bytes = malloc(random_len);
    fill_pseudo_random(random_bytes, random_len, 0x2545F491);

    size_t zeros_len = 300000;
    unsigned char *zeros = calloc(zeros_len, 1);

    size_t repeat_len = 90000;
    unsigned char *repeats = malloc(repeat_len);
    for (size_t i = 0; i < repeat_len; i++) {
        repeats[i] = (unsigned char)("abcabcabcdef"[i % 12]);
    }

    struct corpus corpora[] = {
        { "empty", empty, 0 },
        { "one", one, 1 },
        { "text", text, sizeof text - 1 },
        { "random", random_bytes, random_len },
        { "zeros", zeros, zeros_len },
        { "repeats", repeats, repeat_len },
    };

    for (size_t i = 0; i < sizeof corpora / sizeof corpora[0]; i++) {
        checksums(&corpora[i]);

        int levels[] = { 0, 1, 6, 9, -1 };
        for (size_t l = 0; l < sizeof levels / sizeof levels[0]; l++) {
            roundtrip(&corpora[i], levels[l]);
        }
    }

    error_paths();

    free(random_bytes);
    free(zeros);
    free(repeats);
    return 0;
}
