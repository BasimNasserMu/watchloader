//! WatchLoader core.
//!
//! Runs *on the iPhone*. Talks to the iPhone's own lockdownd through a loopback VPN
//! (LocalDevVPN routes 10.7.0.1 back to the device), keeps it alive with the heartbeat
//! service, asks `com.apple.companion_proxy` to forward ports on the paired Apple Watch,
//! then uses the watch's lockdownd + `com.apple.streaming_zip_conduit` to install an app.
//!
//! Same path as `tools/watchlink.py` in the hello-watch repo, which was verified from a PC.

use std::ffi::{c_char, c_void, CStr};
use std::future::Future;
use std::io::Read;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;

use idevice::companion_proxy::CompanionProxy;
use idevice::heartbeat::HeartbeatClient;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::{Idevice, IdeviceError, IdeviceService};
use tokio::net::TcpStream;
use tokio::sync::Mutex;

type Res<T> = Result<T, String>;

fn e<E: std::fmt::Display + std::fmt::Debug>(ctx: &'static str) -> impl FnOnce(E) -> String {
    // Debug shows the underlying io::Error kind (ConnectionRefused, TimedOut, ...).
    move |err| format!("{ctx}: {err} [{err:?}]")
}

/// Step-by-step connectivity check against one address. Never fails; returns a report.
async fn diagnose_one(ip: &str, phone_pairing: &str) -> String {
    use std::time::Duration;
    let mut r = format!("== {ip} ==\n");
    let addr: IpAddr = match ip.parse() {
        Ok(a) => a,
        Err(err) => return r + &format!("  bad address: {err}\n"),
    };
    let pf = match PairingFile::read_from_file(phone_pairing) {
        Ok(p) => p,
        Err(err) => return r + &format!("  phone.plist unreadable: {err:?}\n"),
    };

    // 1. raw TCP
    let stream = match tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(SocketAddr::new(addr, 62078))).await {
        Ok(Ok(s)) => {
            r += "  1 TCP :62078            OK\n";
            s
        }
        Ok(Err(err)) => return r + &format!("  1 TCP :62078            FAIL {:?} ({err})\n", err.kind()),
        Err(_) => return r + "  1 TCP :62078            FAIL timeout (5s)\n",
    };

    // 2. unauthenticated query
    let mut ld = LockdownClient::new(Idevice::new(Box::new(stream), "watchloader"));
    match tokio::time::timeout(Duration::from_secs(5), ld.get_value(Some("DeviceName"), None)).await {
        Ok(Ok(v)) => r += &format!("  2 lockdown query        OK ({})\n", v.as_string().unwrap_or("?")),
        Ok(Err(err)) => return r + &format!("  2 lockdown query        FAIL {err:?}\n"),
        Err(_) => return r + "  2 lockdown query        FAIL timeout\n",
    }

    // 3. TLS session with the pairing record
    let legacy = match tokio::time::timeout(Duration::from_secs(8), ld.start_session(&pf)).await {
        Ok(Ok(l)) => {
            r += "  3 pairing session (TLS) OK\n";
            l
        }
        Ok(Err(err)) => return r + &format!("  3 pairing session (TLS) FAIL {err:?}\n"),
        Err(_) => return r + "  3 pairing session (TLS) FAIL timeout\n",
    };

    // 4. heartbeat service
    let (port, ssl) = match ld.start_service("com.apple.mobile.heartbeat").await {
        Ok(x) => {
            r += &format!("  4 start heartbeat       OK (port {}, ssl {})\n", x.0, x.1);
            x
        }
        Err(err) => return r + &format!("  4 start heartbeat       FAIL {err:?}\n"),
    };
    let s = match tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(SocketAddr::new(addr, port))).await {
        Ok(Ok(s)) => s,
        Ok(Err(err)) => return r + &format!("  5 heartbeat connect     FAIL {:?} ({err})\n", err.kind()),
        Err(_) => return r + "  5 heartbeat connect     FAIL timeout\n",
    };
    let mut hb = Idevice::new(Box::new(s), "watchloader");
    if ssl {
        if let Err(err) = hb.start_session(&pf, legacy).await {
            return r + &format!("  5 heartbeat TLS         FAIL {err:?}\n");
        }
    }
    let mut hb = HeartbeatClient::new(hb);
    match hb.get_marco(20).await {
        Ok(i) => r += &format!("  5 heartbeat Marco       OK (interval {i}s) — iPhone link works\n"),
        Err(err) => r += &format!("  5 heartbeat Marco       FAIL {err:?}\n"),
    }
    r
}

// ---------------------------------------------------------------------------------------------
// Provider that reaches the *watch* by forwarding each port through the iPhone's companion proxy
// ---------------------------------------------------------------------------------------------

#[derive(Debug)]
struct WatchProvider {
    phone_ip: IpAddr,
    proxy: Arc<Mutex<CompanionProxy>>,
    pairing: PairingFile,
    label: String,
}

impl IdeviceProvider for WatchProvider {
    fn connect(&self, port: u16) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        let proxy = self.proxy.clone();
        let ip = self.phone_ip;
        let label = self.label.clone();
        Box::pin(async move {
            let fwd = proxy.lock().await.start_forwarding_service_port(port, None, None).await?;
            let stream = TcpStream::connect(SocketAddr::new(ip, fwd)).await?;
            Ok(Idevice::new(Box::new(stream), label))
        })
    }

    fn label(&self) -> &str {
        &self.label
    }

    fn get_pairing_file(&self) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        let p = self.pairing.clone();
        Box::pin(async move { Ok(p) })
    }
}

/// Raw lockdown service wrapper so we can drive streaming_zip_conduit ourselves.
struct ZipConduit {
    idevice: Idevice,
}

impl IdeviceService for ZipConduit {
    fn service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.streaming_zip_conduit".into()
    }
    async fn from_stream(idevice: Idevice) -> Result<Self, IdeviceError> {
        Ok(Self { idevice })
    }
}

// ---------------------------------------------------------------------------------------------
// Session setup
// ---------------------------------------------------------------------------------------------

struct Session {
    watch: WatchProvider,
    watch_udid: String,
    _heartbeat: tokio::task::JoinHandle<()>,
}

async fn open_session(phone_ip: &str, phone_pairing: &str, watch_pairing: &str) -> Res<Session> {
    let ip: IpAddr = phone_ip.parse().map_err(e("bad iPhone IP"))?;
    let phone_pf = PairingFile::read_from_file(phone_pairing).map_err(e("iPhone pairing file"))?;
    let watch_pf = PairingFile::read_from_file(watch_pairing).map_err(e("watch pairing file"))?;

    let phone = TcpProvider { addr: ip, scope_id: None, pairing_file: phone_pf, label: "watchloader".into() };

    // Keep Wi-Fi/loopback lockdown alive: the iPhone drops service connections without Marco/Polo.
    let mut hb = HeartbeatClient::connect(&phone)
        .await
        .map_err(e("heartbeat (is LocalDevVPN connected?)"))?;
    let heartbeat = tokio::spawn(async move {
        let mut interval = 30;
        loop {
            match hb.get_marco(interval + 10).await {
                Ok(i) => {
                    interval = i;
                    if hb.send_polo().await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let mut proxy = CompanionProxy::connect(&phone).await.map_err(e("companion_proxy"))?;
    let watches = proxy.get_device_registry().await.map_err(e("watch registry"))?;
    let watch_udid = watches.first().cloned().ok_or("iPhone reports no paired Apple Watch")?;

    let watch = WatchProvider {
        phone_ip: ip,
        proxy: Arc::new(Mutex::new(proxy)),
        pairing: watch_pf,
        label: "watchloader".into(),
    };
    Ok(Session { watch, watch_udid, _heartbeat: heartbeat })
}

async fn probe(phone_ip: &str, phone_pairing: &str, watch_pairing: &str) -> Res<String> {
    let s = open_session(phone_ip, phone_pairing, watch_pairing).await?;
    let mut ld = LockdownClient::connect(&s.watch).await.map_err(e("watch lockdown"))?;
    let pf = s.watch.pairing.clone();
    ld.start_session(&pf).await.map_err(e("watch session (pairing record valid?)"))?;
    let get = |v: Result<plist::Value, IdeviceError>| v.ok().and_then(|x| x.as_string().map(str::to_owned)).unwrap_or_default();
    let name = get(ld.get_value(Some("DeviceName"), None).await);
    let ver = get(ld.get_value(Some("ProductVersion"), None).await);
    Ok(format!("Connected to {name} (watchOS {ver})\nUDID {}", s.watch_udid))
}

// ---------------------------------------------------------------------------------------------
// streaming_zip_conduit (ported from go-ios / watchlink.py)
// ---------------------------------------------------------------------------------------------

const ZIP_EXTRA: [u8; 32] = [
    0x55, 0x54, 0x0D, 0x00, 0x07, 0xF3, 0xA2, 0xEC, 0x60, 0xF6, 0xA2, 0xEC, 0x60, 0xF3, 0xA2, 0xEC,
    0x60, 0x75, 0x78, 0x0B, 0x00, 0x01, 0x04, 0xF5, 0x01, 0x00, 0x00, 0x04, 0x14, 0x00, 0x00, 0x00,
];

fn local_header(name: &str, size: u32, crc: u32) -> Vec<u8> {
    let mut h = Vec::with_capacity(30 + name.len() + ZIP_EXTRA.len());
    h.extend_from_slice(&0x04034b50u32.to_le_bytes());
    h.extend_from_slice(&20u16.to_le_bytes()); // version
    h.extend_from_slice(&0u16.to_le_bytes()); // flags
    h.extend_from_slice(&0u16.to_le_bytes()); // STORE
    h.extend_from_slice(&0xBDEFu16.to_le_bytes()); // time
    h.extend_from_slice(&0x52ECu16.to_le_bytes()); // date
    h.extend_from_slice(&crc.to_le_bytes());
    h.extend_from_slice(&size.to_le_bytes());
    h.extend_from_slice(&size.to_le_bytes());
    h.extend_from_slice(&(name.len() as u16).to_le_bytes());
    h.extend_from_slice(&(ZIP_EXTRA.len() as u16).to_le_bytes());
    h.extend_from_slice(name.as_bytes());
    h.extend_from_slice(&ZIP_EXTRA);
    h
}

async fn send_plist(dev: &mut Idevice, v: plist::Value) -> Res<()> {
    let mut body = Vec::new();
    plist::to_writer_xml(&mut body, &v).map_err(e("encode plist"))?;
    let mut msg = (body.len() as u32).to_be_bytes().to_vec();
    msg.extend(body);
    dev.send_raw(&msg).await.map_err(e("send plist"))
}

async fn read_plist(dev: &mut Idevice) -> Res<plist::Dictionary> {
    let len = dev.read_raw(4).await.map_err(e("read length"))?;
    let n = u32::from_be_bytes([len[0], len[1], len[2], len[3]]) as usize;
    let body = dev.read_raw(n).await.map_err(e("read plist"))?;
    plist::from_bytes(&body).map_err(e("decode plist"))
}

fn dict(pairs: &[(&str, plist::Value)]) -> plist::Value {
    let mut d = plist::Dictionary::new();
    for (k, v) in pairs {
        d.insert((*k).to_owned(), v.clone());
    }
    plist::Value::Dictionary(d)
}

async fn install(
    phone_ip: &str,
    phone_pairing: &str,
    watch_pairing: &str,
    ipa_path: &str,
    progress: &mut dyn FnMut(&str, i32),
) -> Res<String> {
    progress("Connecting to iPhone", 0);
    let s = open_session(phone_ip, phone_pairing, watch_pairing).await?;
    progress("Connecting to watch", 2);
    let mut conduit = ZipConduit::connect(&s.watch).await.map_err(e("start streaming_zip_conduit"))?;
    let dev = &mut conduit.idevice;

    let file = std::fs::File::open(ipa_path).map_err(e("open IPA"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(e("read IPA"))?;
    let total: u64 = (0..zip.len()).filter_map(|i| zip.by_index_raw(i).ok().map(|f| f.size())).sum();
    let file_name = std::path::Path::new(ipa_path).file_name().and_then(|n| n.to_str()).unwrap_or("app.ipa");

    use plist::Value as V;
    send_plist(
        dev,
        dict(&[
            ("InstallTransferredDirectory", V::Integer(1.into())),
            ("UserInitiatedTransfer", V::Integer(0.into())),
            ("MediaSubdir", V::String(format!("PublicStaging/{file_name}"))),
            (
                "InstallOptionsDictionary",
                dict(&[
                    ("DisableDeltaTransfer", V::Integer(1.into())),
                    ("InstallDeltaTypeKey", V::String("InstallDeltaTypeSparseIPAFiles".into())),
                    ("IsUserInitiated", V::Integer(1.into())),
                    ("PackageType", V::String("Customer".into())),
                    ("PreferWifi", V::Integer(1.into())),
                ]),
            ),
        ]),
    )
    .await?;

    let mut meta = Vec::new();
    plist::to_writer_xml(
        &mut meta,
        &dict(&[
            ("RecordCount", V::Integer((2 + zip.len() as u64).into())),
            ("StandardDirectoryPerms", V::Integer(16877.into())),
            ("StandardFilePerms", V::Integer((-32348i64).into())),
            ("TotalUncompressedBytes", V::Integer(total.into())),
            ("Version", V::Integer(2.into())),
        ]),
    )
    .map_err(e("encode metadata"))?;

    progress("Sending app", 5);
    dev.send_raw(&local_header("META-INF/", 0, 0)).await.map_err(e("send"))?;
    let mut m = local_header("META-INF/com.apple.ZipMetadata.plist", meta.len() as u32, crc32(&meta));
    m.extend(&meta);
    dev.send_raw(&m).await.map_err(e("send"))?;

    for i in 0..zip.len() {
        let mut f = zip.by_index(i).map_err(e("read IPA entry"))?;
        let name = f.name().to_owned();
        if f.is_dir() {
            dev.send_raw(&local_header(&name, 0, 0)).await.map_err(e("send"))?;
            continue;
        }
        let mut data = Vec::with_capacity(f.size() as usize);
        f.read_to_end(&mut data).map_err(e("inflate IPA entry"))?;
        let mut chunk = local_header(&name, data.len() as u32, f.crc32());
        chunk.extend(data);
        dev.send_raw(&chunk).await.map_err(e("send"))?;
    }
    dev.send_raw(b"PK\x01\x02").await.map_err(e("send"))?;
    progress("Installing on watch", 10);

    loop {
        let msg = read_plist(dev).await?;
        if msg.get("Status").and_then(|v| v.as_string()) == Some("DataComplete") {
            progress("Done", 100);
            return Ok(format!("Installed {file_name} on the watch"));
        }
        if let Some(p) = msg.get("InstallProgressDict").and_then(|v| v.as_dictionary()) {
            if let Some(err) = p.get("Error").and_then(|v| v.as_string()) {
                let desc = p.get("ErrorDescription").and_then(|v| v.as_string()).unwrap_or("");
                return Err(format!("Install failed: {err} — {desc}"));
            }
            let status = p.get("Status").and_then(|v| v.as_string()).unwrap_or("");
            let pct = p.get("PercentComplete").and_then(|v| v.as_unsigned_integer()).unwrap_or(0) as i32;
            progress(status, pct);
        }
    }
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

// ---------------------------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------------------------

pub type WlProgressCb = Option<extern "C" fn(ctx: *mut c_void, status: *const c_char, percent: i32)>;

unsafe fn cstr<'a>(p: *const c_char) -> Res<&'a str> {
    if p.is_null() {
        return Err("null argument".into());
    }
    CStr::from_ptr(p).to_str().map_err(e("argument not UTF-8"))
}

unsafe fn write_out(out: *mut c_char, out_len: usize, msg: &str) {
    if out.is_null() || out_len == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(out_len - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, n);
    *out.add(n) = 0;
}

fn run<F: Future<Output = Res<String>>>(f: F) -> Res<String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(e("tokio runtime"))?
        .block_on(f)
}

/// Step-by-step connectivity report for each comma-separated address. Always returns 0.
#[no_mangle]
pub unsafe extern "C" fn wl_diagnose(
    addresses: *const c_char,
    phone_pairing: *const c_char,
    out: *mut c_char,
    out_len: usize,
) -> i32 {
    let r = (|| -> Res<String> {
        let (addrs, pp) = (cstr(addresses)?, cstr(phone_pairing)?);
        run(async move {
            let mut report = String::new();
            for a in addrs.split(',').map(str::trim).filter(|a| !a.is_empty()) {
                report += &diagnose_one(a, pp).await;
            }
            Ok(report)
        })
    })();
    let msg = r.unwrap_or_else(|m| m);
    write_out(out, out_len, &msg);
    0
}

/// Connect iPhone -> watch and report the watch name/version. Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn wl_probe(
    phone_ip: *const c_char,
    phone_pairing: *const c_char,
    watch_pairing: *const c_char,
    out: *mut c_char,
    out_len: usize,
) -> i32 {
    let r = (|| -> Res<String> {
        let (ip, pp, wp) = (cstr(phone_ip)?, cstr(phone_pairing)?, cstr(watch_pairing)?);
        run(probe(ip, pp, wp))
    })();
    match r {
        Ok(m) => {
            write_out(out, out_len, &m);
            0
        }
        Err(m) => {
            write_out(out, out_len, &m);
            -1
        }
    }
}

/// Install a (watch-only) IPA on the paired Apple Watch. Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn wl_install(
    phone_ip: *const c_char,
    phone_pairing: *const c_char,
    watch_pairing: *const c_char,
    ipa_path: *const c_char,
    cb: WlProgressCb,
    ctx: *mut c_void,
    out: *mut c_char,
    out_len: usize,
) -> i32 {
    let r = (|| -> Res<String> {
        let (ip, pp, wp, ipa) = (cstr(phone_ip)?, cstr(phone_pairing)?, cstr(watch_pairing)?, cstr(ipa_path)?);
        let mut progress = |status: &str, pct: i32| {
            if let Some(f) = cb {
                let s = std::ffi::CString::new(status).unwrap_or_default();
                f(ctx, s.as_ptr(), pct);
            }
        };
        run(install(ip, pp, wp, ipa, &mut progress))
    })();
    match r {
        Ok(m) => {
            write_out(out, out_len, &m);
            0
        }
        Err(m) => {
            write_out(out, out_len, &m);
            -1
        }
    }
}
