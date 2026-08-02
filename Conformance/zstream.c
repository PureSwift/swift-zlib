/* Differential conformance for the streaming z_stream API.
 *
 * Compiled twice — once against the reference libz, once against this library — and the two
 * outputs diffed, the same arrangement as zconform.c and for the same reason.
 *
 * The inflate half runs over a stream embedded here rather than one each build produced for
 * itself. Two encoders are not required to emit the same bytes, so a decoder fed its own
 * library's output is being asked an easier question than the one that matters; feeding both
 * the identical stream is what makes the comparison mean something.
 *
 * Lines beginning "SIZE:" are the only ones allowed to differ.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

/* 2760 bytes of payload compressed by zlib at level 9, 292 bytes of stream. Mixed text, pseudo-random bytes and a
 * repetitive tail, so the stream carries dynamic blocks, long matches and incompressible runs
 * rather than exercising one path. */
static const unsigned char fixed_stream[] = {
    0x78, 0xda, 0x2b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48, 0x2a, 0xca,
    0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f,
    0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56, 0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb,
    0x81, 0x79, 0xa3, 0x8a, 0x47, 0x15, 0x8f, 0x2a, 0x1e, 0x55, 0x3c, 0xaa, 0x78, 0x54, 0xf1,
    0x30, 0x52, 0xcc, 0xa0, 0xea, 0x95, 0x3f, 0x65, 0xe7, 0x3d, 0x66, 0x0d, 0xdf, 0xa2, 0xe9,
    0x7b, 0x1e, 0xb2, 0x69, 0x07, 0x94, 0xce, 0xda, 0xff, 0x84, 0x53, 0x2f, 0xb8, 0x62, 0xee,
    0xa1, 0xe7, 0x3c, 0x86, 0x61, 0xd5, 0x0b, 0x8f, 0xbd, 0x16, 0x30, 0x8d, 0xaa, 0x5f, 0x72,
    0xf2, 0x9d, 0xb0, 0x45, 0x6c, 0xd3, 0xf2, 0x33, 0x1f, 0xc5, 0xac, 0x13, 0x5a, 0x57, 0x9d,
    0xff, 0x22, 0x69, 0x97, 0xdc, 0xb1, 0xf6, 0xd2, 0x77, 0x19, 0xa7, 0xf4, 0x9e, 0x8d, 0xd7,
    0x7e, 0x2b, 0xb8, 0x66, 0xf5, 0x6f, 0xb9, 0xf9, 0x4f, 0xd9, 0x23, 0x77, 0xd2, 0xf6, 0x3b,
    0x8c, 0x6a, 0xde, 0x05, 0x53, 0x77, 0xdd, 0x67, 0xd1, 0xf4, 0x2b, 0x9e, 0xb1, 0xf7, 0x31,
    0x87, 0x6e, 0x50, 0xf9, 0x9c, 0x83, 0xcf, 0xb8, 0x0d, 0x42, 0xab, 0xe6, 0x1f, 0x79, 0xc9,
    0x67, 0x1c, 0x51, 0xbb, 0xe8, 0xf8, 0x1b, 0x41, 0xb3, 0xe8, 0x86, 0xa5, 0xa7, 0xde, 0x8b,
    0x58, 0xc6, 0xb5, 0xac, 0x3c, 0xf7, 0x59, 0xc2, 0x36, 0xa9, 0x7d, 0xcd, 0xc5, 0x6f, 0xd2,
    0x0e, 0xa9, 0x5d, 0xeb, 0xaf, 0xfc, 0x94, 0x73, 0xce, 0xe8, 0xdd, 0x74, 0xfd, 0x8f, 0xa2,
    0x5b, 0xf6, 0x84, 0xad, 0xb7, 0xfe, 0x13, 0x70, 0xde, 0x02, 0x02, 0xce, 0x73, 0x24, 0xe0,
    0xbc, 0x47, 0x04, 0x9c, 0xd7, 0x4c, 0xc0, 0x79, 0x2a, 0x04, 0x9c, 0x77, 0x94, 0x80, 0xf3,
    0xd2, 0x08, 0x38, 0x8f, 0x9d, 0x80, 0xf3, 0x56, 0x10, 0x70, 0x9e, 0x27, 0x01, 0xe7, 0xbd,
    0x22, 0xe0, 0xbc, 0x6e, 0x02, 0xce, 0xd3, 0xc1, 0xe5, 0xbc, 0xc4, 0xa4, 0xe4, 0x51, 0x44,
    0x07, 0x04, 0x00, 0xfe, 0xa9, 0x3f, 0x39,
};

/* The payload the fixed stream above decodes to; regenerated here rather than embedded, since
 * it is 2760 bytes and entirely determined by this function. */
static size_t build_payload(unsigned char *out, size_t cap) {
    size_t n = 0;
    for (int r = 0; r < 40; r++) {
        const char *line = "the quick brown fox jumps over the lazy dog. ";
        size_t len = strlen(line);
        if (n + len > cap) return n;
        memcpy(out + n, line, len);
        n += len;
    }
    for (int i = 0; i < 600 && n < cap; i++) {
        out[n++] = (unsigned char)((i * 37 + (i >> 5)) & 0xFF);
    }
    for (int r = 0; r < 30; r++) {
        const char *line = "abcabcabcabc";
        size_t len = strlen(line);
        if (n + len > cap) return n;
        memcpy(out + n, line, len);
        n += len;
    }
    return n;
}

/* Round trips through the streaming API at the given buffer sizes, which is where a state
 * machine that assumed it could finish in one call comes apart. */
static void stream_roundtrip(const unsigned char *data, size_t len,
                             int level, int windowBits,
                             uInt in_chunk, uInt out_chunk,
                             const char *label) {
    z_stream def;
    memset(&def, 0, sizeof def);

    int rc = deflateInit2(&def, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY);
    printf("deflateInit2 %-14s w%-4d %d\n", label, windowBits, rc);
    if (rc != Z_OK) return;

    uLong bound = deflateBound(&def, (uLong)len);
    unsigned char *packed = malloc(bound + 64);
    size_t packed_len = 0;
    size_t offset = 0;
    int last = Z_OK;

    for (;;) {
        if (def.avail_in == 0 && offset < len) {
            uInt take = (uInt)(len - offset < in_chunk ? len - offset : in_chunk);
            def.next_in = (Bytef *)(data + offset);
            def.avail_in = take;
            offset += take;
        }

        def.next_out = packed + packed_len;
        def.avail_out = (uInt)(out_chunk < bound + 64 - packed_len
                               ? out_chunk : bound + 64 - packed_len);
        uInt before = def.avail_out;

        int flush = (offset >= len && def.avail_in == 0) ? Z_FINISH : Z_NO_FLUSH;
        last = deflate(&def, flush);
        packed_len += before - def.avail_out;

        if (last == Z_STREAM_END) break;
        if (last != Z_OK && last != Z_BUF_ERROR) break;
        if (packed_len >= bound + 64) break;

        /* No input taken and no output made means the library reported progress it did not
         * make. Bailing out rather than looping keeps a bug a failed comparison instead of a
         * hung test run. */
        if (before == def.avail_out && def.avail_in == 0 && offset >= len
            && last == Z_OK && flush == Z_FINISH) {
            printf("deflate STALLED %-14s w%-4d\n", label, windowBits);
            break;
        }
    }

    printf("deflate end   %-14s w%-4d %d total_in=%lu\n", label, windowBits, last, def.total_in);
    printf("within bound  %-14s w%-4d %d\n", label, windowBits,
           (uLong)packed_len <= bound);
    printf("SIZE: %-14s w%-4d %lu (bound %lu)\n", label, windowBits,
           (unsigned long)packed_len, bound);
    if (windowBits > 0) {
        printf("deflate adler %-14s w%-4d %08lx\n", label, windowBits, def.adler);
    }
    printf("deflateEnd    %-14s w%-4d %d\n", label, windowBits, deflateEnd(&def));

    /* And back, through the streaming decompressor at the same awkward sizes. */
    z_stream inf;
    memset(&inf, 0, sizeof inf);
    rc = inflateInit2(&inf, windowBits);
    printf("inflateInit2  %-14s w%-4d %d\n", label, windowBits, rc);
    if (rc != Z_OK) { free(packed); return; }

    unsigned char *back = malloc(len + 64);
    size_t back_len = 0;
    size_t in_off = 0;
    last = Z_OK;

    for (;;) {
        if (inf.avail_in == 0 && in_off < packed_len) {
            uInt take = (uInt)(packed_len - in_off < in_chunk
                               ? packed_len - in_off : in_chunk);
            inf.next_in = packed + in_off;
            inf.avail_in = take;
            in_off += take;
        }

        inf.next_out = back + back_len;
        inf.avail_out = (uInt)(out_chunk < len + 64 - back_len ? out_chunk : len + 64 - back_len);
        uInt before = inf.avail_out;

        last = inflate(&inf, Z_NO_FLUSH);
        back_len += before - inf.avail_out;

        if (last == Z_STREAM_END) break;
        if (last != Z_OK && last != Z_BUF_ERROR) break;
        if (inf.avail_in == 0 && in_off >= packed_len && before == inf.avail_out) {
            /* Out of input, out of progress: truncated, or a library claiming progress it did
             * not make. Either way there is nothing further to do. */
            printf("inflate STALLED %-14s w%-4d rc=%d\n", label, windowBits, last);
            break;
        }
        if (back_len >= len + 64) break;
    }

    printf("inflate end   %-14s w%-4d %d total_out=%lu\n", label, windowBits, last, inf.total_out);
    printf("recovered     %-14s w%-4d %lu %08lx\n", label, windowBits,
           (unsigned long)back_len,
           back_len ? crc32(0, back, (uInt)back_len) : 0);
    printf("identical     %-14s w%-4d %d\n", label, windowBits,
           back_len == len && memcmp(back, data, len) == 0);
    printf("inflateEnd    %-14s w%-4d %d\n", label, windowBits, inflateEnd(&inf));

    free(packed);
    free(back);
}

/* Decoding the embedded stream, which is the comparison that pins inflate itself. */
static void fixed_inflate(uInt in_chunk, uInt out_chunk) {
    unsigned char payload[4096];
    size_t payload_len = build_payload(payload, sizeof payload);

    z_stream inf;
    memset(&inf, 0, sizeof inf);
    int rc = inflateInit(&inf);
    if (rc != Z_OK) { printf("fixed init %d\n", rc); return; }

    unsigned char back[4096];
    size_t back_len = 0, in_off = 0;
    int last = Z_OK;

    for (;;) {
        if (inf.avail_in == 0 && in_off < sizeof fixed_stream) {
            uInt take = (uInt)(sizeof fixed_stream - in_off < in_chunk
                               ? sizeof fixed_stream - in_off : in_chunk);
            inf.next_in = (Bytef *)(fixed_stream + in_off);
            inf.avail_in = take;
            in_off += take;
        }
        inf.next_out = back + back_len;
        inf.avail_out = (uInt)(out_chunk < sizeof back - back_len
                               ? out_chunk : sizeof back - back_len);
        uInt before = inf.avail_out;
        last = inflate(&inf, Z_NO_FLUSH);
        back_len += before - inf.avail_out;
        if (last != Z_OK) break;
        if (inf.avail_in == 0 && in_off >= sizeof fixed_stream && before == inf.avail_out) break;
        if (back_len >= sizeof back) break;
    }

    printf("fixed in=%-5u out=%-5u rc=%d total_in=%lu total_out=%lu adler=%08lx crc=%08lx\n",
           in_chunk, out_chunk, last, inf.total_in, inf.total_out, inf.adler,
           back_len ? crc32(0, back, (uInt)back_len) : 0);
    printf("fixed matches payload %d\n",
           back_len == payload_len && memcmp(back, payload, back_len) == 0);
    printf("fixed inflateEnd %d\n", inflateEnd(&inf));
}

/* The property that makes concatenated streams work: when a stream ends, next_in has to point
 * at the byte after it, not at wherever a bit buffer happened to stop. */
static void trailing_bytes(void) {
    unsigned char buf[sizeof fixed_stream + 8];
    memcpy(buf, fixed_stream, sizeof fixed_stream);
    memcpy(buf + sizeof fixed_stream, "TRAILING", 8);

    z_stream inf;
    memset(&inf, 0, sizeof inf);
    if (inflateInit(&inf) != Z_OK) return;

    unsigned char back[4096];
    inf.next_in = buf;
    inf.avail_in = (uInt)sizeof buf;
    inf.next_out = back;
    inf.avail_out = (uInt)sizeof back;

    int rc = inflate(&inf, Z_NO_FLUSH);
    printf("trailing rc=%d avail_in=%u total_in=%lu\n", rc, inf.avail_in, inf.total_in);
    printf("trailing next_in points at %.8s\n",
           inf.avail_in >= 8 ? (const char *)inf.next_in : "(short)");
    inflateEnd(&inf);
}

/* Corrupt input, which is the case that matters most for the half reading untrusted bytes. */
static void corrupt(void) {
    unsigned char buf[sizeof fixed_stream];
    unsigned char back[4096];

    for (size_t bit = 0; bit < 6; bit++) {
        memcpy(buf, fixed_stream, sizeof buf);
        buf[20 + bit * 7] ^= (unsigned char)(1 << (bit % 8));

        z_stream inf;
        memset(&inf, 0, sizeof inf);
        if (inflateInit(&inf) != Z_OK) continue;
        inf.next_in = buf;
        inf.avail_in = (uInt)sizeof buf;
        inf.next_out = back;
        inf.avail_out = (uInt)sizeof back;

        int rc = inflate(&inf, Z_FINISH);
        /* Only whether it was rejected, not which byte it stopped on: two decoders may notice
         * the same corruption at different points and both be right. */
        printf("corrupt %zu rejected=%d\n", bit, rc < 0);
        inflateEnd(&inf);
    }
}

/* gzip framing, and the mode that accepts either framing without being told which.
 *
 * Compressing with one setting and decompressing with another is the point: a decoder that
 * detects the wrapper has to reach the same answer as one that was told. */
static void gzip_modes(const unsigned char *data, size_t len) {
    static const struct { int deflate_bits; int inflate_bits; const char *name; } modes[] = {
        { 15 + 16, 15 + 16, "gzip" },
        { 15 + 16, 15 + 32, "gzip->detect" },
        { 15,      15 + 32, "zlib->detect" },
    };

    for (size_t m = 0; m < sizeof modes / sizeof modes[0]; m++) {
        z_stream def;
        memset(&def, 0, sizeof def);

        int rc = deflateInit2(&def, 6, Z_DEFLATED, modes[m].deflate_bits, 8,
                              Z_DEFAULT_STRATEGY);
        printf("gz deflateInit2 %-14s %d\n", modes[m].name, rc);
        if (rc != Z_OK) continue;

        uLong bound = deflateBound(&def, (uLong)len);
        unsigned char *packed = malloc(bound + 64);
        def.next_in = (Bytef *)data;
        def.avail_in = (uInt)len;
        def.next_out = packed;
        def.avail_out = (uInt)(bound + 64);

        rc = deflate(&def, Z_FINISH);
        size_t packed_len = (bound + 64) - def.avail_out;
        printf("gz deflate      %-14s %d within_bound=%d\n", modes[m].name, rc,
               (uLong)packed_len <= bound);
        printf("SIZE: %-14s gz   %lu (bound %lu)\n", modes[m].name,
               (unsigned long)packed_len, bound);

        /* The header's own bytes, which are framing rather than compressed output and so must
         * match the reference exactly. */
        if (modes[m].deflate_bits > 15 && packed_len >= 10) {
            printf("gz header       %-14s %02x %02x %02x %02x os=%02x\n", modes[m].name,
                   packed[0], packed[1], packed[2], packed[3], packed[9]);
        }
        printf("gz crc          %-14s %08lx\n", modes[m].name, def.adler);
        deflateEnd(&def);

        z_stream inf;
        memset(&inf, 0, sizeof inf);
        rc = inflateInit2(&inf, modes[m].inflate_bits);
        printf("gz inflateInit2 %-14s %d\n", modes[m].name, rc);
        if (rc != Z_OK) { free(packed); continue; }

        unsigned char *back = malloc(len + 64);
        inf.next_in = packed;
        inf.avail_in = (uInt)packed_len;
        inf.next_out = back;
        inf.avail_out = (uInt)(len + 64);

        rc = inflate(&inf, Z_FINISH);
        size_t back_len = (len + 64) - inf.avail_out;
        printf("gz inflate      %-14s %d out=%lu avail_in=%u\n", modes[m].name, rc,
               (unsigned long)back_len, inf.avail_in);
        printf("gz identical    %-14s %d\n", modes[m].name,
               back_len == len && memcmp(back, data, len) == 0);
        printf("gz crc back     %-14s %08lx\n", modes[m].name, inf.adler);
        inflateEnd(&inf);

        free(packed);
        free(back);
    }

    /* A member with a name and a comment, written and then read back. Both fields change where
     * the compressed data starts, so a decoder that skips one wrongly reads the body from the
     * wrong byte; and the read side fills buffers the caller sized, so a library that ignores
     * those sizes corrupts the caller rather than itself. */
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit2(&def, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
        gz_header head;
        memset(&head, 0, sizeof head);
        head.name = (Bytef *)"payload.txt";
        head.comment = (Bytef *)"a comment";
        head.time = 1234567890;
        head.os = 3;
        head.text = 1;

        printf("gz setHeader    %d\n", deflateSetHeader(&def, &head));

        unsigned char packed[8192];
        def.next_in = (Bytef *)data;
        def.avail_in = (uInt)len;
        def.next_out = packed;
        def.avail_out = (uInt)sizeof packed;
        int rc = deflate(&def, Z_FINISH);
        size_t packed_len = sizeof packed - def.avail_out;
        printf("gz named deflate %d flags=%02x\n", rc, packed_len > 3 ? packed[3] : 0);
        deflateEnd(&def);

        /* Read it back, with buffers deliberately of different generosity: one ample, one so
         * small the field has to be truncated and still terminated. */
        static const uInt name_caps[] = { 64, 5 };

        for (size_t c = 0; c < sizeof name_caps / sizeof name_caps[0]; c++) {
            z_stream inf;
            memset(&inf, 0, sizeof inf);
            if (inflateInit2(&inf, 15 + 16) != Z_OK) continue;

            gz_header got;
            unsigned char name[64], comment[64], extra[64];
            memset(&got, 0, sizeof got);
            memset(name, 0xAA, sizeof name);
            memset(comment, 0xAA, sizeof comment);
            got.name = name;       got.name_max = name_caps[c];
            got.comment = comment; got.comm_max = (uInt)sizeof comment;
            got.extra = extra;     got.extra_max = (uInt)sizeof extra;

            printf("gz getHeader    cap=%u %d\n", name_caps[c], inflateGetHeader(&inf, &got));

            unsigned char back[8192];
            inf.next_in = packed;
            inf.avail_in = (uInt)packed_len;
            inf.next_out = back;
            inf.avail_out = (uInt)sizeof back;
            rc = inflate(&inf, Z_FINISH);

            printf("gz header done  cap=%u done=%d text=%d time=%lu os=%d\n",
                   name_caps[c], got.done, got.text, got.time, got.os);
            /* Printed as bytes rather than as a string: a field too long for its buffer comes
             * back unterminated, so treating it as one would read past the buffer and would
             * compare whatever happened to follow it. */
            printf("gz header name  cap=%u ", name_caps[c]);
            for (uInt i = 0; i < name_caps[c] && i < sizeof name; i++) printf("%02x", name[i]);
            printf("\n");
            printf("gz header comm  cap=%u ", name_caps[c]);
            for (uInt i = 0; i < 12; i++) printf("%02x", comment[i]);
            printf("\n");
            printf("gz named body   cap=%u rc=%d identical=%d\n", name_caps[c], rc,
                   (size_t)(sizeof back - inf.avail_out) == len
                   && memcmp(back, data, len) == 0);
            inflateEnd(&inf);
        }
    }

    /* Truncated: every prefix of a member has to be refused rather than half-accepted. */
    z_stream d2;
    memset(&d2, 0, sizeof d2);
    if (deflateInit2(&d2, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
        unsigned char packed[8192];
        d2.next_in = (Bytef *)data;
        d2.avail_in = (uInt)len;
        d2.next_out = packed;
        d2.avail_out = (uInt)sizeof packed;
        deflate(&d2, Z_FINISH);
        size_t packed_len = sizeof packed - d2.avail_out;
        deflateEnd(&d2);

        for (size_t cut = 1; cut <= 4; cut++) {
            z_stream inf;
            memset(&inf, 0, sizeof inf);
            if (inflateInit2(&inf, 15 + 16) != Z_OK) continue;
            unsigned char back[8192];
            inf.next_in = packed;
            inf.avail_in = (uInt)(packed_len - cut * 2);
            inf.next_out = back;
            inf.avail_out = (uInt)sizeof back;
            int rc = inflate(&inf, Z_FINISH);
            printf("gz truncated -%zu finished=%d\n", cut * 2, rc == Z_STREAM_END);
            inflateEnd(&inf);
        }
    }
}

static void misuse(void) {
    z_stream s;
    memset(&s, 0, sizeof s);

    printf("inflate no init      %d\n", inflate(&s, Z_NO_FLUSH));
    printf("inflateEnd no init   %d\n", inflateEnd(&s));
    printf("deflate no init      %d\n", deflate(&s, Z_NO_FLUSH));
    printf("deflateEnd no init   %d\n", deflateEnd(&s));

    memset(&s, 0, sizeof s);
    printf("deflateInit bad level %d\n", deflateInit(&s, 12));

    memset(&s, 0, sizeof s);
    printf("inflateInit2 bad bits %d\n", inflateInit2(&s, 7));

    memset(&s, 0, sizeof s);
    if (deflateInit(&s, 6) == Z_OK) {
        printf("deflate bad flush    %d\n", deflate(&s, 99));
        unsigned pending; int bits;
        printf("deflatePending       %d\n", deflatePending(&s, &pending, &bits));
        printf("deflateReset         %d\n", deflateReset(&s));
        printf("deflateEnd           %d\n", deflateEnd(&s));
    }

    memset(&s, 0, sizeof s);
    if (inflateInit(&s) == Z_OK) {
        printf("inflateReset         %d\n", inflateReset(&s));
        printf("inflateReset2 raw    %d\n", inflateReset2(&s, -15));
        printf("inflateEnd           %d\n", inflateEnd(&s));
    }
}

int main(void) {
    unsigned char payload[4096];
    size_t payload_len = build_payload(payload, sizeof payload);

    static const uInt chunks[][2] = {
        { 1, 1 }, { 1, 4096 }, { 4096, 1 }, { 7, 13 }, { 64, 64 }, { 4096, 4096 },
    };

    for (size_t i = 0; i < sizeof chunks / sizeof chunks[0]; i++) {
        fixed_inflate(chunks[i][0], chunks[i][1]);
    }

    char label[32];
    for (size_t i = 0; i < sizeof chunks / sizeof chunks[0]; i++) {
        snprintf(label, sizeof label, "in%u/out%u", chunks[i][0], chunks[i][1]);
        stream_roundtrip(payload, payload_len, 6, 15, chunks[i][0], chunks[i][1], label);
        stream_roundtrip(payload, payload_len, 6, -15, chunks[i][0], chunks[i][1], label);
    }

    for (int level = 0; level <= 9; level++) {
        snprintf(label, sizeof label, "level%d", level);
        stream_roundtrip(payload, payload_len, level, 15, 4096, 4096, label);
    }

    for (int wb = 9; wb <= 15; wb++) {
        snprintf(label, sizeof label, "wb%d", wb);
        stream_roundtrip(payload, payload_len, 6, wb, 4096, 4096, label);
    }

    trailing_bytes();
    corrupt();
    gzip_modes(payload, payload_len);
    misuse();

    return 0;
}
