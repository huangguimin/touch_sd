/*
 * pam_sdfinger: sudo with the Touch SD card.
 *
 *   auth  sufficient  /usr/local/lib/pam/pam_sdfinger.so.2      (/etc/pam.d/sudo_local)
 *
 * The Touch SD app (running as the user) listens on
 * ~/Library/Application Support/SD Finger/sudo.sock.  This module sends it a fresh
 * random challenge; the app waits for a press, matches the finger, and asks the card
 * to sign SHA-256("fpcard press v1" | challenge | press id | serial) with its P-256
 * identity key.  The module checks that signature against the card key installed for
 * the user in /etc/sdfinger/<user>.pub (root-owned, written by the app's installer
 * with the administrator password).  Without the app, the card or a valid signature
 * it returns PAM_AUTHINFO_UNAVAIL or PAM_AUTH_ERR and sudo asks for the password.
 *
 * Protocol and design: SudoBridge.swift, docs/SECURITY_DESIGN.md.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define REPLY_TIMEOUT_MS 30000

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int unhex(const char *s, uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        int a = hexval((unsigned char)s[2 * i]), b = hexval((unsigned char)s[2 * i + 1]);
        if (a < 0 || b < 0) return -1;
        out[i] = (uint8_t)(a << 4 | b);
    }
    return 0;
}

static void tohex(const uint8_t *p, size_t n, char *out) {
    static const char h[] = "0123456789abcdef";
    for (size_t i = 0; i < n; ++i) {
        out[2 * i] = h[p[i] >> 4];
        out[2 * i + 1] = h[p[i] & 15];
    }
    out[2 * n] = 0;
}

/* /etc/sdfinger/<user>.pub: "pub=<128 hex>\nserial=<16 hex>\n", root-owned, not writable
 * by anyone else. */
static int load_key(const char *user, uint8_t pub[64], uint8_t serial[8]) {
    char path[256];
    if (snprintf(path, sizeof path, "/etc/sdfinger/%s.pub", user) >= (int)sizeof path) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat st;
    char buf[512];
    ssize_t n = -1;
    if (fstat(fd, &st) == 0 && st.st_uid == 0 && (st.st_mode & 022) == 0 && S_ISREG(st.st_mode)) {
        n = read(fd, buf, sizeof buf - 1);
    }
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = strstr(buf, "pub="), *s = strstr(buf, "serial=");
    if (!p || !s || unhex(p + 4, pub, 64) || unhex(s + 7, serial, 8)) return -1;
    return 0;
}

static int connect_app(const struct passwd *pw) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (snprintf(addr.sun_path, sizeof addr.sun_path, "%s/Library/Application Support/SD Finger/sudo.sock",
                 pw->pw_dir) >= (int)sizeof addr.sun_path) {
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    /* The listener must be the user's own process: not another account's. */
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != pw->pw_uid) {
        close(fd);
        return -1;
    }
    return fd;
}

static int read_line(int fd, char *buf, size_t cap, int timeout_ms) {
    size_t n = 0;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    while (n + 1 < cap) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int left = timeout_ms - (int)((now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000);
        if (left <= 0) return -1;
        struct pollfd p = {fd, POLLIN, 0};
        int r = poll(&p, 1, left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        ssize_t k = read(fd, buf + n, cap - 1 - n);
        if (k <= 0) break;
        n += (size_t)k;
        if (memchr(buf, '\n', n)) break;
    }
    buf[n] = 0;
    return (int)n;
}

static int verify(const uint8_t pub[64], const uint8_t *msg, size_t msg_len, const uint8_t sig[64]) {
    uint8_t x963[65];
    x963[0] = 4;
    memcpy(x963 + 1, pub, 64);
    CFDataRef keydata = CFDataCreate(NULL, x963, sizeof x963);
    const void *k[] = {kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits};
    int bits = 256;
    CFNumberRef nbits = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    const void *v[] = {kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic, nbits};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 3, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    SecKeyRef key = SecKeyCreateWithData(keydata, attrs, NULL);
    int ok = 0;
    if (key) {
        CFDataRef m = CFDataCreate(NULL, msg, (CFIndex)msg_len);
        CFDataRef s = CFDataCreate(NULL, sig, 64);
        ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageRFC4754SHA256, m, s, NULL) ? 1 : 0;
        CFRelease(m);
        CFRelease(s);
        CFRelease(key);
    }
    CFRelease(attrs);
    CFRelease(nbits);
    CFRelease(keydata);
    return ok;
}

static void say(pam_handle_t *pamh, int style, const char *text) {
    const struct pam_conv *conv = NULL;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS || !conv || !conv->conv) return;
    struct pam_message m = {style, (char *)text};
    const struct pam_message *mp = &m;
    struct pam_response *resp = NULL;
    conv->conv(1, &mp, &resp, conv->appdata_ptr);
    if (resp) {
        free(resp->resp);
        free(resp);
    }
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)argc;
    (void)argv;
    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user) return PAM_USER_UNKNOWN;
    struct passwd *pw = getpwnam(user);
    if (!pw) return PAM_USER_UNKNOWN;

    uint8_t pub[64], serial[8];
    if (load_key(user, pub, serial) != 0) return PAM_AUTHINFO_UNAVAIL;
    int fd = connect_app(pw);
    if (fd < 0) return PAM_AUTHINFO_UNAVAIL;

    uint8_t challenge[32];
    arc4random_buf(challenge, sizeof challenge);
    char hex[65], line[512];
    tohex(challenge, 32, hex);
    int n = snprintf(line, sizeof line, "{\"v\":1,\"challenge\":\"%s\",\"user\":\"%s\",\"service\":\"sudo\"}\n", hex,
                     user);
    if (n <= 0 || n >= (int)sizeof line || write(fd, line, (size_t)n) != n) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }
    if (!(flags & PAM_SILENT)) {
        say(pamh, PAM_TEXT_INFO, "Touch SD：请在指纹卡上按一下已录入的手指……");
    }
    char reply[1024];
    int got = read_line(fd, reply, sizeof reply, REPLY_TIMEOUT_MS);
    close(fd);
    if (got <= 0 || !strstr(reply, "\"ok\":true")) {
        if (got > 0 && !(flags & PAM_SILENT)) say(pamh, PAM_TEXT_INFO, "Touch SD：没有通过，改用密码");
        return got > 0 ? PAM_AUTH_ERR : PAM_AUTHINFO_UNAVAIL;
    }
    const char *ps = strstr(reply, "\"press\":"), *ss = strstr(reply, "\"sig\":\"");
    if (!ps || !ss || strlen(ss + 7) < 128) return PAM_AUTH_ERR;
    unsigned long press = strtoul(ps + 8, NULL, 10);
    uint8_t sig[64];
    if (unhex(ss + 7, sig, 64) != 0 || press == 0 || press > 0xFFFFFFFFul) return PAM_AUTH_ERR;

    static const char label[] = "fpcard press v1";
    uint8_t msg[sizeof label - 1 + 32 + 4 + 8];
    memcpy(msg, label, sizeof label - 1);
    memcpy(msg + 15, challenge, 32);
    msg[47] = (uint8_t)press;
    msg[48] = (uint8_t)(press >> 8);
    msg[49] = (uint8_t)(press >> 16);
    msg[50] = (uint8_t)(press >> 24);
    memcpy(msg + 51, serial, 8);
    if (!verify(pub, msg, sizeof msg, sig)) {
        syslog(LOG_AUTH | LOG_WARNING, "pam_sdfinger: bad card signature for %s", user);
        return PAM_AUTH_ERR;
    }
    syslog(LOG_AUTH | LOG_NOTICE, "pam_sdfinger: %s authenticated with the card", user);
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
