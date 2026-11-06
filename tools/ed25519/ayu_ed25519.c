/*
 * ayu-ed25519 — minimal Ed25519 sign/verify helper for Ayu.Core
 *
 * Why this exists: the runtime container is busybox:musl with no openssl,
 * no python and no package manager. QQ Bot webhook validation (op=13) and
 * callback signature checks both require Ed25519 with the BotSecret seed,
 * so we ship one tiny statically linked binary under var/tools/.
 *
 * Usage:
 *   ayu-ed25519 sign   <secret> <msg-file>            → hex signature (stdout)
 *   ayu-ed25519 verify <secret> <msg-file> <sig-hex>  → exit 0 ok / 1 bad
 *   ayu-ed25519 pubkey <secret>                       → hex public key
 *
 * Seed derivation follows the official QQ Bot demo:
 *   seed = secret repeated until len >= 32, then truncated to 32 bytes.
 *
 * Build: sh tools/build_ed25519.sh   (needs libssl-dev, produces static bin)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/evp.h>

#define SEED_LEN 32
#define SIG_LEN  64

static int read_file(const char *path, unsigned char **out, size_t *outlen)
{
	FILE *f = fopen(path, "rb");
	long n;
	unsigned char *buf;

	if (!f) {
		fprintf(stderr, "ayu-ed25519: cannot open %s\n", path);
		return -1;
	}
	if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
	n = ftell(f);
	if (n < 0) { fclose(f); return -1; }
	rewind(f);
	buf = malloc((size_t)n + 1);
	if (!buf) { fclose(f); return -1; }
	if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
		free(buf); fclose(f);
		fprintf(stderr, "ayu-ed25519: short read %s\n", path);
		return -1;
	}
	fclose(f);
	buf[n] = 0;
	*out = buf;
	*outlen = (size_t)n;
	return 0;
}

/* build_seed: secret repeated until >= 32 bytes, truncated to 32 */
static int build_seed(const char *secret, unsigned char seed[SEED_LEN])
{
	size_t slen = strlen(secret), i = 0;

	if (slen == 0) {
		fprintf(stderr, "ayu-ed25519: empty secret\n");
		return -1;
	}
	while (i < SEED_LEN) {
		size_t n = SEED_LEN - i;
		if (n > slen) n = slen;
		memcpy(seed + i, secret, n);
		i += n;
	}
	return 0;
}

static void print_hex(const unsigned char *b, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++) printf("%02x", b[i]);
}

static int parse_hex(const char *hex, unsigned char *out, size_t want)
{
	size_t n = strlen(hex), i;
	unsigned int v;

	if (n != want * 2) return -1;
	for (i = 0; i < want; i++) {
		if (sscanf(hex + i * 2, "%2x", &v) != 1) return -1;
		out[i] = (unsigned char)v;
	}
	return 0;
}

int main(int argc, char **argv)
{
	unsigned char seed[SEED_LEN];
	const char *secret;
	unsigned char *msg = NULL;
	size_t msglen = 0;
	EVP_PKEY *pkey = NULL;
	EVP_MD_CTX *ctx = NULL;
	int rc = 1;

	if (argc < 3) {
		fprintf(stderr,
			"usage: ayu-ed25519 sign <secret> <msg-file>\n"
			"       ayu-ed25519 verify <secret> <msg-file> <sig-hex>\n"
			"       ayu-ed25519 pubkey <secret>\n");
		return 2;
	}
	/* "-" → take the secret from AYU_ED25519_SECRET, so it never shows up
	 * in the process table (argv) while the CGI handler is running. */
	secret = argv[2];
	if (strcmp(secret, "-") == 0) {
		secret = getenv("AYU_ED25519_SECRET");
		if (!secret) {
			fprintf(stderr, "ayu-ed25519: AYU_ED25519_SECRET not set\n");
			return 2;
		}
	}
	if (build_seed(secret, seed) != 0) return 2;

	pkey = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, seed, SEED_LEN);
	if (!pkey) {
		fprintf(stderr, "ayu-ed25519: key init failed\n");
		goto done;
	}

	if (strcmp(argv[1], "pubkey") == 0) {
		unsigned char pub[SEED_LEN];
		size_t publen = sizeof(pub);
		if (EVP_PKEY_get_raw_public_key(pkey, pub, &publen) != 1) goto done;
		print_hex(pub, publen);
		printf("\n");
		rc = 0;
		goto done;
	}

	if (read_file(argv[3], &msg, &msglen) != 0) goto done;

	if (strcmp(argv[1], "sign") == 0 && argc >= 4) {
		unsigned char sig[SIG_LEN];
		size_t siglen = sizeof(sig);

		ctx = EVP_MD_CTX_new();
		if (!ctx) goto done;
		if (EVP_DigestSignInit(ctx, NULL, NULL, NULL, pkey) != 1) goto done;
		if (EVP_DigestSign(ctx, sig, &siglen, msg, msglen) != 1) goto done;
		print_hex(sig, siglen);
		printf("\n");
		rc = 0;
	} else if (strcmp(argv[1], "verify") == 0 && argc >= 5) {
		unsigned char sig[SIG_LEN], pub[SEED_LEN];
		EVP_PKEY *pubkey = NULL;
		size_t publen = sizeof(pub), siglen = sizeof(sig);

		if (parse_hex(argv[4], sig, SIG_LEN) != 0) {
			fprintf(stderr, "ayu-ed25519: bad signature hex\n");
			goto done;
		}
		/* QQ rejects signatures whose top 3 bits are set (sig[63] & 224). */
		if (sig[63] & 224) {
			fprintf(stderr, "ayu-ed25519: non-canonical signature\n");
			goto done;
		}
		if (EVP_PKEY_get_raw_public_key(pkey, pub, &publen) != 1) goto done;
		pubkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, pub, publen);
		if (!pubkey) goto done;

		ctx = EVP_MD_CTX_new();
		if (!ctx) { EVP_PKEY_free(pubkey); goto done; }
		if (EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, pubkey) != 1) {
			EVP_PKEY_free(pubkey); goto done;
		}
		rc = (EVP_DigestVerify(ctx, sig, siglen, msg, msglen) == 1) ? 0 : 1;
		EVP_PKEY_free(pubkey);
	} else {
		fprintf(stderr, "ayu-ed25519: unknown command %s\n", argv[1]);
		rc = 2;
	}

done:
	if (ctx) EVP_MD_CTX_free(ctx);
	if (pkey) EVP_PKEY_free(pkey);
	free(msg);
	return rc;
}
