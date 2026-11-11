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

/// 2FA prompt. method: 0 = code on trusted devices, 1 = SMS. phones: "•• 12, •• 34" (may be "").
/// Write the code (or "sms" to request a text) into code_out and return 0; non-zero cancels.
typedef int32_t (*wl_tfa_cb)(void *ctx, int32_t method, const char *phones, char *code_out, size_t code_len);

/// Sign in with an Apple ID. out = "email\nfirst name\nteam id" on success. Returns 0 on success.
int32_t wl_login(const char *email, const char *password, const char *config_dir,
                 wl_tfa_cb tfa_cb, void *ctx, char *out, size_t out_len);

/// Signed-in account ("email\nfirst name\nteam id"); returns -1 if not signed in.
int32_t wl_account(const char *config_dir, char *out, size_t out_len);

/// Sign out (removes the stored token).
int32_t wl_logout(const char *config_dir, char *out, size_t out_len);

/// Re-sign a watch-only IPA in place with a fresh 7-day profile. watch_udid may be "" (then it is
/// read through the iPhone's companion registry, which needs the loopback VPN).
int32_t wl_resign(const char *config_dir, const char *phone_ip, const char *phone_pairing,
                  const char *watch_pairing, const char *watch_udid, const char *ipa_path,
                  wl_progress_cb cb, void *ctx, char *out, size_t out_len);

/// Read an IPA's metadata (bundle name/id/version, profile ExpirationDate/TeamName/DeviceCount,
/// IsWatchApp). Writes an XML plist into `out`. Returns 0 on success.
int32_t wl_ipa_info(const char *ipa_path, char *out, size_t out_len);

/// Install a watch-only IPA (Payload/<App>.app) on the paired Apple Watch.
/// `cb` is called synchronously on the calling thread with progress updates.
int32_t wl_install(const char *phone_ip, const char *phone_pairing, const char *watch_pairing,
                   const char *ipa_path, wl_progress_cb cb, void *ctx, char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
