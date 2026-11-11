//! Apple ID sign-in and re-signing, built on Impactor's plume_core / plume_utils / plume_store.
//!
//! Everything (account token, signing certificate + private key, anisette provisioning) lives
//! in `config_dir` — the app's private Application Support folder, never Documents.

use std::ffi::{c_char, c_void, CString};
use std::path::{Path, PathBuf};

use plume_core::auth::{Account, TwoFactorAction, TwoFactorMethod, TwoFactorRequest};
use plume_core::developer::DeveloperSession;
use plume_core::{AnisetteConfiguration, CertificateIdentity};
use plume_store::AccountStore;
use plume_utils::{Package, PlistInfoTrait, Signer, SignerMode, SignerOptions};

use crate::{e, Res};

/// 2FA callback. `method`: 0 = code pushed to trusted devices, 1 = SMS.
/// `phones`: human-readable trusted numbers ("•• 12, •• 34"), may be empty.
/// Write the code (or "sms") into `code_out`; return 0, or non-zero to cancel.
pub type WlTfaCb =
    Option<extern "C" fn(ctx: *mut c_void, method: i32, phones: *const c_char, code_out: *mut c_char, code_len: usize) -> i32>;

fn store_path(config_dir: &Path) -> PathBuf {
    config_dir.join("accounts.json")
}

fn anisette(config_dir: &Path) -> AnisetteConfiguration {
    AnisetteConfiguration::default().set_configuration_path(config_dir.to_path_buf())
}

pub async fn login(email: &str, password: &str, config_dir: &Path, cb: WlTfaCb, ctx: *mut c_void) -> Res<String> {
    std::fs::create_dir_all(config_dir).map_err(e("create config dir"))?;
    let (user, pass) = (email.to_owned(), password.to_owned());
    let creds = move || -> Result<(String, String), String> { Ok((user.clone(), pass.clone())) };

    let tfa = move |req: TwoFactorRequest| -> Result<TwoFactorAction, String> {
        let f = cb.ok_or("no 2FA handler")?;
        let method = match req.method {
            TwoFactorMethod::Device => 0,
            TwoFactorMethod::Sms => 1,
        };
        let phones = req
            .trusted_phone_numbers
            .iter()
            .map(|p| format!("•• {}", p.last_two_digits))
            .collect::<Vec<_>>()
            .join(", ");
        let phones = CString::new(phones).unwrap_or_default();
        let mut buf = vec![0u8; 64];
        let rc = f(ctx, method, phones.as_ptr(), buf.as_mut_ptr() as *mut c_char, buf.len());
        if rc != 0 {
            return Err("2FA cancelled".into());
        }
        let code = String::from_utf8_lossy(&buf[..buf.iter().position(|&b| b == 0).unwrap_or(buf.len())])
            .trim()
            .to_owned();
        if code.eq_ignore_ascii_case("sms") {
            if let Some(p) = req.trusted_phone_numbers.first() {
                return Ok(TwoFactorAction::SendSms(p.id));
            }
        }
        Ok(TwoFactorAction::SubmitCode(code))
    };

    let account = Account::login(creds, tfa, anisette(config_dir)).await.map_err(e("Apple ID sign-in"))?;
    let mut store = AccountStore::load(&Some(store_path(config_dir))).await.map_err(e("account store"))?;
    store
        .accounts_add_from_session(email.to_owned(), account)
        .await
        .map_err(e("save account"))?;
    store.account_select(email).await.map_err(e("select account"))?;
    describe(config_dir).await
}

pub async fn describe(config_dir: &Path) -> Res<String> {
    let store = AccountStore::load(&Some(store_path(config_dir))).await.map_err(e("account store"))?;
    let a = store.selected_account().ok_or("Not signed in")?;
    Ok(format!("{}\n{}\n{}", a.email(), a.first_name(), a.team_id()))
}

pub async fn logout(config_dir: &Path) -> Res<String> {
    let mut store = AccountStore::load(&Some(store_path(config_dir))).await.map_err(e("account store"))?;
    let email = store.selected_account().ok_or("Not signed in")?.email().clone();
    store.accounts_remove(&email).await.map_err(e("remove account"))?;
    Ok(format!("Signed out {email}"))
}

async fn session(config_dir: &Path) -> Res<(DeveloperSession, String)> {
    let store = AccountStore::load(&Some(store_path(config_dir))).await.map_err(e("account store"))?;
    let a = store.selected_account().ok_or("Not signed in — add your Apple ID in Settings")?.clone();
    let s = DeveloperSession::new(a.adsid().clone(), a.xcode_gs_token().clone(), anisette(config_dir))
        .await
        .map_err(e("restore Apple ID session (try signing in again)"))?;
    let team = if a.team_id().is_empty() {
        s.qh_list_teams()
            .await
            .map_err(e("list teams"))?
            .teams
            .first()
            .map(|t| t.team_id.clone())
            .ok_or("Apple ID has no developer team")?
    } else {
        a.team_id().clone()
    };
    Ok((s, team))
}

/// Re-sign `ipa` for the watch with a fresh free-account profile and replace it in place.
pub async fn resign(
    config_dir: &Path,
    ipa: &str,
    watch_udid: &str,
    progress: &mut dyn FnMut(&str, i32),
) -> Res<String> {
    progress("Restoring Apple ID session", 2);
    let (session, team) = session(config_dir).await?;

    progress("Registering Apple Watch", 10);
    session
        .qh_ensure_device(&team, &"Apple Watch".to_string(), &watch_udid.to_string())
        .await
        .map_err(e("register watch"))?;

    progress("Preparing signing certificate", 20);
    let cert = CertificateIdentity::new_with_session(
        &session,
        config_dir.to_path_buf(),
        Some("WatchLoader".into()),
        &team,
        false,
        None,
    )
    .await
    .map_err(e("signing certificate"))?;

    progress("Unpacking app", 35);
    let pkg = Package::new(PathBuf::from(ipa)).map_err(e("open IPA"))?;
    let bundle = pkg.get_package_bundle().map_err(e("unpack IPA"))?;
    let original_id = bundle.get_bundle_identifier();

    let options = SignerOptions {
        mode: SignerMode::Pem,
        // keep the original bundle id so the watch app keeps matching its companion
        custom_identifier: original_id.clone(),
        ..SignerOptions::default()
    };
    let mut signer = Signer::new(Some(cert), options);

    progress("Updating bundle", 45);
    signer.modify_bundle(&bundle, &Some(team.clone())).await.map_err(e("modify bundle"))?;
    progress("Registering App IDs & profiles", 55);
    signer
        .register_bundle(&bundle, &session, &team, false)
        .await
        .map_err(e("register App IDs / profiles"))?;
    progress("Signing", 75);
    signer.sign_bundle(&bundle).await.map_err(e("sign"))?;

    progress("Packaging", 90);
    let signed = pkg.get_archive_based_on_path(bundle.bundle_dir()).map_err(e("package IPA"))?;
    std::fs::copy(&signed, ipa).map_err(e("replace IPA"))?;
    pkg.remove_package_stage();
    progress("Re-signed", 100);
    Ok(format!("Re-signed {} for 7 days (team {team})", original_id.unwrap_or_default()))
}
