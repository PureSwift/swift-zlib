/* zbench.c - throughput, measured the same way against either library.
 *
 * Compiled twice like the conformance programs: once against the system libz and once against
 * this library, so the two binaries run identical code over identical payloads and the only
 * variable is the implementation underneath. Every line it prints is a measurement, not a
 * check: this program cannot fail a build, because a timing taken on a shared machine measures
 * the neighbours as much as the library. What it can do is leave a number in the log.
 *
 * Three payloads, because the hot paths differ by data: "text" is word-shaped and
 * Huffman-friendly, "records" is run-heavy binary, "random" is incompressible and exercises
 * stored blocks and the literal path. All three are deterministic, so runs compare.
 *
 * Deflate is measured at levels 1, 6 and 9; inflate decodes the level-6 stream. Each timing
 * is the best of three passes, which discards warm-up and scheduler noise rather than
 * averaging it in.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

enum {
    TEXT_SIZE = 8 << 20,
    RECORDS_SIZE = 8 << 20,
    RANDOM_SIZE = 8 << 20,
    PASSES = 3,
};

static unsigned long long rng_state = 0x9E3779B97F4A7C15ULL;

static unsigned long long rng(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static void fill_text(unsigned char *out, size_t len) {
    static const char *words[] = {
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
        "stream", "window", "buffer", "length", "distance", "literal", "match",
        "block", "huffman", "code", "symbol", "deflate", "inflate", "byte",
    };
    size_t count = sizeof(words) / sizeof(words[0]);
    size_t at = 0;

    while (at < len) {
        const char *word = words[rng() % count];
        size_t n = strlen(word);
        if (at + n + 1 > len) break;
        memcpy(out + at, word, n);
        at += n;
        out[at++] = (rng() % 12 == 0) ? '\n' : ' ';
    }
    while (at < len) out[at++] = ' ';
}

static void fill_records(unsigned char *out, size_t len) {
    /* Fixed-shape records with slowly-varying fields: long runs, repeated structure, the
     * shape of logs and databases. */
    size_t at = 0;
    unsigned counter = 0;

    while (at + 64 <= len) {
        memset(out + at, 0, 64);
        out[at] = 0xAB;
        out[at + 1] = (unsigned char)(counter >> 8);
        out[at + 2] = (unsigned char)counter;
        memcpy(out + at + 3, "record-payload-", 15);
        out[at + 18] = 'A' + counter % 7;
        counter++;
        at += 64;
    }
    while (at < len) out[at++] = 0;
}

static void fill_random(unsigned char *out, size_t len) {
    for (size_t i = 0; i + 8 <= len; i += 8) {
        unsigned long long v = rng();
        memcpy(out + i, &v, 8);
    }
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* One full deflate of src into dst, returning the compressed size, or 0 on error. */
static size_t run_deflate(int level, const unsigned char *src, size_t srclen,
                          unsigned char *dst, size_t dstcap) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (deflateInit(&s, level) != Z_OK) return 0;

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srclen;
    s.next_out = dst;
    s.avail_out = (uInt)dstcap;

    int rc = deflate(&s, Z_FINISH);
    size_t made = dstcap - s.avail_out;
    deflateEnd(&s);
    return rc == Z_STREAM_END ? made : 0;
}

static size_t run_inflate(const unsigned char *src, size_t srclen,
                          unsigned char *dst, size_t dstcap) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit(&s) != Z_OK) return 0;

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srclen;
    s.next_out = dst;
    s.avail_out = (uInt)dstcap;

    int rc = inflate(&s, Z_FINISH);
    size_t made = dstcap - s.avail_out;
    inflateEnd(&s);
    return rc == Z_STREAM_END ? made : 0;
}

static void bench_payload(const char *name, const unsigned char *payload, size_t len) {
    size_t cap = compressBound((uLong)len);
    unsigned char *compressed = malloc(cap);
    unsigned char *recovered = malloc(len);
    if (!compressed || !recovered) { fprintf(stderr, "zbench: out of memory\n"); exit(1); }

    static const int levels[] = { 1, 6, 9 };

    for (size_t i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
        int level = levels[i];
        size_t made = 0;
        double best = 1e30;

        for (int pass = 0; pass < PASSES; pass++) {
            double t0 = now();
            made = run_deflate(level, payload, len, compressed, cap);
            double t1 = now();
            if (!made) { fprintf(stderr, "zbench: deflate failed\n"); exit(1); }
            if (t1 - t0 < best) best = t1 - t0;
        }
        printf("BENCH deflate %-8s L%d %8.1f MB/s\n", name, level, len / best / 1e6);
    }

    /* Inflate always decodes the level-6 stream this same binary produced. */
    size_t made6 = run_deflate(6, payload, len, compressed, cap);
    double best = 1e30;

    for (int pass = 0; pass < PASSES; pass++) {
        double t0 = now();
        size_t got = run_inflate(compressed, made6, recovered, len);
        double t1 = now();
        if (got != len || memcmp(recovered, payload, len) != 0) {
            fprintf(stderr, "zbench: inflate round trip failed\n");
            exit(1);
        }
        if (t1 - t0 < best) best = t1 - t0;
    }
    printf("BENCH inflate %-8s    %8.1f MB/s\n", name, len / best / 1e6);

    free(compressed);
    free(recovered);
}

int main(void) {
    printf("zlibVersion %s\n", zlibVersion());

    unsigned char *text = malloc(TEXT_SIZE);
    unsigned char *records = malloc(RECORDS_SIZE);
    unsigned char *noise = malloc(RANDOM_SIZE);
    if (!text || !records || !noise) { fprintf(stderr, "zbench: out of memory\n"); return 1; }

    fill_text(text, TEXT_SIZE);
    fill_records(records, RECORDS_SIZE);
    fill_random(noise, RANDOM_SIZE);

    bench_payload("text", text, TEXT_SIZE);
    bench_payload("records", records, RECORDS_SIZE);
    bench_payload("random", noise, RANDOM_SIZE);

    free(text);
    free(records);
    free(noise);
    return 0;
}
