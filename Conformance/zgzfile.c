/* Differential conformance for the gz* file layer.
 *
 * Compiled twice and diffed, as the others are. Each build writes its own files and reads them
 * back, so the comparison is of behaviour rather than of bytes on disk — two encoders need not
 * produce the same file, and the "SIZE:" lines carry the sizes that legitimately differ.
 *
 * The conventions in this family are stdio's and they are not uniform: gzread answers in bytes
 * and -1 on error, gzfread answers in items and cannot report an error at all, gzgetc answers
 * with an int so -1 can mean end-of-file. Each is checked as what it actually is.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

static char dir[512];

static const char *at(const char *name) {
    static char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    return path;
}

static long file_size(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fclose(f);
    return n;
}

static size_t build_payload(unsigned char *out, size_t cap) {
    size_t n = 0;
    for (int r = 0; r < 60 && n + 45 < cap; r++) {
        const char *line = "the quick brown fox jumps over the lazy dog.\n";
        size_t len = strlen(line);
        memcpy(out + n, line, len);
        n += len;
    }
    for (int i = 0; i < 800 && n < cap; i++) {
        out[n++] = (unsigned char)((i * 37 + (i >> 5)) & 0xFF);
    }
    return n;
}

/* Write a file, read it back, and check every answer along the way. */
static void write_then_read(const unsigned char *data, size_t len, int level) {
    char mode[8];
    snprintf(mode, sizeof mode, "wb%d", level);

    gzFile out = gzopen(at("roundtrip.gz"), mode);
    printf("gzopen w L%d      %d\n", level, out != NULL);
    if (!out) return;

    int put = gzwrite(out, data, (unsigned)len);
    printf("gzwrite L%d       %d\n", level, put);
    printf("gztell w L%d      %ld\n", level, (long)gztell(out));
    printf("gzclose w L%d     %d\n", level, gzclose(out));

    printf("SIZE: roundtrip L%d %ld\n", level, file_size(at("roundtrip.gz")));

    gzFile in = gzopen(at("roundtrip.gz"), "rb");
    printf("gzopen r L%d      %d\n", level, in != NULL);
    if (!in) return;

    printf("gzdirect L%d      %d\n", level, gzdirect(in));

    unsigned char *back = malloc(len + 64);
    size_t total = 0;
    for (;;) {
        int got = gzread(in, back + total, 1024);
        if (got <= 0) { printf("gzread last L%d   %d\n", level, got); break; }
        total += (size_t)got;
        if (total > len) break;
    }

    printf("read back L%d     %lu identical=%d\n", level, (unsigned long)total,
           total == len && memcmp(back, data, len) == 0);
    printf("gztell r L%d      %ld\n", level, (long)gztell(in));
    printf("gzeof L%d         %d\n", level, gzeof(in));
    printf("gzoffset==size L%d %d\n", level, gzoffset(in) == file_size(at("roundtrip.gz")));

    int errnum = 0;
    gzerror(in, &errnum);
    printf("gzerror L%d       %d\n", level, errnum);
    printf("gzclose r L%d     %d\n", level, gzclose(in));

    free(back);
}

/* Reading in awkward sizes, which is where buffering shows. */
static void chunked_reads(const unsigned char *data, size_t len) {
    static const unsigned chunks[] = { 1, 3, 64, 4096 };

    for (size_t c = 0; c < sizeof chunks / sizeof chunks[0]; c++) {
        gzFile in = gzopen(at("roundtrip.gz"), "rb");
        if (!in) continue;

        unsigned char *back = malloc(len + 64);
        size_t total = 0;
        for (;;) {
            int got = gzread(in, back + total, chunks[c]);
            if (got <= 0) break;
            total += (size_t)got;
            if (total > len) break;
        }

        printf("chunk %-5u      %lu identical=%d eof=%d\n", chunks[c],
               (unsigned long)total,
               total == len && memcmp(back, data, len) == 0, gzeof(in));
        gzclose(in);
        free(back);
    }
}

/* The character and line entry points, each with its own convention. */
static void character_api(void) {
    gzFile out = gzopen(at("lines.gz"), "wb");
    if (!out) return;
    gzputs(out, "first line\n");
    gzprintf(out, "formatted %d %s\n", 42, "line");
    gzputc(out, 'x');
    gzputc(out, '\n');
    gzclose(out);

    gzFile in = gzopen(at("lines.gz"), "rb");
    if (!in) return;

    char line[128];
    for (int i = 0; i < 4; i++) {
        char *got = gzgets(in, line, sizeof line);
        printf("gzgets %d         %s\n", i, got ? got : "(null)\n");
    }

    gzrewind(in);
    int c1 = gzgetc(in);
    printf("gzgetc           %d\n", c1);
    printf("gzungetc         %d\n", gzungetc(c1, in));
    printf("gztell after ungetc %ld\n", (long)gztell(in));
    int c2 = gzgetc(in);
    printf("gzgetc again     %d\n", c2);
    printf("gzgetc_          %d\n", gzgetc_(in));
    gzclose(in);
}

/* Seeking, which for a compressed stream means decompressing to get there. */
static void seeking(const unsigned char *data, size_t len) {
    gzFile in = gzopen(at("roundtrip.gz"), "rb");
    if (!in) return;

    static const long targets[] = { 0, 1, 100, 2000, 500, 0 };
    unsigned char byte;

    for (size_t t = 0; t < sizeof targets / sizeof targets[0]; t++) {
        long where = (long)gzseek(in, targets[t], SEEK_SET);
        int got = gzread(in, &byte, 1);
        printf("gzseek %-5ld     at=%ld read=%d correct=%d\n", targets[t], where, got,
               got == 1 && (size_t)targets[t] < len && byte == data[targets[t]]);
    }

    printf("gzseek cur       %ld\n", (long)gzseek(in, 10, SEEK_CUR));
    printf("gzseek end       %ld\n", (long)gzseek(in, 0, SEEK_END));
    printf("gzrewind         %d tell=%ld\n", gzrewind(in), (long)gztell(in));
    gzclose(in);
}

/* A file that is not gzip at all is copied through rather than refused, which is what makes
 * zcat work on a plain text file. */
static void transparent(const unsigned char *data, size_t len) {
    FILE *raw = fopen(at("plain.txt"), "wb");
    if (!raw) return;
    fwrite(data, 1, len, raw);
    fclose(raw);

    gzFile in = gzopen(at("plain.txt"), "rb");
    printf("plain gzopen     %d\n", in != NULL);
    if (!in) return;

    unsigned char *back = malloc(len + 64);
    size_t total = 0;
    for (;;) {
        int got = gzread(in, back + total, 4096);
        if (got <= 0) break;
        total += (size_t)got;
        if (total > len) break;
    }

    printf("plain direct     %d\n", gzdirect(in));
    printf("plain read       %lu identical=%d\n", (unsigned long)total,
           total == len && memcmp(back, data, len) == 0);
    gzclose(in);
    free(back);
}

/* Several members one after another read as their concatenation. */
static void multi_member(const unsigned char *data, size_t len) {
    for (int part = 0; part < 2; part++) {
        gzFile out = gzopen(at(part == 0 ? "part0.gz" : "part1.gz"), "wb");
        if (!out) return;
        gzwrite(out, data, (unsigned)(len / 2));
        gzclose(out);
    }

    FILE *joined = fopen(at("joined.gz"), "wb");
    if (!joined) return;
    for (int part = 0; part < 2; part++) {
        FILE *f = fopen(at(part == 0 ? "part0.gz" : "part1.gz"), "rb");
        if (!f) { fclose(joined); return; }
        unsigned char buf[4096];
        size_t got;
        while ((got = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, got, joined);
        fclose(f);
    }
    fclose(joined);

    gzFile in = gzopen(at("joined.gz"), "rb");
    if (!in) return;

    unsigned char *back = malloc(len + 64);
    size_t total = 0;
    for (;;) {
        int got = gzread(in, back + total, 4096);
        if (got <= 0) break;
        total += (size_t)got;
        if (total > len + 8) break;
    }

    size_t half = len / 2;
    printf("multi-member     %lu expected=%lu identical=%d\n",
           (unsigned long)total, (unsigned long)(half * 2),
           total == half * 2 && memcmp(back, data, half) == 0
           && memcmp(back + half, data, half) == 0);
    gzclose(in);
    free(back);
}

/* Items rather than bytes, and a partial item at the end that must not be counted. */
static void item_api(const unsigned char *data, size_t len) {
    gzFile out = gzopen(at("items.gz"), "wb");
    if (!out) return;
    printf("gzfwrite         %lu\n", (unsigned long)gzfwrite(data, 7, len / 7, out));
    gzclose(out);

    gzFile in = gzopen(at("items.gz"), "rb");
    if (!in) return;
    unsigned char *back = malloc(len + 64);
    printf("gzfread          %lu\n", (unsigned long)gzfread(back, 7, len / 7, in));
    printf("gzfread partial  %lu\n", (unsigned long)gzfread(back, 1000000, 1, in));
    gzclose(in);
    free(back);
}

static void errors_and_options(const unsigned char *data, size_t len) {
    printf("gzopen missing   %d\n", gzopen(at("does-not-exist.gz"), "rb") != NULL);
    printf("gzopen bad mode  %d\n", gzopen(at("roundtrip.gz"), "q") != NULL);

    gzFile out = gzopen(at("buffered.gz"), "wb");
    if (out) {
        printf("gzbuffer early   %d\n", gzbuffer(out, 65536));
        gzwrite(out, data, (unsigned)len);
        printf("gzbuffer late    %d\n", gzbuffer(out, 4096));
        printf("gzflush          %d\n", gzflush(out, Z_SYNC_FLUSH));
        printf("gzsetparams      %d\n", gzsetparams(out, 1, Z_DEFAULT_STRATEGY));
        gzwrite(out, data, (unsigned)len);
        printf("gzclose_w        %d\n", gzclose_w(out));
        printf("SIZE: buffered      %ld\n", file_size(at("buffered.gz")));
    }

    gzFile in = gzopen(at("buffered.gz"), "rb");
    if (in) {
        unsigned char *back = malloc(len * 2 + 64);
        size_t total = 0;
        for (;;) {
            int got = gzread(in, back + total, 4096);
            if (got <= 0) break;
            total += (size_t)got;
            if (total > len * 2) break;
        }
        printf("params read back %lu identical=%d\n", (unsigned long)total,
               total == len * 2 && memcmp(back, data, len) == 0
               && memcmp(back + len, data, len) == 0);
        printf("gzclose_r        %d\n", gzclose_r(in));
        free(back);
    }

    /* A file that starts like a gzip member and then is not one. */
    FILE *bad = fopen(at("bad.gz"), "wb");
    if (bad) {
        static const unsigned char junk[] = { 0x1f, 0x8b, 0x08, 0x00, 1, 2, 3, 4, 5, 6, 7, 8 };
        fwrite(junk, 1, sizeof junk, bad);
        fclose(bad);

        gzFile broken = gzopen(at("bad.gz"), "rb");
        if (broken) {
            unsigned char buf[64];
            int got = gzread(broken, buf, sizeof buf);
            int errnum = 0;
            gzerror(broken, &errnum);
            printf("corrupt read     %d err=%d\n", got, errnum < 0);
            gzclearerr(broken);
            gzerror(broken, &errnum);
            printf("after clearerr   %d\n", errnum);
            gzclose(broken);
        }
    }
}

int main(int argc, char **argv) {
    snprintf(dir, sizeof dir, "%s", argc > 1 ? argv[1] : ".");

    unsigned char payload[8192];
    size_t len = build_payload(payload, sizeof payload);
    printf("payload %lu\n", (unsigned long)len);

    for (int level = 0; level <= 9; level += 3) {
        write_then_read(payload, len, level);
    }

    chunked_reads(payload, len);
    character_api();
    seeking(payload, len);
    transparent(payload, len);
    multi_member(payload, len);
    item_api(payload, len);
    errors_and_options(payload, len);

    return 0;
}
