//! Builds + signs + RLP-encodes the Tempo `0x76` escrow transactions the Swift SDK
//! broadcasts. Swift could encode this, but the format is Tempo-specific and
//! evolving, so binding Tempo's own `tempo-primitives` crate keeps the output
//! byte-identical to the chain's canonical implementation and makes an upgrade a
//! version bump rather than a hand-maintained Swift port. No hand-rolled encoding.
//!
//! Builds the escrow `open`, `topUp`, and `close` transactions (open/topUp are two-call
//! txs: an ERC-20 `approve` then the escrow call). Two surfaces each: the typed Rust
//! builders (`build_open_tx` / `build_top_up_tx` / `build_close_tx`, used by the in-crate
//! tests) and the UniFFI exports (FFI-friendly types: scalars, `Vec<u8>`, and decimal
//! `String`s for `u128` / `u256`) that the Swift wrapper calls. It is
//! packaged into the `TempoTxFFI` xcframework (`build-xcframework.sh`, macOS + iOS
//! slices) on Apple and built as a static archive (`build-linux-lib.sh`) on Linux, then
//! linked by the opt-in `MPPTempoFFI` SwiftPM product.

use alloy_primitives::{Address, Bytes, FixedBytes, Signature, TxKind, U256};
use alloy_sol_types::{sol, SolCall};
use k256::ecdsa::SigningKey;
use tempo_primitives::transaction::Call;
use tempo_primitives::{TempoSignature, TempoTransaction};
use zeroize::{Zeroize, Zeroizing};

sol! {
    // ERC-20 / TIP-20 token approval the escrow needs before it can pull the deposit
    // via transferFrom (open / topUp prepend this call). amount is uint256.
    function approve(address spender, uint256 amount);
    function open(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner);
    // additionalDeposit is uint256 here (close/open amounts are uint128); matches the escrow ABI.
    function topUp(bytes32 channelId, uint256 additionalDeposit);
    function close(bytes32 channelId, uint128 cumulativeAmount, bytes signature);
}

/// A reason a transaction could not be built.
#[derive(Debug)]
pub enum BuildError {
    /// The 32-byte signing key was not a valid secp256k1 private key.
    InvalidKey,
    /// Signing the transaction hash failed.
    SigningFailed,
}

/// A single escrow/token call to a contract: ABI-encoded `calldata` sent `to` an
/// address (value is always zero; the escrow moves TIP-20 tokens, not native value).
fn call(to: Address, calldata: Vec<u8>) -> Call {
    Call {
        to: TxKind::Call(to),
        value: U256::ZERO,
        input: Bytes::from(calldata),
    }
}

/// Assembles a Tempo `0x76` transaction from `calls`, signs it with `private_key`, and
/// returns the raw EIP-2718 bytes ready to broadcast via `eth_sendRawTransaction`. The
/// fee/nonce inputs come from the caller (the Swift side reads them over JSON-RPC). The
/// key's raw bytes are zeroized on every path; the k256 `SigningKey` is zeroize-on-drop.
#[allow(clippy::too_many_arguments)]
fn build_signed_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    mut private_key: [u8; 32],
    calls: Vec<Call>,
) -> Result<Vec<u8>, BuildError> {
    let tx = TempoTransaction {
        chain_id,
        fee_token,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        calls,
        nonce_key: U256::ZERO, // 0 = the protocol (sequential) nonce
        nonce,
        ..Default::default()
    };

    let hash = tx.signature_hash();
    let signing_key_result = SigningKey::from_bytes((&private_key).into());
    private_key.zeroize();
    let signing_key = signing_key_result.map_err(|_| BuildError::InvalidKey)?;
    let (sig, recid) = signing_key
        .sign_prehash_recoverable(hash.as_slice())
        .map_err(|_| BuildError::SigningFailed)?;
    let alloy_sig = Signature::new(
        U256::from_be_slice(&sig.r().to_bytes()),
        U256::from_be_slice(&sig.s().to_bytes()),
        recid.is_y_odd(),
    );

    let signed = tx.into_signed(TempoSignature::from(alloy_sig));
    let mut out = Vec::new();
    signed.eip2718_encode(&mut out);
    Ok(out)
}

/// Builds the signed `0x76` transaction that calls `escrow.close(channelId,
/// cumulativeAmount, voucherSignature)`. `voucher_signature` is the payer/
/// authorized-signer signature the escrow recovers (`ecrecover`); `private_key` is
/// the sender's key (it pays gas). A single-call transaction.
#[allow(clippy::too_many_arguments)]
pub fn build_close_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    private_key: [u8; 32],
    escrow: Address,
    channel_id: [u8; 32],
    cumulative_amount: u128,
    voucher_signature: Vec<u8>,
) -> Result<Vec<u8>, BuildError> {
    let close = closeCall {
        channelId: FixedBytes::<32>::from(channel_id),
        cumulativeAmount: cumulative_amount,
        signature: Bytes::from(voucher_signature),
    }
    .abi_encode();
    build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(escrow, close)],
    )
}

/// Builds the signed `0x76` transaction that opens a channel: a two-call transaction
/// that first `approve`s the escrow to pull `deposit` of `token`, then calls
/// `escrow.open(payee, token, deposit, salt, authorizedSigner)`. Mirrors the reference
/// mppx client (`approve` then `open`, `feeToken` typically the token itself).
#[allow(clippy::too_many_arguments)]
pub fn build_open_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    private_key: [u8; 32],
    escrow: Address,
    token: Address,
    payee: Address,
    deposit: u128,
    salt: [u8; 32],
    authorized_signer: Address,
) -> Result<Vec<u8>, BuildError> {
    let approve = approveCall {
        spender: escrow,
        amount: U256::from(deposit),
    }
    .abi_encode();
    let open = openCall {
        payee,
        token,
        deposit,
        salt: FixedBytes::<32>::from(salt),
        authorizedSigner: authorized_signer,
    }
    .abi_encode();
    build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(token, approve), call(escrow, open)],
    )
}

/// Builds the signed `0x76` transaction that tops up a channel: a two-call transaction
/// that first `approve`s the escrow to pull `additional_deposit` of `token`, then calls
/// `escrow.topUp(channelId, additionalDeposit)`. `additional_deposit` is a `uint256`.
#[allow(clippy::too_many_arguments)]
pub fn build_top_up_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    private_key: [u8; 32],
    escrow: Address,
    token: Address,
    channel_id: [u8; 32],
    additional_deposit: U256,
) -> Result<Vec<u8>, BuildError> {
    let approve = approveCall {
        spender: escrow,
        amount: additional_deposit,
    }
    .abi_encode();
    let top_up = topUpCall {
        channelId: FixedBytes::<32>::from(channel_id),
        additionalDeposit: additional_deposit,
    }
    .abi_encode();
    build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(token, approve), call(escrow, top_up)],
    )
}

// ── UniFFI export layer ────────────────────────────────────────────────────────
// FFI-friendly surface for the Swift wrapper: scalars + Vec<u8> + decimal Strings
// for u128 (UniFFI has no u128 / fixed arrays / alloy types). Validates, then calls
// the typed `build_close_tx` above.

uniffi::setup_scaffolding!();

/// A reason the FFI close-tx build failed.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    /// An argument was the wrong length or not a valid value (the message names it).
    #[error("invalid input: {0}")]
    InvalidInput(String),
    /// The signing key was not a valid secp256k1 private key.
    #[error("invalid signing key")]
    InvalidKey,
    /// Signing the transaction hash failed.
    #[error("signing failed")]
    SigningFailed,
}

fn parse_u128(label: &str, text: &str) -> Result<u128, FfiError> {
    text.parse::<u128>()
        .map_err(|_| FfiError::InvalidInput(format!("{label}: not a u128")))
}

fn parse_u256(label: &str, text: &str) -> Result<U256, FfiError> {
    U256::from_str_radix(text, 10)
        .map_err(|_| FfiError::InvalidInput(format!("{label}: not a u256")))
}

fn parse_address(label: &str, bytes: &[u8]) -> Result<Address, FfiError> {
    if bytes.len() != 20 {
        return Err(FfiError::InvalidInput(format!("{label}: need 20 bytes")));
    }
    Ok(Address::from_slice(bytes))
}

fn parse_optional_address(label: &str, bytes: Option<Vec<u8>>) -> Result<Option<Address>, FfiError> {
    match bytes {
        Some(bytes) => Ok(Some(parse_address(label, &bytes)?)),
        None => Ok(None),
    }
}

fn parse_bytes32(label: &str, bytes: Vec<u8>) -> Result<[u8; 32], FfiError> {
    bytes
        .try_into()
        .map_err(|_| FfiError::InvalidInput(format!("{label}: need 32 bytes")))
}

/// Copies the 32-byte key out of the incoming `Vec` and zeroizes the `Vec`'s heap
/// buffer (a `try_into` move would drop it un-zeroized). The returned `Zeroizing` is
/// wiped on every exit path; the typed builder also zeroizes its own by-value copy.
fn take_key(private_key: Vec<u8>) -> Result<Zeroizing<[u8; 32]>, FfiError> {
    let mut private_key = private_key;
    let key_bytes: Result<[u8; 32], _> = private_key.as_slice().try_into();
    private_key.zeroize();
    Ok(Zeroizing::new(key_bytes.map_err(|_| {
        FfiError::InvalidInput("private_key: need 32 bytes".into())
    })?))
}

fn map_build_error(error: BuildError) -> FfiError {
    match error {
        BuildError::InvalidKey => FfiError::InvalidKey,
        BuildError::SigningFailed => FfiError::SigningFailed,
    }
}

/// UniFFI entry point: build + sign + RLP-encode the escrow `close` `0x76` tx.
/// `max_fee_per_gas` / `max_priority_fee_per_gas` / `cumulative_amount` are decimal
/// `u128` strings; `fee_token` / `escrow` are 20-byte addresses; `private_key` and
/// `channel_id` are 32 bytes; `voucher_signature` is the 65-byte voucher signature.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_close_transaction(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    gas_limit: u64,
    fee_token: Option<Vec<u8>>,
    private_key: Vec<u8>,
    escrow: Vec<u8>,
    channel_id: Vec<u8>,
    cumulative_amount: String,
    voucher_signature: Vec<u8>,
) -> Result<Vec<u8>, FfiError> {
    let key = take_key(private_key)?;
    build_close_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        parse_optional_address("fee_token", fee_token)?,
        *key,
        parse_address("escrow", &escrow)?,
        parse_bytes32("channel_id", channel_id)?,
        parse_u128("cumulative_amount", &cumulative_amount)?,
        voucher_signature,
    )
    .map_err(map_build_error)
}

/// UniFFI entry point: build + sign + RLP-encode the escrow `open` `0x76` tx (a two-call
/// approve + open). `deposit` is a decimal `u128` string; `escrow` / `token` / `payee` /
/// `authorized_signer` are 20-byte addresses; `private_key` and `salt` are 32 bytes.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_open_transaction(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    gas_limit: u64,
    fee_token: Option<Vec<u8>>,
    private_key: Vec<u8>,
    escrow: Vec<u8>,
    token: Vec<u8>,
    payee: Vec<u8>,
    deposit: String,
    salt: Vec<u8>,
    authorized_signer: Vec<u8>,
) -> Result<Vec<u8>, FfiError> {
    let key = take_key(private_key)?;
    build_open_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        parse_optional_address("fee_token", fee_token)?,
        *key,
        parse_address("escrow", &escrow)?,
        parse_address("token", &token)?,
        parse_address("payee", &payee)?,
        parse_u128("deposit", &deposit)?,
        parse_bytes32("salt", salt)?,
        parse_address("authorized_signer", &authorized_signer)?,
    )
    .map_err(map_build_error)
}

/// UniFFI entry point: build + sign + RLP-encode the escrow `topUp` `0x76` tx (a two-call
/// approve + topUp). `additional_deposit` is a decimal `u256` string; `escrow` / `token`
/// are 20-byte addresses; `private_key` and `channel_id` are 32 bytes.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_top_up_transaction(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    gas_limit: u64,
    fee_token: Option<Vec<u8>>,
    private_key: Vec<u8>,
    escrow: Vec<u8>,
    token: Vec<u8>,
    channel_id: Vec<u8>,
    additional_deposit: String,
) -> Result<Vec<u8>, FfiError> {
    let key = take_key(private_key)?;
    build_top_up_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        parse_optional_address("fee_token", fee_token)?,
        *key,
        parse_address("escrow", &escrow)?,
        parse_address("token", &token)?,
        parse_bytes32("channel_id", channel_id)?,
        parse_u256("additional_deposit", &additional_deposit)?,
    )
    .map_err(map_build_error)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fixed inputs -> a fixed, signed close tx. Locks the exact bytes (k256 uses
    /// deterministic RFC-6979 nonces, so this is reproducible) as a regression net:
    /// any change in the format, a dep bump, or our code that alters the output
    /// trips this. The live-Moderato e2e is the authoritative on-chain check.
    #[test]
    fn close_tx_golden_bytes() {
        let bytes = build_close_tx(
            42431,
            7,
            1_000_000_000,
            1_000_000,
            100_000,
            None,
            [0x11; 32],
            Address::from([0x55; 20]),
            [0xAB; 32],
            1000,
            vec![0u8; 65],
        )
        .expect("build");
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        // The 2718 envelope leads with the Tempo tx type id 0x76.
        assert_eq!(bytes.first(), Some(&0x76));
        // Full golden (351 bytes); identical on tempo-primitives 1.7.2 and 1.8.0.
        assert_eq!(hex, GOLDEN_CLOSE_TX);
    }

    /// The UniFFI wrapper (FFI-friendly types) parses to the same inputs and produces
    /// the identical bytes, so the boundary marshalling is faithful.
    #[test]
    fn ffi_wrapper_matches_golden() {
        let bytes = build_close_transaction(
            42431,
            7,
            "1000000000".into(),
            "1000000".into(),
            100_000,
            None,
            vec![0x11; 32],
            vec![0x55; 20],
            vec![0xAB; 32],
            "1000".into(),
            vec![0u8; 65],
        )
        .expect("build");
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_CLOSE_TX);
    }

    #[test]
    fn ffi_wrapper_rejects_bad_lengths() {
        // 31-byte key -> InvalidInput, not a panic.
        let result = build_close_transaction(
            42431, 7, "1".into(), "1".into(), 1, None,
            vec![0x11; 31], vec![0x55; 20], vec![0xAB; 32], "1".into(), vec![0u8; 65],
        );
        assert!(matches!(result, Err(FfiError::InvalidInput(_))));
    }

    fn open_fixture() -> Vec<u8> {
        build_open_tx(
            42431,
            7,
            1_000_000_000,
            1_000_000,
            100_000,
            None,
            [0x11; 32],
            Address::from([0x55; 20]), // escrow
            Address::from([0x22; 20]), // token
            Address::from([0x33; 20]), // payee
            1000,
            [0xAB; 32], // salt
            Address::from([0x44; 20]), // authorizedSigner
        )
        .expect("build open")
    }

    fn top_up_fixture() -> Vec<u8> {
        build_top_up_tx(
            42431,
            7,
            1_000_000_000,
            1_000_000,
            100_000,
            None,
            [0x11; 32],
            Address::from([0x55; 20]), // escrow
            Address::from([0x22; 20]), // token
            [0xAB; 32],                // channelId
            U256::from(1000u64),
        )
        .expect("build topUp")
    }

    /// The byte offset of `needle` within `haystack`, or `None`.
    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack.windows(needle.len()).position(|w| w == needle)
    }

    /// The first 4 bytes of `keccak256(signature)`: the Solidity function selector,
    /// recomputed here as an INDEPENDENT oracle (not via the same `sol!` path the
    /// builder uses), so a wrong ABI in the builder is caught rather than mirrored.
    fn selector(signature: &[u8]) -> [u8; 4] {
        alloy_primitives::keccak256(signature)[..4].try_into().expect("4 bytes")
    }

    /// open is a two-call tx: approve(escrow, deposit) on the token, then
    /// open(...) on the escrow. Structurally verified by independent selectors +
    /// call order, then locked to the full golden bytes.
    #[test]
    fn open_tx_golden_and_structure() {
        let bytes = open_fixture();
        assert_eq!(bytes.first(), Some(&0x76));

        // The canonical ERC-20 approve selector is the well-known constant 0x095ea7b3;
        // matching it confirms the approve calldata is correct independently of `sol!`.
        let approve = selector(b"approve(address,uint256)");
        assert_eq!(approve, [0x09, 0x5e, 0xa7, 0xb3]);
        let open = selector(b"open(address,address,uint128,bytes32,address)");
        let approve_at = find(&bytes, &approve).expect("approve selector present");
        let open_at = find(&bytes, &open).expect("open selector present");
        // approve is the first call, open the second.
        assert!(approve_at < open_at, "approve must precede open");

        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_OPEN_TX);
    }

    /// topUp is a two-call tx: approve(escrow, amount) on the token, then
    /// topUp(channelId, amount) on the escrow. `additionalDeposit` is a uint256.
    #[test]
    fn top_up_tx_golden_and_structure() {
        let bytes = top_up_fixture();
        assert_eq!(bytes.first(), Some(&0x76));

        let approve = selector(b"approve(address,uint256)");
        assert_eq!(approve, [0x09, 0x5e, 0xa7, 0xb3]);
        let top_up = selector(b"topUp(bytes32,uint256)");
        let approve_at = find(&bytes, &approve).expect("approve selector present");
        let top_up_at = find(&bytes, &top_up).expect("topUp selector present");
        assert!(approve_at < top_up_at, "approve must precede topUp");

        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_TOP_UP_TX);
    }

    /// The UniFFI wrappers parse the FFI-friendly types to the same inputs and produce
    /// the identical bytes as the typed builders.
    #[test]
    fn ffi_open_and_top_up_match_golden() {
        let open = build_open_transaction(
            42431, 7, "1000000000".into(), "1000000".into(), 100_000, None,
            vec![0x11; 32], vec![0x55; 20], vec![0x22; 20], vec![0x33; 20],
            "1000".into(), vec![0xAB; 32], vec![0x44; 20],
        )
        .expect("build open");
        assert_eq!(open.iter().map(|b| format!("{b:02x}")).collect::<String>(), GOLDEN_OPEN_TX);

        let top_up = build_top_up_transaction(
            42431, 7, "1000000000".into(), "1000000".into(), 100_000, None,
            vec![0x11; 32], vec![0x55; 20], vec![0x22; 20], vec![0xAB; 32], "1000".into(),
        )
        .expect("build topUp");
        assert_eq!(top_up.iter().map(|b| format!("{b:02x}")).collect::<String>(), GOLDEN_TOP_UP_TX);
    }

    const GOLDEN_CLOSE_TX: &str = "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555555555555580b8e40d65c51dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0800780808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c";

    const GOLDEN_OPEN_TX: &str = "76f9017a82a5bf830f4240843b9aca00830186a0f9011cf85c94222222222222222222222222222222222222222280b844095ea7b3000000000000000000000000555555555555555555555555555555555555555500000000000000000000000000000000000000000000000000000000000003e8f8bc94555555555555555555555555555555555555555580b8a4c79ea4850000000000000000000000003333333333333333333333333333333333333333000000000000000000000000222222222222222222222222222222222222222200000000000000000000000000000000000000000000000000000000000003e8abababababababababababababababababababababababababababababababab0000000000000000000000004444444444444444444444444444444444444444c0800780808080c0b841de9fb016ce44ed02dca54f29b1ebabe7a64a1a6ac99e83a58cc1adb6cee88d887406777d5e7e3347d60866e9569ae234a3faa625ee643ef6986d7115ec1deb591b";

    const GOLDEN_TOP_UP_TX: &str = "76f9011982a5bf830f4240843b9aca00830186a0f8bcf85c94222222222222222222222222222222222222222280b844095ea7b3000000000000000000000000555555555555555555555555555555555555555500000000000000000000000000000000000000000000000000000000000003e8f85c94555555555555555555555555555555555555555580b844b67644b9abababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e8c0800780808080c0b841614b14a310bd2d62e898ea879e38c84dbd59b869209c51dd4c261b2eddce322439e6f11f9a4b5678909d4ab9bf29e8052abcb7ab9f6c4518e6455ec5d0ae43241b";
}

