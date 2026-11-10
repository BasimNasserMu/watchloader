#ifndef WLCORE_H
#define WLCORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*wl_progress_cb)(void *ctx, const char *status, int32_t percent);

/// Step-by-step connectivity report (TCP, lockdown, TLS session, heartbeat) for each
/// comma-separated address. Always returns 0; the report is written into `out`.
int32_t wl_diagnose(const char *addresses, const char *phone_pairing, char *out, size_t out_len);

/// Connect to the iPhone (via loopback VPN) and through it to the paired watch.
/// Writes a human-readable result or error into `out`. Returns 0 on success.
int32_t wl_probe(const char *phone_ip, const char *phone_pairing, const char *watch_pairing,
                 char *out, size_t out_len);

/// Install a watch-only IPA (Payload/<App>.app) on the paired Apple Watch.
/// `cb` is called synchronously on the calling thread with progress updates.
int32_t wl_install(const char *phone_ip, const char *phone_pairing, const char *watch_pairing,
                   const char *ipa_path, wl_progress_cb cb, void *ctx, char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
