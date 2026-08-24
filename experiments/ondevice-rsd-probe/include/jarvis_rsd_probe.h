#ifndef JARVIS_RSD_PROBE_H
#define JARVIS_RSD_PROBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    JARVIS_RSD_SERVICE_TESTMANAGERD = 1u << 0,
    JARVIS_RSD_SERVICE_DTSERVICEHUB = 1u << 1,
    JARVIS_RSD_SERVICE_APP_SERVICE = 1u << 2,
    JARVIS_RSD_SERVICE_INSTALLATION_PROXY = 1u << 3,
};

enum {
    JARVIS_RSD_STAGE_INPUT = 1,
    JARVIS_RSD_STAGE_PAIRING_PARSE = 2,
    JARVIS_RSD_STAGE_TCP_CONNECT = 3,
    JARVIS_RSD_STAGE_PAIR_VERIFY_HELLO = 4,
    JARVIS_RSD_STAGE_PAIR_VERIFY = 5,
    JARVIS_RSD_STAGE_TUNNEL_LISTENER = 6,
    JARVIS_RSD_STAGE_TUNNEL_TCP = 7,
    JARVIS_RSD_STAGE_TUNNEL_TLS = 8,
    JARVIS_RSD_STAGE_TUNNEL_PARAMETERS = 9,
    JARVIS_RSD_STAGE_RSD_TCP = 10,
    JARVIS_RSD_STAGE_RSD_HANDSHAKE = 11,
    JARVIS_RSD_STAGE_COMPLETE = 12,
};

typedef struct JarvisRsdProbeResult {
    uint32_t abi_version;
    uint32_t stage;
    int32_t error_code;
    int32_t error_subcode;
    uint64_t protocol_version;
    uint32_t service_mask;
    uint32_t service_count;
} JarvisRsdProbeResult;

/** Validate a bounded RPPairing record without I/O. Returns 1 or 0. */
int32_t jarvis_rsd_pairing_record_is_valid(const uint8_t *data, size_t length);

/**
 * Execute one read-only probe to the compile-time endpoint 10.7.0.1:49152.
 * Returns 0 only after RSD handshake, otherwise -1 with a sanitized result.
 */
int32_t jarvis_rsd_probe(const uint8_t *data,
                         size_t length,
                         JarvisRsdProbeResult *output);

#ifdef __cplusplus
}
#endif

#endif
