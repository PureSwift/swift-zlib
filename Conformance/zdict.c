/* Differential conformance for what completed the API: dictionaries, params, prime, copy,
 * sync, inflateBack, and the introspection calls.
 *
 * Compiled twice and diffed, as ever. Where a value is honest to differ — inflateMark's bit
 * accounting, sizes — it is either not printed or printed as SIZE:.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

static size_t build_payload(unsigned char *out, size_t cap) {
    size_t n = 0;
    for (int r = 0; r < 50 && n + 60 < cap; r++) {
        n += (size_t)snprintf((char *)out + n, cap - n,
                              "GET /api/v1/items/%d HTTP/1.1\r\nHost: example.com\r\n\r\n", r);
    }
    return n;
}

/* The dictionary is the kind of text the payload shares its vocabulary with. */
static const char dictionary[] =
    "GET /api/v1/items/ HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n";

static void dictionary_roundtrip(const unsigned char *data, size_t len) {
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit(&def, 6) != Z_OK) return;

    printf("setDictionary    %d\n",
           deflateSetDictionary(&def, (const Bytef *)dictionary, sizeof dictionary - 1));
    printf("dict adler       %08lx\n", def.adler);

    unsigned char with_dict[8192];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)len;
    def.next_out = with_dict;
    def.avail_out = sizeof with_dict;
    int rc = deflate(&def, Z_FINISH);
    size_t with_len = sizeof with_dict - def.avail_out;
    printf("deflate w/dict   %d\n", rc);
    printf("SIZE: with dict  %lu\n", (unsigned long)with_len);

    /* Reading the dictionary back mid-stream. */
    unsigned char got[65536];
    uInt got_len = 0;
    printf("getDictionary    %d\n", deflateGetDictionary(&def, got, &got_len));
    printf("dict tail ok     %d\n",
           got_len >= len ? memcmp(got + got_len - len, data, len) == 0 : -1);
    deflateEnd(&def);

    /* Without, so the benefit is visible in the SIZE lines. */
    memset(&def, 0, sizeof def);
    deflateInit(&def, 6);
    unsigned char without[8192];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)len;
    def.next_out = without;
    def.avail_out = sizeof without;
    deflate(&def, Z_FINISH);
    printf("SIZE: no dict    %lu\n", (unsigned long)(sizeof without - def.avail_out));
    deflateEnd(&def);

    /* Decompressing: the stream stops, names the dictionary, takes it, carries on. */
    z_stream inf;
    memset(&inf, 0, sizeof inf);
    if (inflateInit(&inf) != Z_OK) return;

    unsigned char back[8192];
    inf.next_in = with_dict;
    inf.avail_in = (uInt)with_len;
    inf.next_out = back;
    inf.avail_out = sizeof back;

    rc = inflate(&inf, Z_NO_FLUSH);
    printf("inflate needdict %d adler=%08lx\n", rc, inf.adler);

    /* The wrong dictionary first, which has to be refused. */
    printf("wrong dict       %d\n",
           inflateSetDictionary(&inf, (const Bytef *)"not the dictionary", 18));
    printf("right dict       %d\n",
           inflateSetDictionary(&inf, (const Bytef *)dictionary, sizeof dictionary - 1));

    rc = inflate(&inf, Z_FINISH);
    size_t back_len = sizeof back - inf.avail_out;
    printf("inflate w/dict   %d identical=%d\n", rc,
           back_len == len && memcmp(back, data, len) == 0);

    got_len = 0;
    printf("inf getDict      %d\n", inflateGetDictionary(&inf, got, &got_len));
    inflateEnd(&inf);
}

static void params_and_copy(const unsigned char *data, size_t len) {
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit(&def, 1) != Z_OK) return;

    unsigned char out[16384];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)(len / 2);
    def.next_out = out;
    def.avail_out = sizeof out;

    printf("deflate half     %d\n", deflate(&def, Z_NO_FLUSH));
    printf("deflateParams    %d\n", deflateParams(&def, 9, Z_DEFAULT_STRATEGY));

    /* A copy taken mid-stream: both must finish independently and identically. */
    z_stream dup;
    memset(&dup, 0, sizeof dup);
    printf("deflateCopy      %d\n", deflateCopy(&dup, &def));

    unsigned char out2[16384];
    memcpy(out2, out, sizeof out);
    dup.next_out = out2 + (dup.total_out - (uLong)(sizeof out - def.avail_out) + sizeof out - def.avail_out);
    dup.next_out = out2 + (sizeof out - def.avail_out);
    dup.avail_out = (uInt)(sizeof out2 - (sizeof out - def.avail_out));

    def.next_in = (Bytef *)data + len / 2;
    def.avail_in = (uInt)(len - len / 2);
    dup.next_in = (Bytef *)data + len / 2;
    dup.avail_in = (uInt)(len - len / 2);

    int rc1 = deflate(&def, Z_FINISH);
    int rc2 = deflate(&dup, Z_FINISH);
    size_t len1 = sizeof out - def.avail_out;
    size_t len2 = sizeof out2 - dup.avail_out;

    printf("finish both      %d %d same=%d\n", rc1, rc2,
           len1 == len2 && memcmp(out, out2, len1) == 0);

    /* Both decode to the payload through the reference of whichever build this is. */
    z_stream inf;
    memset(&inf, 0, sizeof inf);
    inflateInit(&inf);
    unsigned char back[16384];
    inf.next_in = out;
    inf.avail_in = (uInt)len1;
    inf.next_out = back;
    inf.avail_out = sizeof back;
    rc1 = inflate(&inf, Z_FINISH);
    printf("copy decodes     %d identical=%d\n", rc1,
           (size_t)(sizeof back - inf.avail_out) == len
           && memcmp(back, data, len) == 0);
    inflateEnd(&inf);

    deflateEnd(&def);
    deflateEnd(&dup);

    /* inflateCopy, across a split point. */
    memset(&def, 0, sizeof def);
    deflateInit(&def, 6);
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)len;
    def.next_out = out;
    def.avail_out = sizeof out;
    deflate(&def, Z_FINISH);
    size_t packed_len = sizeof out - def.avail_out;
    deflateEnd(&def);

    memset(&inf, 0, sizeof inf);
    inflateInit(&inf);
    inf.next_in = out;
    inf.avail_in = (uInt)(packed_len / 2);
    inf.next_out = back;
    inf.avail_out = sizeof back;
    inflate(&inf, Z_NO_FLUSH);

    z_stream infdup;
    memset(&infdup, 0, sizeof infdup);
    printf("inflateCopy      %d\n", inflateCopy(&infdup, &inf));

    unsigned char back2[16384];
    memcpy(back2, back, sizeof back);
    infdup.next_out = back2 + (sizeof back - inf.avail_out);
    infdup.avail_out = inf.avail_out;

    inf.next_in = out + packed_len / 2;
    inf.avail_in = (uInt)(packed_len - packed_len / 2);
    infdup.next_in = out + packed_len / 2;
    infdup.avail_in = (uInt)(packed_len - packed_len / 2);

    rc1 = inflate(&inf, Z_FINISH);
    rc2 = inflate(&infdup, Z_FINISH);
    printf("both finish      %d %d same=%d\n", rc1, rc2,
           inf.avail_out == infdup.avail_out
           && memcmp(back, back2, sizeof back - inf.avail_out) == 0);
    inflateEnd(&inf);
    inflateEnd(&infdup);
}

static void prime_roundtrip(const unsigned char *data, size_t len) {
    /* deflatePrime injects bits ahead of a raw stream; inflatePrime hands them back. The pair
     * is its own test: a stream primed with n bits decodes only if the decoder is primed with
     * the same n. */
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit2(&def, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return;

    printf("deflatePrime     %d\n", deflatePrime(&def, 5, 0x15));

    unsigned char out[16384];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)len;
    def.next_out = out;
    def.avail_out = sizeof out;
    int rc = deflate(&def, Z_FINISH);
    size_t packed_len = sizeof out - def.avail_out;
    printf("primed deflate   %d\n", rc);
    printf("primed low bits  %02x\n", out[0] & 0x1F);
    deflateEnd(&def);

    z_stream inf;
    memset(&inf, 0, sizeof inf);
    if (inflateInit2(&inf, -15) != Z_OK) return;

    /* The decoder consumes the five primed bits by being handed them directly, then reads the
     * stream from the byte after: which is to say, the first byte's remaining bits arrive via
     * inflatePrime too. */
    printf("inflatePrime     %d\n", inflatePrime(&inf, 3, (out[0] >> 5) & 0x7));

    unsigned char back[16384];
    inf.next_in = out + 1;
    inf.avail_in = (uInt)(packed_len - 1);
    inf.next_out = back;
    inf.avail_out = sizeof back;
    rc = inflate(&inf, Z_FINISH);
    printf("primed inflate   %d identical=%d\n", rc,
           (size_t)(sizeof back - inf.avail_out) == len && memcmp(back, data, len) == 0);
    inflateEnd(&inf);
}

static void sync_recovery(const unsigned char *data, size_t len) {
    /* A stream with a full flush in the middle, damaged before it: inflateSync finds the
     * marker and decoding resumes with the second half. */
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit(&def, 6) != Z_OK) return;

    unsigned char out[16384];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)(len / 2);
    def.next_out = out;
    def.avail_out = sizeof out;
    deflate(&def, Z_FULL_FLUSH);

    def.next_in = (Bytef *)data + len / 2;
    def.avail_in = (uInt)(len - len / 2);
    deflate(&def, Z_FINISH);
    size_t packed_len = sizeof out - def.avail_out;
    deflateEnd(&def);

    /* Corrupt a byte early in the first half. */
    out[8] ^= 0xFF;

    z_stream inf;
    memset(&inf, 0, sizeof inf);
    inflateInit(&inf);

    unsigned char back[16384];
    inf.next_in = out;
    inf.avail_in = (uInt)packed_len;
    inf.next_out = back;
    inf.avail_out = sizeof back;

    int rc = inflate(&inf, Z_NO_FLUSH);
    printf("corrupt inflate  %d\n", rc < 0);

    rc = inflateSync(&inf);
    printf("inflateSync      %d\n", rc);
    printf("syncPoint        %d\n", inflateSyncPoint(&inf));

    if (rc == Z_OK) {
        /* What follows the marker decodes; its content is the second half of the payload. The
         * checksum cannot match a half stream, so validation is what inflateValidate is for. */
        inflateValidate(&inf, 0);
        rc = inflate(&inf, Z_FINISH);
        size_t got = sizeof back - inf.avail_out;
        printf("resumed          rc>=0=%d got=%lu tailok=%d\n", rc >= 0,
               (unsigned long)got,
               got == len - len / 2 && memcmp(back, data + len / 2, got) == 0);
    }
    inflateEnd(&inf);
}

/* inflateBack: the callback-driven convention, run over a raw stream. */
static unsigned in_offset;
static unsigned char *in_data;
static unsigned in_len;

static unsigned pull(void *desc, unsigned char **buf) {
    (void)desc;
    if (in_offset >= in_len) return 0;
    *buf = in_data + in_offset;
    unsigned give = in_len - in_offset < 97 ? in_len - in_offset : 97;
    in_offset += give;
    return give;
}

static unsigned char pushed[65536];
static unsigned pushed_len;

static int push(void *desc, unsigned char *buf, unsigned len) {
    (void)desc;
    if (pushed_len + len > sizeof pushed) return 1;
    memcpy(pushed + pushed_len, buf, len);
    pushed_len += len;
    return 0;
}

static void back_api(const unsigned char *data, size_t len) {
    z_stream def;
    memset(&def, 0, sizeof def);
    if (deflateInit2(&def, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return;

    static unsigned char packed[16384];
    def.next_in = (Bytef *)data;
    def.avail_in = (uInt)len;
    def.next_out = packed;
    def.avail_out = sizeof packed;
    deflate(&def, Z_FINISH);
    unsigned packed_len = (unsigned)(sizeof packed - def.avail_out);
    deflateEnd(&def);

    static unsigned char window[32768];
    z_stream inf;
    memset(&inf, 0, sizeof inf);
    printf("backInit         %d\n", inflateBackInit(&inf, 15, window));

    in_data = packed;
    in_len = packed_len;
    in_offset = 0;
    pushed_len = 0;

    int rc = inflateBack(&inf, pull, NULL, push, NULL);
    printf("inflateBack      %d identical=%d\n", rc,
           pushed_len == len && memcmp(pushed, data, len) == 0);
    printf("backEnd          %d\n", inflateBackEnd(&inf));
}

static void introspection(void) {
    z_stream inf;
    memset(&inf, 0, sizeof inf);
    inflateInit(&inf);

    /* Only what is contractual: the error values for a stream that is not one, and that a
     * fresh stream answers at all. The in-stream values are the reference's own accounting. */
    printf("mark no stream   %ld\n", inflateMark(NULL));
    printf("codes no stream  %d\n", inflateCodesUsed(NULL) == (unsigned long)-1);
    printf("undermine        %d\n", inflateUndermine(&inf, 1) < 0);

    const z_crc_t *table = get_crc_table();
    printf("crc table        %d %08lx %08lx\n", table != NULL,
           (unsigned long)table[1], (unsigned long)table[255]);
    inflateEnd(&inf);
}

int main(void) {
    unsigned char payload[8192];
    size_t len = build_payload(payload, sizeof payload);
    printf("payload %lu\n", (unsigned long)len);

    dictionary_roundtrip(payload, len);
    params_and_copy(payload, len);
    prime_roundtrip(payload, len);
    sync_recovery(payload, len);
    back_api(payload, len);
    introspection();

    return 0;
}
