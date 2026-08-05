/* zfuzz.c - differential stress for the inflate fast/careful boundary.
 *
 * gen mode (run with the reference): writes N compressed streams - mixed payloads, levels,
 * framings, a share of them bit-flipped or truncated - into a directory. An optional seed
 * argument varies the whole batch, which is what makes repeated runs *continuing* fuzzing
 * rather than one fixed regression test; the seed is printed so a failing batch can be
 * regenerated exactly.
 *
 * check mode (run with either library): decodes every stream under several input/output
 * chunk-size patterns, printing per stream+pattern: final return code, output length, output
 * FNV hash, and a hash of the whole return-code sequence. What two correct libraries must
 * agree on is the verdict and, for accepted streams, the bytes; the code-sequence hash is
 * informational, because the interleaving of Z_OK and Z_BUF_ERROR while starved for input
 * is not part of the contract. run_fuzz.sh encodes exactly that comparison.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define STREAMS 3000

static unsigned long long rs = 0x243F6A8885A308D3ULL;
static unsigned long long rng(void) {
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs;
}

static size_t make_payload(unsigned char *out, size_t cap) {
    size_t len = rng() % cap;
    size_t at = 0;
    int kind = rng() % 4;
    while (at < len) {
        switch (kind) {
        case 0: out[at] = (unsigned char)rng(); at++; break;                  /* noise */
        case 1: out[at] = "abcdefgh"[rng() % 8]; at++; break;                 /* smallish alphabet */
        case 2: {                                                             /* runs */
            size_t run = 1 + rng() % 300; unsigned char b = (unsigned char)rng();
            while (run-- && at < len) out[at++] = b;
            break;
        }
        default: {                                                            /* self-similar */
            if (at < 16) { out[at] = (unsigned char)rng(); at++; }
            else { size_t back = 1 + rng() % (at < 4000 ? at : 4000); out[at] = out[at - back]; at++; }
        }
        }
    }
    return len;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: zfuzz gen dir [seed] | zfuzz check dir\n"); return 2; }
    const char *dir = argv[2];
    char path[1024];

    if (strcmp(argv[1], "gen") == 0) {
        unsigned char *payload = malloc(100000);
        unsigned char *compressed = malloc(200000);

        if (argc > 3) rs ^= strtoull(argv[3], NULL, 0);
        printf("seed %llx\n", rs);

        for (int i = 0; i < STREAMS; i++) {
            size_t len = make_payload(payload, 100000);
            int level = (int)(rng() % 10);
            int wbits = 15;
            switch (rng() % 3) { case 0: wbits = 15; break; case 1: wbits = -15; break; default: wbits = 31; }

            z_stream s; memset(&s, 0, sizeof(s));
            if (deflateInit2(&s, level, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 1;
            s.next_in = payload; s.avail_in = (uInt)len;
            s.next_out = compressed; s.avail_out = 200000;
            if (deflate(&s, Z_FINISH) != Z_STREAM_END) return 1;
            size_t clen = 200000 - s.avail_out;
            deflateEnd(&s);

            /* a third damaged: bit flip or truncation, deterministically */
            unsigned damage = rng() % 3;
            if (damage == 1 && clen > 4) compressed[rng() % clen] ^= (unsigned char)(1u << (rng() % 8));
            if (damage == 2 && clen > 8) clen -= 1 + rng() % (clen / 2);

            snprintf(path, sizeof(path), "%s/s%04d_%d.bin", dir, i, wbits);
            FILE *f = fopen(path, "wb");
            if (!f) { perror("fopen"); return 1; }
            fwrite(compressed, 1, clen, f);
            fclose(f);
        }
        printf("generated %d streams\n", STREAMS);
        return 0;
    }

    /* check mode: chunked decode, every stream, several patterns */
    static const struct { size_t in, out; } patterns[] = {
        { 1u << 20, 1u << 20 }, { 1, 1 }, { 7, 13 }, { 3, 4096 }, { 4096, 3 }, { 271, 259 },
    };

    unsigned char *compressed = malloc(200000);
    unsigned char *outbuf = malloc(1 << 20);

    for (int i = 0; i < STREAMS; i++) {
        /* find the file whatever its wbits suffix */
        int wb[3] = { 15, -15, 31 };
        FILE *f = NULL; int wbits = 15;
        for (int k = 0; k < 3; k++) {
            snprintf(path, sizeof(path), "%s/s%04d_%d.bin", dir, i, wb[k]);
            f = fopen(path, "rb");
            if (f) { wbits = wb[k]; break; }
        }
        if (!f) { printf("s%04d missing\n", i); continue; }
        size_t clen = fread(compressed, 1, 200000, f);
        fclose(f);

        for (size_t p = 0; p < sizeof(patterns) / sizeof(patterns[0]); p++) {
            z_stream s; memset(&s, 0, sizeof(s));
            if (inflateInit2(&s, wbits) != Z_OK) { printf("s%04d p%zu initfail\n", i, p); continue; }

            unsigned long long codehash = 1469598103934665603ULL, outhash = 1469598103934665603ULL;
            size_t inpos = 0, outlen = 0;
            int rc = Z_OK, stalls = 0;

            while (rc == Z_OK || rc == Z_BUF_ERROR) {
                size_t take = patterns[p].in;
                if (take > clen - inpos) take = clen - inpos;
                s.next_in = compressed + inpos; s.avail_in = (uInt)take;
                s.next_out = outbuf; s.avail_out = (uInt)(patterns[p].out);

                rc = inflate(&s, Z_NO_FLUSH);

                size_t made = patterns[p].out - s.avail_out;
                size_t used = take - s.avail_in;
                inpos += used;
                for (size_t b = 0; b < made; b++) { outhash ^= outbuf[b]; outhash *= 1099511628211ULL; }
                outlen += made;
                codehash ^= (unsigned long long)(rc + 10); codehash *= 1099511628211ULL;

                if (rc == Z_STREAM_END) break;
                if (made == 0 && used == 0) {
                    if (inpos >= clen) break;      /* out of input entirely */
                    if (++stalls > 4) break;       /* no progress: report and stop */
                } else stalls = 0;
                if (outlen > (100u << 20)) break;  /* runaway guard */
            }

            printf("s%04d p%zu rc%d len%zu code%llx out%llx\n", i, p, rc, outlen, codehash, outhash);
            inflateEnd(&s);
        }
    }
    return 0;
}
