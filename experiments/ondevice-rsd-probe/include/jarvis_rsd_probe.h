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
    JARVIS_DTX_CHANNEL_DTSERVICEHUB = 1u << 0,
    JARVIS_DTX_CHANNEL_TESTMANAGER_CTRL = 1u << 1,
    JARVIS_DTX_CHANNEL_TESTMANAGER_MAIN = 1u << 2,
};

enum {
    JARVIS_XCTESTMANAGER_PROXY_CONTROL = 1u << 0,
    JARVIS_XCTESTMANAGER_PROXY_MAIN = 1u << 1,
    JARVIS_FIXED_WDA_CONTROLLER_ACTIVE = 1u << 0,
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
    JARVIS_RSD_STAGE_DTX_RSD_TCP = 20,
    JARVIS_RSD_STAGE_DTX_RSD_HANDSHAKE = 21,
    JARVIS_RSD_STAGE_DTX_DTSERVICEHUB_TCP = 22,
    JARVIS_RSD_STAGE_DTX_DTSERVICEHUB_HANDSHAKE = 23,
    JARVIS_RSD_STAGE_DTX_TESTMANAGER_CTRL_TCP = 24,
    JARVIS_RSD_STAGE_DTX_TESTMANAGER_CTRL_HANDSHAKE = 25,
    JARVIS_RSD_STAGE_DTX_TESTMANAGER_MAIN_TCP = 26,
    JARVIS_RSD_STAGE_DTX_TESTMANAGER_MAIN_HANDSHAKE = 27,
    JARVIS_RSD_STAGE_DTX_COMPLETE = 28,
    JARVIS_RSD_STAGE_PROXY_RSD_TCP = 30,
    JARVIS_RSD_STAGE_PROXY_RSD_HANDSHAKE = 31,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_CTRL_TCP = 32,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_CTRL_HANDSHAKE = 33,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_MAIN_TCP = 34,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_MAIN_HANDSHAKE = 35,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_CTRL_CHANNEL = 36,
    JARVIS_RSD_STAGE_PROXY_TESTMANAGER_MAIN_CHANNEL = 37,
    JARVIS_RSD_STAGE_PROXY_COMPLETE = 38,
    JARVIS_RSD_STAGE_CONTROLLER_RSD_TCP = 40,
    JARVIS_RSD_STAGE_CONTROLLER_RSD_HANDSHAKE = 41,
    JARVIS_RSD_STAGE_CONTROLLER_INSTALLATION_PROXY = 42,
    JARVIS_RSD_STAGE_CONTROLLER_RUNNER_LOOKUP = 43,
    JARVIS_RSD_STAGE_CONTROLLER_DTSERVICEHUB = 44,
    JARVIS_RSD_STAGE_CONTROLLER_TESTMANAGER_CTRL = 45,
    JARVIS_RSD_STAGE_CONTROLLER_TESTMANAGER_MAIN = 46,
    JARVIS_RSD_STAGE_CONTROLLER_PROXY_CHANNELS = 47,
    JARVIS_RSD_STAGE_CONTROLLER_SESSION_INIT = 48,
    JARVIS_RSD_STAGE_CONTROLLER_RUNNER_LAUNCH = 49,
    JARVIS_RSD_STAGE_CONTROLLER_RUNNER_AUTHORIZATION = 50,
    JARVIS_RSD_STAGE_CONTROLLER_DRIVER_CHANNEL = 51,
    JARVIS_RSD_STAGE_CONTROLLER_START_TEST_PLAN = 52,
    JARVIS_RSD_STAGE_CONTROLLER_ACTIVE = 53,
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

typedef struct JarvisDtxProbeResult {
    uint32_t abi_version;
    uint32_t stage;
    int32_t error_code;
    int32_t error_subcode;
    uint32_t channel_mask;
} JarvisDtxProbeResult;

/** Validate a bounded RPPairing record without I/O. Returns 1 or 0. */
int32_t jarvis_rsd_pairing_record_is_valid(const uint8_t *data, size_t length);

/**
 * Execute one read-only probe to the compile-time endpoint 10.7.0.1:49152.
 * Returns 0 only after RSD handshake, otherwise -1 with a sanitized result.
 */
int32_t jarvis_rsd_probe(const uint8_t *data,
                         size_t length,
                         JarvisRsdProbeResult *output);

/** Open and retain one bounded verify-only adapter for warm continuity. */
int32_t jarvis_rsd_hold_start(const uint8_t *data,
                              size_t length,
                              JarvisRsdProbeResult *output);

/** Re-run only the RSD handshake over the retained adapter. */
int32_t jarvis_rsd_hold_check(JarvisRsdProbeResult *output);

/** Perform only three fixed DTX capability handshakes, then close them. */
int32_t jarvis_rsd_hold_dtx_probe(JarvisDtxProbeResult *output);

/** Open and close exactly two fixed XCTestManager proxy channels. */
int32_t jarvis_rsd_hold_xctestmanager_proxy_probe(JarvisDtxProbeResult *output);

/** Start the fixed on-device XCTest controller and WDA runner. */
int32_t jarvis_rsd_hold_fixed_wda_start(JarvisDtxProbeResult *output);

/** Return the current sanitized controller-bootstrap stage. */
uint32_t jarvis_rsd_fixed_wda_progress(void);

/** Check whether the fixed XCTest controller task is active. */
int32_t jarvis_rsd_fixed_wda_check(JarvisDtxProbeResult *output);

/** Abort the fixed XCTest controller task. */
int32_t jarvis_rsd_fixed_wda_stop(void);

/** Drop the retained adapter and fixed controller. */
int32_t jarvis_rsd_hold_stop(void);

#ifdef __cplusplus
}
#endif

#endif
