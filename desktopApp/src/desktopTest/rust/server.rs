//! 隔离集成测试桌面：真实 SPAKE2 配对、认证恢复、加密快照和 PNG 分块。
//! 身份与图片全部为合成数据；stdout 只输出控制事件，不打印配对码或秘密。

use loki_metris_pairing::{SenderSession, assets::AssetDescriptor, session::{AwaitingDeviceProof, SecureChannel}};
use serde_json::{Value, json};
use std::{error::Error, io::{self, BufRead, Read, Write}, net::{Shutdown, TcpListener, TcpStream}, thread, time::{Duration, Instant}};

const CLIENT: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const PAIR_SESSION: &str = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const RESUME_CHALLENGE: &str = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const FRAME_LIMIT: usize = 96 * 1024;
const PNG: &[u8] = include_bytes!(env!("LOKI_DESKTOP_TEST_PNG"));
type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn require(condition: bool, message: &'static str) -> Result<()> {
    if condition { Ok(()) } else { Err(io::Error::new(io::ErrorKind::InvalidData, message).into()) }
}

fn event(value: Value) -> Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, &value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn read_frame(stream: &mut TcpStream) -> Result<Value> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    require(length > 0 && length <= FRAME_LIMIT, "fixture_frame_limit")?;
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes)?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn write_frame(stream: &mut TcpStream, value: Value) -> Result<()> {
    let bytes = serde_json::to_vec(&value)?;
    require(!bytes.is_empty() && bytes.len() <= FRAME_LIMIT, "fixture_frame_limit")?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&bytes)?;
    stream.flush()?;
    Ok(())
}

fn send_secure(stream: &mut TcpStream, channel: &mut SecureChannel, value: Value) -> Result<()> {
    let packet = channel.seal(&serde_json::to_vec(&value)?)?;
    write_frame(stream, serde_json::to_value(packet)?)
}

fn read_secure(stream: &mut TcpStream, channel: &mut SecureChannel) -> Result<Value> {
    let packet = serde_json::from_value(read_frame(stream)?)?;
    Ok(serde_json::from_slice(&channel.open(&packet)?)?)
}

fn accept(listener: &TcpListener) -> Result<TcpStream> {
    let deadline = Instant::now() + Duration::from_secs(25);
    loop {
        match listener.accept() {
            Ok((stream, peer)) => {
                require(peer.ip().is_loopback(), "fixture_requires_loopback")?;
                stream.set_nonblocking(false)?;
                stream.set_read_timeout(Some(Duration::from_secs(10)))?;
                stream.set_write_timeout(Some(Duration::from_secs(10)))?;
                stream.set_nodelay(true)?;
                return Ok(stream);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            Err(error) => return Err(error.into()),
        }
    }
}

fn snapshot(asset: &AssetDescriptor) -> Value {
    let amount = json!({"total":"1000000001", "availability":"available", "completeness":"complete", "confidence":"exact"});
    json!({
        "type":"snapshot", "capabilities":["deviceFormFactorV1"],
        "snapshot": {
            "version":1,
            "tokens": {
                "day":{"date":"2026-10-22","zone":"Asia/Shanghai","startMs":1792598400000_i64,"endMs":1792684800000_i64},
                "observedMs":1792602000000_i64,
                "all":amount,
                "agents":[{"agent":"codex","amount":amount}]
            },
            "hooksAvailable":true,
            "hooks":[{"agent":"codex","slot":1,"behavior":"running","content":"桌面真实通道测试 🖥️🚀 中文与 emoji", "contentTruncated":false,"image":asset.hash}],
            "assets":[asset],
            "enabledAgents":["codex"]
        }
    })
}

fn fixture() -> Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    listener.set_nonblocking(true)?;
    event(json!({"port":listener.local_addr()?.port()}))?;
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut code = String::new();
    require(input.read_line(&mut code)? > 0, "fixture_code_missing")?;
    let code = code.trim_end_matches(['\r', '\n']);
    require(loki_metris_pairing::valid_pairing_code(code), "fixture_code_invalid")?;

    let mut pairing = accept(&listener)?;
    let intro = read_frame(&mut pairing)?;
    require(intro["kind"] == "pairing" && intro["value"]["clientId"] == CLIENT, "fixture_pairing_offer_invalid")?;
    let device = intro["value"]["deviceId"].as_str().ok_or("fixture_device_missing")?.to_owned();
    let (sender, hello) = SenderSession::start(CLIENT, &device, code, PAIR_SESSION.to_owned())?;
    write_frame(&mut pairing, serde_json::to_value(hello)?)?;
    let (sender, confirmation) = sender.accept(serde_json::from_value(read_frame(&mut pairing)?)?)?;
    write_frame(&mut pairing, serde_json::to_value(confirmation)?)?;
    let material = sender.verify(serde_json::from_value(read_frame(&mut pairing)?)?)?;
    let secret = *material.secret_bytes();
    pairing.shutdown(Shutdown::Both)?;
    drop(pairing);

    let mut stream = accept(&listener)?;
    let intro = read_frame(&mut stream)?;
    require(intro["kind"] == "resume", "fixture_resume_offer_invalid")?;
    let (proof, reply) = AwaitingDeviceProof::accept(serde_json::from_value(intro["value"].clone())?, CLIENT, &device, &secret, RESUME_CHALLENGE.to_owned())?;
    write_frame(&mut stream, serde_json::to_value(reply)?)?;
    let mut channel = proof.verify(serde_json::from_value(read_frame(&mut stream)?)?)?;
    let metadata = read_secure(&mut stream, &mut channel)?;
    require(metadata["deviceId"] == device && metadata["platform"] == "android", "fixture_metadata_invalid")?;

    let asset = AssetDescriptor::from_bytes(PNG)?;
    let initial = snapshot(&asset);
    send_secure(&mut stream, &mut channel, initial.clone())?;
    let mut form_factor = false;
    let mut asset_sent = false;
    while !form_factor || !asset_sent {
        let message = read_secure(&mut stream, &mut channel)?;
        match message["type"].as_str() {
            Some("deviceFormFactor") => {
                require(!form_factor && message["formFactor"] == "tablet", "fixture_form_factor_invalid_or_duplicate")?;
                form_factor = true;
            }
            Some("assetRequest") => {
                require(!asset_sent && message["hash"] == asset.hash && message["offset"] == 0, "fixture_asset_request_invalid")?;
                send_secure(&mut stream, &mut channel, json!({"type":"assetChunk", "chunk":asset.chunk(PNG, 0)?}))?;
                asset_sent = true;
            }
            _ => return Err("fixture_unexpected_message".into()),
        }
    }
    // 第二个完整快照不得再次上报设备类别；紧随其后的 pong 形成可观测的序号屏障。
    send_secure(&mut stream, &mut channel, initial)?;
    send_secure(&mut stream, &mut channel, json!({"type":"ping", "nonce":7}))?;
    let pong = read_secure(&mut stream, &mut channel)?;
    require(pong["type"] == "pong" && pong["nonce"] == 7, "fixture_pong_or_single_form_factor_failed")?;
    event(json!({"streaming":true}))?;

    let mut command = String::new();
    require(input.read_line(&mut command)? > 0 && command.trim_end_matches(['\r', '\n']) == "disconnect", "fixture_disconnect_missing")?;
    stream.shutdown(Shutdown::Both)?;
    drop(stream);
    drop(listener);
    event(json!({"disconnected":true}))?;
    Ok(())
}

fn main() {
    if let Err(error) = fixture() {
        eprintln!("desktop-link-fixture: {error}");
        std::process::exit(1);
    }
}
