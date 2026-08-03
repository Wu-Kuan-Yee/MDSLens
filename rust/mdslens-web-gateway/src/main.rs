// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

use std::collections::{HashMap, HashSet};
use std::env;
use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Body;
use axum::extract::State;
use axum::http::header::{CONTENT_TYPE, COOKIE, ORIGIN, SET_COOKIE};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use mds_bridge::api::{FrbLayoutConfig, FrbSshSettings};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tempfile::Builder as TempFileBuilder;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::trace::TraceLayer;
use url::Url;

const SESSION_COOKIE: &str = "__Host-mdslens_session";
const DEVELOPMENT_SESSION_COOKIE: &str = "mdslens_session";
const MAX_CONFIG_BYTES: usize = 4 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const SESSION_LIFETIME_SECONDS: u64 = 12 * 60 * 60;
const SIGNAL_BATCH_MAGIC: &[u8; 8] = b"MDSLBIN1";

#[derive(Clone)]
struct GatewayState {
    sessions: Arc<Mutex<HashMap<String, Arc<BrowserSession>>>>,
    policy: Arc<GatewayPolicy>,
}

struct BrowserSession {
    auth: Mutex<SessionAuth>,
    tunnel: Mutex<mds_ssh::tunnel::SshTunnelManager>,
    last_seen: AtomicU64,
}

#[derive(Clone, Default)]
struct SessionAuth {
    authenticated: bool,
    user: String,
    token: String,
    requested_api_url: String,
    effective_api_url: String,
    ssh: Option<FrbSshSettings>,
    used_ssh: bool,
}

struct GatewayPolicy {
    allowed_hosts: HashSet<String>,
    allow_any_host: bool,
    allowed_origins: HashSet<String>,
    secure_cookie: bool,
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "ok": false,
                "error": self.message,
            })),
        )
            .into_response()
    }
}

type ApiResult<T> = Result<T, ApiError>;

#[derive(Serialize)]
struct HealthResponse {
    ok: bool,
    service: &'static str,
    version: &'static str,
}

#[derive(Serialize)]
struct SessionResponse {
    ok: bool,
    authenticated: bool,
    user: String,
    api_url: String,
    used_ssh: bool,
}

#[derive(Deserialize)]
struct LoginRequest {
    api_url: String,
    user: String,
    password: String,
    #[serde(default)]
    ssh: Option<FrbSshSettings>,
}

#[derive(Deserialize)]
struct ShotInfoRequest {
    shot: String,
}

#[derive(Deserialize)]
struct FetchRequest {
    config_json: String,
    data_mode: i32,
}

#[derive(Deserialize)]
struct PrewarmRequest {
    config_json: String,
}

#[derive(Deserialize)]
struct CancelRequest {
    request_id: u64,
}

#[derive(Deserialize)]
struct ParseConfigurationRequest {
    name: String,
    bytes_base64: String,
}

#[derive(Deserialize)]
struct EncodeConfigurationRequest {
    config_json: String,
    format: String,
}

#[tokio::main]
async fn main() {
    let bind = env::var("MDSLENS_WEB_BIND").unwrap_or_else(|_| "127.0.0.1:8088".into());
    let address: SocketAddr = bind.parse().unwrap_or_else(|error| {
        eprintln!("Invalid MDSLENS_WEB_BIND '{bind}': {error}");
        std::process::exit(2);
    });
    let web_root =
        PathBuf::from(env::var("MDSLENS_WEB_ROOT").unwrap_or_else(|_| "build/web".into()));
    let policy = Arc::new(GatewayPolicy::from_environment());
    let state = GatewayState {
        sessions: Arc::new(Mutex::new(HashMap::new())),
        policy,
    };

    let api = Router::new()
        .route("/health", get(health))
        .route("/session", get(session_status))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/shot/latest", post(latest_shot))
        .route("/shot/info", post(shot_info))
        .route("/signals/fetch", post(fetch_signals))
        .route("/signals/fetch-binary", post(fetch_signals_binary))
        .route("/signals/prewarm", post(prewarm_signals))
        .route("/signals/cancel", post(cancel_fetch))
        .route("/ssh/test", post(test_ssh))
        .route("/ssh/disconnect", post(disconnect_ssh))
        .route("/configuration/parse", post(parse_configuration))
        .route("/configuration/encode", post(encode_configuration))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_REQUEST_BYTES));

    let static_files = ServeDir::new(&web_root)
        .append_index_html_on_directories(true)
        .fallback(ServeFile::new(web_root.join("index.html")));

    let app = Router::new()
        .nest("/gateway/v1", api)
        .fallback_service(static_files)
        .with_state(state)
        .layer(middleware::from_fn(security_headers))
        .layer(TraceLayer::new_for_http());

    let listener = tokio::net::TcpListener::bind(address)
        .await
        .unwrap_or_else(|error| {
            eprintln!("Cannot bind MDSLens Web Gateway to {address}: {error}");
            std::process::exit(2);
        });
    println!(
        "MDSLens Web Gateway listening on http://{address} (web root: {})",
        web_root.display()
    );
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap_or_else(|error| {
            eprintln!("MDSLens Web Gateway stopped: {error}");
            std::process::exit(1);
        });
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

async fn security_headers(request: Request<Body>, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    for (name, value) in [
        (
            "content-security-policy",
            "default-src 'self'; script-src 'self' blob: 'wasm-unsafe-eval'; \
             worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; \
             img-src 'self' data: blob:; \
             font-src 'self' data:; connect-src 'self' https://api.github.com; \
             object-src 'none'; base-uri 'self'; frame-ancestors 'self'",
        ),
        ("cross-origin-opener-policy", "same-origin"),
        ("cross-origin-embedder-policy", "credentialless"),
        ("cross-origin-resource-policy", "same-origin"),
        ("referrer-policy", "no-referrer"),
        ("x-content-type-options", "nosniff"),
        ("x-frame-options", "SAMEORIGIN"),
        (
            "permissions-policy",
            "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        ),
    ] {
        headers.insert(
            HeaderName::from_static(name),
            HeaderValue::from_static(value),
        );
    }
    response
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        service: "mdslens-web-gateway",
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn session_status(
    State(state): State<GatewayState>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    let (id, session, created) = session_for_request(&state, &headers)?;
    let auth = session
        .auth
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    let response = Json(SessionResponse {
        ok: true,
        authenticated: auth.authenticated,
        user: auth.user,
        api_url: auth.requested_api_url,
        used_ssh: auth.used_ssh,
    })
    .into_response();
    Ok(with_session_cookie(response, &id, created, &state.policy))
}

async fn login(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<LoginRequest>,
) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    validate_api_url(&payload.api_url, &state.policy)?;
    if payload.user.trim().is_empty() || payload.password.is_empty() {
        return Err(ApiError::bad_request("Username and password are required."));
    }
    if let Some(ssh) = &payload.ssh {
        validate_ssh_settings(ssh, &state.policy)?;
    }
    let (id, session, created) = session_for_request(&state, &headers)?;
    let api_url = payload.api_url.trim_end_matches('/').to_string();
    let user = payload.user.trim().to_string();
    let password = payload.password;
    let ssh = payload.ssh.filter(|settings| settings.mode > 0);
    let operation_session = Arc::clone(&session);
    let operation_api_url = api_url.clone();
    let operation_ssh = ssh.clone();
    let login_result = tokio::task::spawn_blocking(move || {
        let mut manager = operation_session
            .tunnel
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        login_with_optional_ssh(
            &mut manager,
            &operation_api_url,
            &user,
            &password,
            operation_ssh.as_ref(),
        )
    })
    .await
    .map_err(|error| ApiError::internal(format!("Login worker failed: {error}")))?
    .map_err(ApiError::unauthorized)?;

    let (token, effective_url, used_ssh) = login_result;
    {
        let mut auth = session
            .auth
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *auth = SessionAuth {
            authenticated: true,
            user: payload.user.trim().to_string(),
            token,
            requested_api_url: api_url,
            effective_api_url: effective_url,
            ssh,
            used_ssh,
        };
    }
    let response = Json(json!({
        "ok": true,
        "authenticated": true,
        "user": payload.user.trim(),
        "used_ssh": used_ssh,
    }))
    .into_response();
    Ok(with_session_cookie(response, &id, created, &state.policy))
}

async fn logout(State(state): State<GatewayState>, headers: HeaderMap) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    if let Some(id) = session_id_from_headers(&headers) {
        state
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&id);
    }
    let mut response = Json(json!({"ok": true})).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&expired_cookie(&state.policy))
            .map_err(|error| ApiError::internal(error.to_string()))?,
    );
    Ok(response)
}

async fn latest_shot(
    State(state): State<GatewayState>,
    headers: HeaderMap,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    let session = authenticated_session(&state, &headers)?;
    let auth = session_auth(&session)?;
    let result = tokio::task::spawn_blocking(move || {
        mds_auth::http::fetch_latest_shot(&auth.effective_api_url, &auth.token)
    })
    .await
    .map_err(|error| ApiError::internal(format!("Latest-shot worker failed: {error}")))?
    .map_err(ApiError::bad_request)?;
    Ok(Json(json!({
        "shot": result.shot,
        "ip": result.ip,
        "pulse": result.pulse,
        "it": result.it,
        "time": result.time,
    })))
}

async fn shot_info(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<ShotInfoRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    let session = authenticated_session(&state, &headers)?;
    let auth = session_auth(&session)?;
    let result = tokio::task::spawn_blocking(move || {
        mds_auth::http::fetch_shot_info(&auth.effective_api_url, &auth.token, &payload.shot)
    })
    .await
    .map_err(|error| ApiError::internal(format!("Shot-info worker failed: {error}")))?
    .map_err(ApiError::bad_request)?;
    Ok(Json(json!({
        "shot": result.shot,
        "ip": result.ip,
        "pulse": result.pulse,
        "it": result.it,
        "time": result.time,
    })))
}

async fn fetch_signals(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<FetchRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    validate_signal_hosts(&payload.config_json, &state.policy)?;
    let session = authenticated_session(&state, &headers)?;
    let auth = session_auth(&session)?;
    let operation_session = Arc::clone(&session);
    let result = tokio::task::spawn_blocking(move || {
        let mut manager = operation_session
            .tunnel
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mds_bridge::api::fetch_signals_for_session(
            payload.config_json,
            payload.data_mode,
            auth.ssh,
            &mut manager,
        )
    })
    .await
    .map_err(|error| ApiError::internal(format!("Signal worker failed: {error}")))?;
    serde_json::to_value(result)
        .map(Json)
        .map_err(|error| ApiError::internal(error.to_string()))
}

async fn fetch_signals_binary(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<FetchRequest>,
) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    validate_signal_hosts(&payload.config_json, &state.policy)?;
    let session = authenticated_session(&state, &headers)?;
    let auth = session_auth(&session)?;
    let operation_session = Arc::clone(&session);
    let result = tokio::task::spawn_blocking(move || {
        let mut manager = operation_session
            .tunnel
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mds_bridge::api::fetch_signals_for_session(
            payload.config_json,
            payload.data_mode,
            auth.ssh,
            &mut manager,
        )
    })
    .await
    .map_err(|error| ApiError::internal(format!("Signal worker failed: {error}")))?;
    let body = encode_signal_batch(result)?;
    Ok((
        [(
            CONTENT_TYPE,
            HeaderValue::from_static("application/vnd.mdslens.signals-v1"),
        )],
        body,
    )
        .into_response())
}

fn encode_signal_batch(mut signals: Vec<mds_bridge::api::FrbLoadedSignal>) -> ApiResult<Vec<u8>> {
    let signal_count = u32::try_from(signals.len())
        .map_err(|_| ApiError::internal("Signal batch contains too many entries."))?;
    let mut output = Vec::new();
    output.extend_from_slice(SIGNAL_BATCH_MAGIC);
    output.extend_from_slice(&signal_count.to_le_bytes());
    for signal in &mut signals {
        let uniform = std::mem::take(&mut signal.series.uniform_y);
        let points = std::mem::take(&mut signal.series.points);
        let metadata =
            serde_json::to_vec(signal).map_err(|error| ApiError::internal(error.to_string()))?;
        let metadata_len = u32::try_from(metadata.len())
            .map_err(|_| ApiError::internal("Signal metadata is too large."))?;
        let uniform_len = u32::try_from(uniform.len())
            .map_err(|_| ApiError::internal("Uniform signal data is too large."))?;
        let point_len = u32::try_from(points.len())
            .map_err(|_| ApiError::internal("Irregular signal data is too large."))?;
        output.extend_from_slice(&metadata_len.to_le_bytes());
        output.extend_from_slice(&uniform_len.to_le_bytes());
        output.extend_from_slice(&point_len.to_le_bytes());
        output.extend_from_slice(&metadata);
        pad_to_eight_bytes(&mut output);
        for value in uniform {
            output.extend_from_slice(&value.to_le_bytes());
        }
        pad_to_eight_bytes(&mut output);
        for point in points {
            let x = point.first().copied().unwrap_or_default();
            let y = point.get(1).copied().unwrap_or_default();
            output.extend_from_slice(&x.to_le_bytes());
            output.extend_from_slice(&y.to_le_bytes());
        }
    }
    Ok(output)
}

fn pad_to_eight_bytes(output: &mut Vec<u8>) {
    let padding = (8 - output.len() % 8) % 8;
    output.resize(output.len() + padding, 0);
}

async fn prewarm_signals(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<PrewarmRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    validate_signal_hosts(&payload.config_json, &state.policy)?;
    let session = authenticated_session(&state, &headers)?;
    let auth = session_auth(&session)?;
    let operation_session = Arc::clone(&session);
    tokio::task::spawn_blocking(move || {
        let mut manager = operation_session
            .tunnel
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mds_bridge::api::prewarm_signals_for_session(payload.config_json, auth.ssh, &mut manager)
    })
    .await
    .map_err(|error| ApiError::internal(format!("Prewarm worker failed: {error}")))?
    .map_err(ApiError::bad_request)?;
    Ok(Json(json!({"ok": true})))
}

async fn cancel_fetch(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<CancelRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    authenticated_session(&state, &headers)?;
    Ok(Json(json!({
        "ok": true,
        "cancelled": mds_bridge::api::cancel_fetch(payload.request_id),
    })))
}

async fn test_ssh(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(settings): Json<FrbSshSettings>,
) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    validate_ssh_settings(&settings, &state.policy)?;
    let (id, session, created) = session_for_request(&state, &headers)?;
    let test_settings = settings.clone();
    tokio::task::spawn_blocking(move || mds_bridge::api::ssh_test(test_settings))
        .await
        .map_err(|error| ApiError::internal(format!("SSH worker failed: {error}")))?
        .map_err(ApiError::bad_request)?;
    session
        .auth
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .ssh = Some(settings);
    let response = Json(json!({"ok": true})).into_response();
    Ok(with_session_cookie(response, &id, created, &state.policy))
}

async fn disconnect_ssh(
    State(state): State<GatewayState>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    validate_origin(&headers, &state.policy)?;
    let (id, session, created) = session_for_request(&state, &headers)?;
    session
        .tunnel
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .reload_settings(mds_ssh::settings::SshSettings::default());
    let mut auth = session
        .auth
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    auth.ssh = None;
    auth.used_ssh = false;
    let response = Json(json!({"ok": true})).into_response();
    Ok(with_session_cookie(response, &id, created, &state.policy))
}

async fn parse_configuration(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<ParseConfigurationRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    let extension = configuration_extension(&payload.name)?;
    let bytes = STANDARD
        .decode(payload.bytes_base64.as_bytes())
        .map_err(|error| ApiError::bad_request(format!("Invalid configuration bytes: {error}")))?;
    if bytes.len() > MAX_CONFIG_BYTES {
        return Err(ApiError::bad_request("Configuration file is too large."));
    }
    let config = tokio::task::spawn_blocking(move || -> Result<FrbLayoutConfig, String> {
        let mut file = TempFileBuilder::new()
            .prefix("mdslens-web-")
            .suffix(extension)
            .tempfile()
            .map_err(|error| error.to_string())?;
        file.write_all(&bytes).map_err(|error| error.to_string())?;
        let path = file.path().to_string_lossy().into_owned();
        mds_bridge::api::parse_environment_checked(path)
    })
    .await
    .map_err(|error| ApiError::internal(format!("Configuration worker failed: {error}")))?
    .map_err(ApiError::bad_request)?;
    serde_json::to_value(config)
        .map(Json)
        .map_err(|error| ApiError::internal(error.to_string()))
}

async fn encode_configuration(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(payload): Json<EncodeConfigurationRequest>,
) -> ApiResult<Json<Value>> {
    validate_origin(&headers, &state.policy)?;
    let config: FrbLayoutConfig = serde_json::from_str(&payload.config_json)
        .map_err(|error| ApiError::bad_request(format!("Invalid layout: {error}")))?;
    let content = match payload.format.to_ascii_lowercase().as_str() {
        "toml" => mds_bridge::api::encode_environment(config),
        "webscp" => mds_bridge::api::encode_environment_webscp(config),
        _ => return Err(ApiError::bad_request("Unsupported configuration format.")),
    };
    Ok(Json(json!({"ok": true, "content": content})))
}

fn login_with_optional_ssh(
    manager: &mut mds_ssh::tunnel::SshTunnelManager,
    api_url: &str,
    user: &str,
    password: &str,
    ssh: Option<&FrbSshSettings>,
) -> Result<(String, String, bool), String> {
    match ssh {
        None => {
            let token = mds_auth::http::request_api_token(api_url, user, password)?;
            Ok((token, api_url.to_string(), false))
        }
        Some(settings) if settings.mode == 1 => {
            if let Ok(token) = mds_auth::http::request_api_token(api_url, user, password) {
                return Ok((token, api_url.to_string(), false));
            }
            manager.reload_settings(settings.clone().into_rust());
            let tunneled = manager.prepare_url_via_ssh(api_url)?;
            let token = mds_auth::http::request_api_token(&tunneled, user, password)?;
            Ok((token, tunneled, true))
        }
        Some(settings) => {
            manager.reload_settings(settings.clone().into_rust());
            let tunneled = manager.prepare_url_via_ssh(api_url)?;
            let token = mds_auth::http::request_api_token(&tunneled, user, password)?;
            Ok((token, tunneled, true))
        }
    }
}

fn authenticated_session(
    state: &GatewayState,
    headers: &HeaderMap,
) -> ApiResult<Arc<BrowserSession>> {
    let id = session_id_from_headers(headers)
        .ok_or_else(|| ApiError::unauthorized("No browser session."))?;
    cleanup_expired_sessions(state);
    let session = state
        .sessions
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&id)
        .cloned()
        .ok_or_else(|| ApiError::unauthorized("Browser session expired."))?;
    session.last_seen.store(unix_seconds(), Ordering::Release);
    if !session
        .auth
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .authenticated
    {
        return Err(ApiError::unauthorized("Sign in before loading data."));
    }
    Ok(session)
}

fn session_auth(session: &BrowserSession) -> ApiResult<SessionAuth> {
    let auth = session
        .auth
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    if !auth.authenticated || auth.token.is_empty() {
        return Err(ApiError::unauthorized(
            "Browser session is not authenticated.",
        ));
    }
    Ok(auth)
}

fn session_for_request(
    state: &GatewayState,
    headers: &HeaderMap,
) -> ApiResult<(String, Arc<BrowserSession>, bool)> {
    cleanup_expired_sessions(state);
    if let Some(id) = session_id_from_headers(headers) {
        if let Some(session) = state
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&id)
            .cloned()
        {
            session.last_seen.store(unix_seconds(), Ordering::Release);
            return Ok((id, session, false));
        }
    }
    let id = new_session_id()?;
    let session = Arc::new(BrowserSession {
        auth: Mutex::new(SessionAuth::default()),
        tunnel: Mutex::new(mds_ssh::tunnel::SshTunnelManager::new()),
        last_seen: AtomicU64::new(unix_seconds()),
    });
    state
        .sessions
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(id.clone(), Arc::clone(&session));
    Ok((id, session, true))
}

fn session_id_from_headers(headers: &HeaderMap) -> Option<String> {
    let cookies = headers.get(COOKIE)?.to_str().ok()?;
    for item in cookies.split(';') {
        let (name, value) = item.trim().split_once('=')?;
        if name == SESSION_COOKIE || name == DEVELOPMENT_SESSION_COOKIE {
            if value.len() >= 32 && value.bytes().all(is_session_character) {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn is_session_character(value: u8) -> bool {
    value.is_ascii_alphanumeric() || value == b'-' || value == b'_'
}

fn new_session_id() -> ApiResult<String> {
    let mut bytes = [0_u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| ApiError::internal("Secure random generator failed."))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn cleanup_expired_sessions(state: &GatewayState) {
    let cutoff = unix_seconds().saturating_sub(SESSION_LIFETIME_SECONDS);
    state
        .sessions
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .retain(|_, session| session.last_seen.load(Ordering::Acquire) >= cutoff);
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs())
}

fn with_session_cookie(
    mut response: Response,
    id: &str,
    created: bool,
    policy: &GatewayPolicy,
) -> Response {
    if created {
        if let Ok(value) = HeaderValue::from_str(&session_cookie(id, policy)) {
            response.headers_mut().insert(SET_COOKIE, value);
        }
    }
    response
}

fn session_cookie(id: &str, policy: &GatewayPolicy) -> String {
    let name = if policy.secure_cookie {
        SESSION_COOKIE
    } else {
        DEVELOPMENT_SESSION_COOKIE
    };
    let secure = if policy.secure_cookie { "; Secure" } else { "" };
    format!(
        "{name}={id}; Path=/; HttpOnly; SameSite=Strict{secure}; Max-Age={SESSION_LIFETIME_SECONDS}"
    )
}

fn expired_cookie(policy: &GatewayPolicy) -> String {
    let name = if policy.secure_cookie {
        SESSION_COOKIE
    } else {
        DEVELOPMENT_SESSION_COOKIE
    };
    let secure = if policy.secure_cookie { "; Secure" } else { "" };
    format!("{name}=; Path=/; HttpOnly; SameSite=Strict{secure}; Max-Age=0")
}

fn validate_origin(headers: &HeaderMap, policy: &GatewayPolicy) -> ApiResult<()> {
    let Some(origin) = headers.get(ORIGIN) else {
        return Ok(());
    };
    let origin = origin
        .to_str()
        .map_err(|_| ApiError::forbidden("Invalid request origin."))?;
    if origin == "null" {
        return Err(ApiError::forbidden("Opaque origins are not allowed."));
    }
    if policy.allowed_origins.contains(origin) {
        return Ok(());
    }
    let host = headers
        .get("host")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    let parsed = Url::parse(origin).map_err(|_| ApiError::forbidden("Invalid request origin."))?;
    if parsed.host_str().is_some()
        && parsed
            .port_or_known_default()
            .map(|port| format!("{}:{port}", parsed.host_str().unwrap_or_default()))
            .is_some_and(|origin_host| origin_host == host)
    {
        return Ok(());
    }
    if parsed
        .host_str()
        .is_some_and(|origin_host| origin_host == host)
    {
        return Ok(());
    }
    Err(ApiError::forbidden(
        "Cross-origin gateway requests are not allowed.",
    ))
}

fn validate_api_url(api_url: &str, policy: &GatewayPolicy) -> ApiResult<()> {
    let parsed = Url::parse(api_url)
        .map_err(|error| ApiError::bad_request(format!("Invalid API URL: {error}")))?;
    if parsed.scheme() != "http" {
        return Err(ApiError::bad_request(
            "The current native EAST API transport requires an http:// URL.",
        ));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| ApiError::bad_request("API URL has no host."))?;
    validate_host(host, policy)
}

fn validate_ssh_settings(settings: &FrbSshSettings, policy: &GatewayPolicy) -> ApiResult<()> {
    if settings.mode <= 0 {
        return Ok(());
    }
    if settings.host.trim().is_empty() || settings.user.trim().is_empty() {
        return Err(ApiError::bad_request("SSH host and user are required."));
    }
    validate_host(endpoint_host(&settings.host), policy)
}

fn validate_signal_hosts(config_json: &str, policy: &GatewayPolicy) -> ApiResult<()> {
    let config: FrbLayoutConfig = serde_json::from_str(config_json)
        .map_err(|error| ApiError::bad_request(format!("Invalid signal layout: {error}")))?;
    for signal in config
        .columns
        .iter()
        .flatten()
        .flat_map(|panel| panel.signal_specs.iter())
    {
        if !signal.server_ip.trim().is_empty() {
            validate_host(endpoint_host(&signal.server_ip), policy)?;
        }
    }
    Ok(())
}

fn endpoint_host(value: &str) -> &str {
    let trimmed = value.trim();
    if trimmed.starts_with('[') {
        return trimmed
            .strip_prefix('[')
            .and_then(|rest| rest.split_once(']'))
            .map_or(trimmed, |(host, _)| host);
    }
    trimmed.rsplit_once(':').map_or(trimmed, |(host, port)| {
        if port.bytes().all(|value| value.is_ascii_digit()) {
            host
        } else {
            trimmed
        }
    })
}

fn validate_host(host: &str, policy: &GatewayPolicy) -> ApiResult<()> {
    let normalized = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if normalized.is_empty() {
        return Err(ApiError::bad_request("Network host is empty."));
    }
    if policy.allow_any_host || policy.allowed_hosts.contains(&normalized) {
        return Ok(());
    }
    Err(ApiError::forbidden(format!(
        "Host '{normalized}' is not in MDSLENS_WEB_ALLOWED_HOSTS."
    )))
}

fn configuration_extension(name: &str) -> ApiResult<&'static str> {
    let lower = name.trim().to_ascii_lowercase();
    if lower.ends_with(".toml") {
        Ok(".toml")
    } else if lower.ends_with(".webscp") {
        Ok(".webscp")
    } else {
        Err(ApiError::bad_request(
            "Only .toml and .webscp configurations are accepted.",
        ))
    }
}

impl GatewayPolicy {
    fn from_environment() -> Self {
        let configured_hosts = env::var("MDSLENS_WEB_ALLOWED_HOSTS")
            .unwrap_or_else(|_| "202.127.204.12,202.127.204.26,202.127.204.41".into());
        let allow_any_host = configured_hosts.split(',').any(|host| host.trim() == "*");
        let allowed_hosts = configured_hosts
            .split(',')
            .map(|host| host.trim().trim_end_matches('.').to_ascii_lowercase())
            .filter(|host| !host.is_empty() && host != "*")
            .collect();
        let allowed_origins = env::var("MDSLENS_WEB_ALLOWED_ORIGINS")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|origin| !origin.is_empty())
            .map(ToOwned::to_owned)
            .collect();
        let secure_cookie = env::var("MDSLENS_WEB_SECURE_COOKIE").map_or(true, |value| {
            value != "0" && !value.eq_ignore_ascii_case("false")
        });
        Self {
            allowed_hosts,
            allow_any_host,
            allowed_origins,
            secure_cookie,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_policy() -> GatewayPolicy {
        GatewayPolicy {
            allowed_hosts: ["mds.example", "202.127.204.12"]
                .into_iter()
                .map(ToOwned::to_owned)
                .collect(),
            allow_any_host: false,
            allowed_origins: HashSet::new(),
            secure_cookie: true,
        }
    }

    #[test]
    fn host_policy_rejects_unlisted_network_destinations() {
        let policy = test_policy();
        assert!(validate_host("mds.example", &policy).is_ok());
        assert!(validate_host("202.127.204.12", &policy).is_ok());
        assert!(validate_host("127.0.0.1", &policy).is_err());
        assert!(validate_host("169.254.169.254", &policy).is_err());
    }

    #[test]
    fn production_cookie_is_not_visible_to_javascript() {
        let cookie = session_cookie("abcdefghijklmnopqrstuvwxyz012345", &test_policy());
        assert!(cookie.contains("HttpOnly"));
        assert!(cookie.contains("Secure"));
        assert!(cookie.contains("SameSite=Strict"));
        assert!(cookie.starts_with("__Host-"));
    }

    #[test]
    fn configuration_extensions_are_strict() {
        assert_eq!(configuration_extension("layout.toml").unwrap(), ".toml");
        assert_eq!(configuration_extension("layout.webscp").unwrap(), ".webscp");
        assert!(configuration_extension("layout.json").is_err());
    }

    #[test]
    fn binary_signal_batches_keep_waveforms_out_of_json() {
        let signal = mds_bridge::api::FrbLoadedSignal {
            column: 1,
            row: 2,
            signal: 3,
            shot: "164309".into(),
            series: mds_bridge::api::FrbSignalSeries {
                name: "IP".into(),
                uniform_y: vec![1.25, 2.5],
                uniform_start: -0.1,
                uniform_step: 0.05,
                points: vec![[3.0, 4.0]],
                ..Default::default()
            },
        };
        let encoded = encode_signal_batch(vec![signal]).unwrap();
        assert_eq!(&encoded[..8], SIGNAL_BATCH_MAGIC);
        assert_eq!(u32::from_le_bytes(encoded[8..12].try_into().unwrap()), 1);
        let metadata_len = u32::from_le_bytes(encoded[12..16].try_into().unwrap()) as usize;
        assert_eq!(u32::from_le_bytes(encoded[16..20].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(encoded[20..24].try_into().unwrap()), 1);
        let metadata: Value = serde_json::from_slice(&encoded[24..24 + metadata_len]).unwrap();
        assert_eq!(metadata["series"]["uniform_y"], json!([]));
        assert_eq!(metadata["series"]["points"], json!([]));
        let uniform_start = (24 + metadata_len + 7) & !7;
        assert_eq!(
            f32::from_le_bytes(
                encoded[uniform_start..uniform_start + 4]
                    .try_into()
                    .unwrap()
            ),
            1.25
        );
        let points_start = (uniform_start + 8 + 7) & !7;
        assert_eq!(
            f64::from_le_bytes(encoded[points_start..points_start + 8].try_into().unwrap()),
            3.0
        );
    }
}
