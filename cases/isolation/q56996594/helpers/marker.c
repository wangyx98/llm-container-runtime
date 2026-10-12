/* marker NONCE : the program of the image. Prints (stdout)
 *   nonce=NONCE / hash=SHA256(salt+NONCE) / uid=.. gid=.. / pid=..
 * salt = the content of /etc/marker-salt in the image (two images differ by it). Then it stays alive for 4 s (so that the lab can look at the
 * process from the host) and exits 0. Static, no libc dependencies other than the system calls. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha_t;
static const uint32_t K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))
static void block(sha_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2; int i;
    for (i = 0; i < 16; i++) w[i] = (uint32_t)p[4*i] << 24 | p[4*i+1] << 16 | p[4*i+2] << 8 | p[4*i+3];
    for (i = 16; i < 64; i++) { uint32_t s0 = ROR(w[i-15],7) ^ ROR(w[i-15],18) ^ (w[i-15] >> 3), s1 = ROR(w[i-2],17) ^ ROR(w[i-2],19) ^ (w[i-2] >> 10); w[i] = w[i-16] + s0 + w[i-7] + s1; }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (i = 0; i < 64; i++) {
        t1 = h + (ROR(e,6) ^ ROR(e,11) ^ ROR(e,25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        t2 = (ROR(a,2) ^ ROR(a,13) ^ ROR(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
static void init(sha_t *s) { static const uint32_t i0[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}; memcpy(s->h, i0, 32); s->len = 0; s->n = 0; }
static void add(sha_t *s, const void *d, size_t n) { const uint8_t *p = d; while (n--) { s->buf[s->n++] = *p++; s->len++; if (s->n == 64) { block(s, s->buf); s->n = 0; } } }
static void done(sha_t *s, char *hex) {
    uint64_t bits = s->len * 8; uint8_t pad = 0x80; int i;
    add(s, &pad, 1); pad = 0; while (s->n != 56) add(s, &pad, 1);
    for (i = 7; i >= 0; i--) { uint8_t b = bits >> (8 * i); add(s, &b, 1); }
    for (i = 0; i < 8; i++) sprintf(hex + 8 * i, "%08x", s->h[i]);
}

int main(int argc, char **argv) {
    char salt[256] = "", hex[65]; sha_t s;
    if (argc != 2) { fprintf(stderr, "usage: marker NONCE\n"); return 2; }
    FILE *f = fopen("/etc/marker-salt", "r");
    if (!f || !fgets(salt, sizeof salt, f)) { fprintf(stderr, "marker: no /etc/marker-salt: this is not the image of the lab\n"); return 3; }
    fclose(f);
    salt[strcspn(salt, "\n")] = 0;
    init(&s); add(&s, salt, strlen(salt)); add(&s, argv[1], strlen(argv[1])); done(&s, hex);
    printf("nonce=%s\nhash=%s\nuid=%u\ngid=%u\npid=%d\n", argv[1], hex, (unsigned)geteuid(), (unsigned)getegid(), (int)getpid());
    fflush(stdout);
    sleep(4);
    return 0;
}
