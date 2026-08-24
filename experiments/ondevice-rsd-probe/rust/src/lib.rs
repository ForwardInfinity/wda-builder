//! Narrow, read-only RSD transport probe for the Jarvis experiment.
//!
//! Security properties of this FFI boundary:
//! - the only network destination is the LocalDevVPN fake peer 10.7.0.1:49152;
//! - only pair-verify is attempted; pair-setup and PIN callbacks are unreachable;
//! - no service port, address, pairing record, UUID, or raw error text is returned;
//! - no relay, generic socket, DVT, XCTest, WDA, HID, or process API is exported.

use std::future::Future;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::slice;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use idevice::IdeviceError;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use tokio::net::TcpStream;
use tokio::runtime::{Builder, Runtime};

const ABI_VERSION: u32 = 1;
const MAX_PAIRING_BYTES: usize = 256 * 1024;
const OPERATION_TIMEOUT: Duration = Duration::from_secs(8);
const TARGET: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 7, 0, 1)), 49_152);
const HOSTNAME: &str = "JarvisRSDProbe";

pub const SERVICE_TESTMANAGERD: u32 = 1 << 0;
pub const SERVICE_DTSERVICEHUB: u32 = 1 << 1;
pub const SERVICE_APP_SERVICE: u32 = 1 << 2;
pub const SERVICE_INSTALLATION_PROXY: u32 = 1 << 3;

pub const STAGE_INPUT: u32 = 1;
pub const STAGE_PAIRING_PARSE: u32 = 2;
pub const STAGE_TCP_CONNECT: u32 = 3;
pub const STAGE_PAIR_VERIFY_HELLO: u32 = 4;
pub const STAGE_PAIR_VERIFY: u32 = 5;
pub const STAGE_TUNNEL_LISTENER: u32 = 6;
pub const STAGE_TUNNEL_TCP: u32 = 7;
pub const STAGE_TUNNEL_TLS: u32 = 8;
pub const STAGE_TUNNEL_PARAMETERS: u32 = 9;
pub const STAGE_RSD_TCP: u32 = 10;
pub const STAGE_RSD_HANDSHAKE: u32 = 11;
pub const STAGE_COMPLETE: u32 = 12;

const ERROR_INVALID_INPUT: i32 = -7_001;
const ERROR_PAIRING_MISMATCH: i32 = -7_002;
const ERROR_TIMEOUT: i32 = -7_003;
const ERROR_RUNTIME: i32 = -7_004;
const ERROR_BUSY: i32 = -7_005;
const ERROR_TUNNEL_PARAMETERS: i32 = -7_006;
const ERROR_ADAPTER_CONNECT: i32 = -7_007;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct JarvisRsdProbeResult {
    pub abi_version: u32,
    pub stage: u32,
    pub error_code: i32,
    pub error_subcode: i32,
    pub protocol_version: u64,
    pub service_mask: u32,
    pub service_count: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProbeFailure {
    stage: u32,
    code: i32,
    subcode: i32,
}

impl ProbeFailure {
    fn fixed(stage: u32, code: i32) -> Self {
        Self {
            stage,
            code,
            subcode: 0,
        }
    }

    fn from_socket(stage: u32, error: io::Error) -> Self {
        // Preserve only the bounded numeric errno. No address, payload, raw
        // error text, identifier, or pairing material crosses the FFI.
        let subcode = error
            .raw_os_error()
            .filter(|value| (1..=4_095).contains(value))
            .unwrap_or(-1);
        Self {
            stage,
            code: IdeviceError::Socket(error).code(),
            subcode,
        }
    }

    fn from_idevice(stage: u32, error: IdeviceError) -> Self {
        Self {
            stage,
            code: error.code(),
            subcode: error.sub_code(),
        }
    }
}

static RUNTIME: OnceLock<Result<Runtime, ()>> = OnceLock::new();
static PROBE_LOCK: Mutex<()> = Mutex::new(());

fn runtime() -> Result<&'static Runtime, ProbeFailure> {
    RUNTIME
        .get_or_init(|| {
            Builder::new_multi_thread()
                .worker_threads(2)
                .enable_io()
                .enable_time()
                .build()
                .map_err(|_| ())
        })
        .as_ref()
        .map_err(|_| ProbeFailure::fixed(STAGE_INPUT, ERROR_RUNTIME))
}

fn pairing_bytes<'a>(data: *const u8, length: usize) -> Option<&'a [u8]> {
    if data.is_null() || length == 0 || length > MAX_PAIRING_BYTES {
        return None;
    }
    // SAFETY: the FFI caller promises that `data` points to `length` readable
    // bytes. Bounds and null are checked above, and the slice never escapes.
    Some(unsafe { slice::from_raw_parts(data, length) })
}

fn parse_pairing(bytes: &[u8]) -> Result<RpPairingFile, ProbeFailure> {
    let pairing = RpPairingFile::from_bytes(bytes)
        .map_err(|error| ProbeFailure::from_idevice(STAGE_PAIRING_PARSE, error))?;

    let derived_public = pairing.e_private_key.verifying_key();
    let identifier_ok = !pairing.identifier.is_empty()
        && pairing.identifier.len() <= 128
        && pairing
            .identifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-');
    let irk_ok = pairing.alt_irk.as_ref().is_none_or(|irk| irk.len() == 16);

    if derived_public != pairing.e_public_key || !identifier_ok || !irk_ok {
        return Err(ProbeFailure::fixed(
            STAGE_PAIRING_PARSE,
            ERROR_PAIRING_MISMATCH,
        ));
    }
    Ok(pairing)
}

async fn bounded<T, F>(stage: u32, operation: F) -> Result<T, ProbeFailure>
where
    F: Future<Output = Result<T, IdeviceError>>,
{
    match tokio::time::timeout(OPERATION_TIMEOUT, operation).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(ProbeFailure::from_idevice(stage, error)),
        Err(_) => Err(ProbeFailure::fixed(stage, ERROR_TIMEOUT)),
    }
}

async fn bounded_tcp_connect(
    stage: u32,
    target: SocketAddr,
) -> Result<TcpStream, ProbeFailure> {
    match tokio::time::timeout(OPERATION_TIMEOUT, TcpStream::connect(target)).await {
        Ok(Ok(stream)) => Ok(stream),
        Ok(Err(error)) => Err(ProbeFailure::from_socket(stage, error)),
        Err(_) => Err(ProbeFailure::fixed(stage, ERROR_TIMEOUT)),
    }
}

fn service_mask(handshake: &RsdHandshake) -> u32 {
    let mut mask = 0;
    if handshake
        .services
        .contains_key("com.apple.dt.testmanagerd.remote")
    {
        mask |= SERVICE_TESTMANAGERD;
    }
    if handshake
        .services
        .contains_key("com.apple.instruments.dtservicehub")
    {
        mask |= SERVICE_DTSERVICEHUB;
    }
    if handshake
        .services
        .contains_key("com.apple.coredevice.appservice")
    {
        mask |= SERVICE_APP_SERVICE;
    }
    if handshake
        .services
        .contains_key("com.apple.mobile.installation_proxy.shim.remote")
    {
        mask |= SERVICE_INSTALLATION_PROXY;
    }
    mask
}

async fn run_probe(mut pairing: RpPairingFile) -> Result<JarvisRsdProbeResult, ProbeFailure> {
    let stream = bounded_tcp_connect(STAGE_TCP_CONNECT, TARGET).await?;
    let socket = RpPairingSocket::new(stream);
    let mut client = RemotePairingClient::new(socket, HOSTNAME);

    // Deliberately do not call RemotePairingClient::connect: upstream falls
    // back to pair-setup if verification fails. These two calls implement a
    // strict pair-verify-only transaction and fail closed on a stale record.
    bounded(STAGE_PAIR_VERIFY_HELLO, client.attempt_pair_verify()).await?;
    bounded(STAGE_PAIR_VERIFY, client.validate_pairing(&mut pairing)).await?;

    let tunnel_port = bounded(STAGE_TUNNEL_LISTENER, client.create_tcp_listener()).await?;
    if tunnel_port == 0 {
        return Err(ProbeFailure::fixed(
            STAGE_TUNNEL_LISTENER,
            ERROR_TUNNEL_PARAMETERS,
        ));
    }
    let tunnel_target = SocketAddr::new(TARGET.ip(), tunnel_port);
    let tunnel_stream = bounded_tcp_connect(STAGE_TUNNEL_TCP, tunnel_target).await?;
    let tunnel = bounded(
        STAGE_TUNNEL_TLS,
        connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key()),
    )
    .await?;

    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|_| ProbeFailure::fixed(STAGE_TUNNEL_PARAMETERS, ERROR_TUNNEL_PARAMETERS))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|_| ProbeFailure::fixed(STAGE_TUNNEL_PARAMETERS, ERROR_TUNNEL_PARAMETERS))?;
    let mtu = usize::from(tunnel.info.mtu);
    let rsd_port = tunnel.info.server_rsd_port;
    if !client_ip.is_ipv6()
        || !server_ip.is_ipv6()
        || !(1_280..=65_535).contains(&mtu)
        || rsd_port == 0
    {
        return Err(ProbeFailure::fixed(
            STAGE_TUNNEL_PARAMETERS,
            ERROR_TUNNEL_PARAMETERS,
        ));
    }

    let raw_tunnel = tunnel.into_inner();
    let mut adapter = Adapter::new(Box::new(raw_tunnel), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let rsd_stream = tokio::time::timeout(OPERATION_TIMEOUT, adapter.connect(rsd_port))
        .await
        .map_err(|_| ProbeFailure::fixed(STAGE_RSD_TCP, ERROR_TIMEOUT))?
        .map_err(|_| ProbeFailure::fixed(STAGE_RSD_TCP, ERROR_ADAPTER_CONNECT))?;
    let handshake = bounded(STAGE_RSD_HANDSHAKE, RsdHandshake::new(rsd_stream)).await?;

    Ok(JarvisRsdProbeResult {
        abi_version: ABI_VERSION,
        stage: STAGE_COMPLETE,
        error_code: 0,
        error_subcode: 0,
        protocol_version: handshake.protocol_version as u64,
        service_mask: service_mask(&handshake),
        service_count: handshake.services.len().min(u32::MAX as usize) as u32,
    })
}

/// Validates the bounded RPPairing record format without performing I/O.
///
/// Returns 1 for valid and 0 for invalid. No identifiers or key bytes leave
/// this function.
///
/// # Safety
/// `data` must point to `length` readable bytes for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jarvis_rsd_pairing_record_is_valid(
    data: *const u8,
    length: usize,
) -> i32 {
    pairing_bytes(data, length)
        .and_then(|bytes| parse_pairing(bytes).ok())
        .map_or(0, |_| 1)
}

/// Runs one bounded, read-only probe against the fixed LocalDevVPN endpoint.
///
/// Returns 0 only after an RSD handshake. On failure, returns -1 and stores a
/// sanitized stage/code tuple in `output`. It never returns raw error text.
///
/// # Safety
/// `data` must point to `length` readable bytes and `output` must be a valid,
/// writable pointer for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jarvis_rsd_probe(
    data: *const u8,
    length: usize,
    output: *mut JarvisRsdProbeResult,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: checked non-null above; caller promises writable storage.
    unsafe {
        *output = JarvisRsdProbeResult {
            abi_version: ABI_VERSION,
            stage: STAGE_INPUT,
            error_code: ERROR_INVALID_INPUT,
            ..JarvisRsdProbeResult::default()
        };
    }

    let Some(bytes) = pairing_bytes(data, length) else {
        return -1;
    };
    let pairing = match parse_pairing(bytes) {
        Ok(pairing) => pairing,
        Err(failure) => {
            // SAFETY: `output` was validated above.
            unsafe {
                (*output).stage = failure.stage;
                (*output).error_code = failure.code;
                (*output).error_subcode = failure.subcode;
            }
            return -1;
        }
    };
    let Ok(_guard) = PROBE_LOCK.try_lock() else {
        // SAFETY: `output` was validated above.
        unsafe {
            (*output).error_code = ERROR_BUSY;
        }
        return -1;
    };
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(failure) => {
            // SAFETY: `output` was validated above.
            unsafe {
                (*output).stage = failure.stage;
                (*output).error_code = failure.code;
                (*output).error_subcode = failure.subcode;
            }
            return -1;
        }
    };

    match runtime.block_on(run_probe(pairing)) {
        Ok(result) => {
            // SAFETY: `output` was validated above.
            unsafe { *output = result };
            0
        }
        Err(failure) => {
            // SAFETY: `output` was validated above.
            unsafe {
                (*output).stage = failure.stage;
                (*output).error_code = failure.code;
                (*output).error_subcode = failure.subcode;
            }
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_pairing_record_validates_without_network() {
        let pairing = RpPairingFile::generate(HOSTNAME);
        let bytes = pairing.to_bytes();
        assert_eq!(
            unsafe { jarvis_rsd_pairing_record_is_valid(bytes.as_ptr(), bytes.len()) },
            1
        );
    }

    #[test]
    fn malformed_and_unbounded_inputs_fail_closed() {
        let malformed = b"not a plist";
        assert_eq!(
            unsafe { jarvis_rsd_pairing_record_is_valid(malformed.as_ptr(), malformed.len()) },
            0
        );
        assert_eq!(unsafe { jarvis_rsd_pairing_record_is_valid(std::ptr::null(), 1) }, 0);
        let byte = 0_u8;
        assert_eq!(
            unsafe {
                jarvis_rsd_pairing_record_is_valid(&byte, MAX_PAIRING_BYTES.saturating_add(1))
            },
            0
        );
    }

    #[test]
    fn public_and_private_key_mismatch_is_rejected() {
        let first = RpPairingFile::generate("first");
        let second = RpPairingFile::generate("second");
        let mismatched = RpPairingFile {
            e_private_key: first.e_private_key,
            e_public_key: second.e_public_key,
            identifier: first.identifier,
            alt_irk: None,
        };
        let bytes = mismatched.to_bytes();
        assert_eq!(
            unsafe { jarvis_rsd_pairing_record_is_valid(bytes.as_ptr(), bytes.len()) },
            0
        );
    }

    #[test]
    fn numeric_socket_diagnostic_is_bounded() {
        let failure = ProbeFailure::from_socket(
            STAGE_TCP_CONNECT,
            io::Error::from_raw_os_error(61),
        );
        assert_eq!(failure.code, 1);
        assert_eq!(failure.subcode, 61);
        let failure = ProbeFailure::from_socket(
            STAGE_TCP_CONNECT,
            io::Error::other("not exported"),
        );
        assert_eq!(failure.subcode, -1);
    }

    #[test]
    fn fixed_target_and_service_bits_are_stable() {
        assert_eq!(std::mem::size_of::<JarvisRsdProbeResult>(), 32);
        assert_eq!(std::mem::align_of::<JarvisRsdProbeResult>(), 8);
        assert_eq!(TARGET.to_string(), "10.7.0.1:49152");
        assert_eq!(
            SERVICE_TESTMANAGERD
                | SERVICE_DTSERVICEHUB
                | SERVICE_APP_SERVICE
                | SERVICE_INSTALLATION_PROXY,
            0x0f
        );
    }
}
