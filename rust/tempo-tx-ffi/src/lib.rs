//! Builds + signs + RLP-encodes the Tempo `0x76` escrow transactions the Swift SDK
//! broadcasts. Swift could encode this, but the format is Tempo-specific and
//! evolving, so binding Tempo's own `tempo-primitives` crate keeps the output
//! byte-identical to the chain's canonical implementation and makes an upgrade a
//! version bump rather than a hand-maintained Swift port. No hand-rolled encoding.
//!
//! Builds the escrow `open`, `topUp`, and `close` transactions (open/topUp are two-call
//! txs: an ERC-20 `approve` then the escrow call), plus the two `transferWithMemo` builders:
//! the recurring subscription charge (signed by an access key as a V2 keychain signature,
//! optional fee-payer sponsor) and the one-time settled charge (signed directly by the payer).
//! Two surfaces each: the typed Rust builders (`build_open_tx` / `build_top_up_tx` /
//! `build_close_tx` / `build_subscription_charge_tx` / `build_transfer_tx`, used by the in-crate
//! tests) and the UniFFI exports (FFI-friendly types: scalars, `Vec<u8>`, and decimal
//! `String`s for `u128` / `u256`) that the Swift wrapper calls. It is
//! packaged into the `TempoTxFFI` xcframework (`build-xcframework.sh`, macOS + iOS
//! slices) on Apple and built as a static archive (`build-linux-lib.sh`) on Linux, then
//! linked by the opt-in `MPPTempoFFI` SwiftPM product.

use alloy_primitives::{Address, Bytes, FixedBytes, Signature, TxKind, U256};
use alloy_sol_types::{sol, SolCall};
use k256::ecdsa::SigningKey;
use tempo_primitives::transaction::key_authorization::{KeyAuthorization, SignedKeyAuthorization};
use tempo_primitives::transaction::tempo_transaction::FEE_PAYER_SIGNATURE_MARKER;
use tempo_primitives::transaction::tt_signature::KeychainSignature;
use tempo_primitives::transaction::{Call, PrimitiveSignature};
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
    // TIP-20 recurring subscription charge: moves `amount` of the currency to `recipient`
    // with an MPP attribution `memo`. Signed by the access key the subscription delegated.
    function transferWithMemo(address recipient, uint256 amount, bytes32 memo);
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
    key_authorization: Option<SignedKeyAuthorization>,
    keychain_user_address: Option<Address>,
    mut fee_payer_key: Option<[u8; 32]>,
) -> Result<Vec<u8>, BuildError> {
    // A sponsored tx carries a fee-payer signature: the fee payer (not the sender) pays gas, so
    // gas is NOT drawn from the access key's spending limit. While the sender signs, the field
    // holds a marker (so the sender's hash uses the placeholder + skips committing to the fee
    // token); the real fee-payer signature replaces it below.
    let sponsored = fee_payer_key.is_some() && keychain_user_address.is_some();
    let mut tx = TempoTransaction {
        chain_id,
        fee_token,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        calls,
        nonce_key: U256::ZERO, // 0 = the protocol (sequential) nonce
        nonce,
        // Present only for the provisioning charge: adds the access key to the
        // AccountKeychain precompile before the tx signature is verified.
        key_authorization,
        fee_payer_signature: sponsored.then_some(FEE_PAYER_SIGNATURE_MARKER),
        ..Default::default()
    };

    let hash = tx.signature_hash();
    let signing_key_result = SigningKey::from_bytes((&private_key).into());
    private_key.zeroize();

    // Parse the fee-payer (sponsor) key eagerly too, before any fallible `?` below, so neither
    // key's raw bytes can survive on an early-return path. We *borrow* it (no `take()`/move): a
    // move of a `Copy` `[u8; 32]` out of the `Option` would leave the original payload bytes
    // behind un-wiped (`None` only rewrites the discriminant), so we keep it `Some` and let the
    // in-place `zeroize()` below overwrite the real bytes. The fee-payer signature itself is built
    // after the sender's (it commits to the same tx); we only capture the parsed key + hash here.
    // A fee payer is honoured only with a keychain context (a sponsored access-key tx).
    let fee_payer_prep = match (keychain_user_address, fee_payer_key.as_ref()) {
        (Some(sender), Some(key)) => {
            let fee_payer_hash = tx.fee_payer_signature_hash(sender);
            Some((SigningKey::from_bytes(key.into()), fee_payer_hash))
        }
        _ => None,
    };
    fee_payer_key.zeroize();

    let signing_key = signing_key_result.map_err(|_| BuildError::InvalidKey)?;
    // A keychain (access-key) signature signs `keccak256(0x04 || sig_hash || user_address)` (V2),
    // so the chain executes the tx for `user_address` (the root) on behalf of the signing access
    // key; a plain signature signs the tx hash directly.
    let effective_hash = match keychain_user_address {
        Some(user_address) => KeychainSignature::signing_hash(hash, user_address),
        None => hash,
    };
    let (sig, recid) = signing_key
        .sign_prehash_recoverable(effective_hash.as_slice())
        .map_err(|_| BuildError::SigningFailed)?;
    let alloy_sig = Signature::new(
        U256::from_be_slice(&sig.r().to_bytes()),
        U256::from_be_slice(&sig.s().to_bytes()),
        recid.is_y_odd(),
    );
    let tempo_sig = match keychain_user_address {
        Some(user_address) => TempoSignature::Keychain(KeychainSignature::new(
            user_address,
            PrimitiveSignature::Secp256k1(alloy_sig),
        )),
        None => TempoSignature::from(alloy_sig),
    };

    // Build the fee-payer signature from the key parsed (and wiped) above. The fee payer signs
    // `fee_payer_signature_hash(sender)`, committing the sponsor to the fee token and the gas.
    if let Some((parsed, fee_payer_hash)) = fee_payer_prep {
        let fee_payer_signing_key = parsed.map_err(|_| BuildError::InvalidKey)?;
        let (fee_sig, fee_recid) = fee_payer_signing_key
            .sign_prehash_recoverable(fee_payer_hash.as_slice())
            .map_err(|_| BuildError::SigningFailed)?;
        tx.fee_payer_signature = Some(Signature::new(
            U256::from_be_slice(&fee_sig.r().to_bytes()),
            U256::from_be_slice(&fee_sig.s().to_bytes()),
            fee_recid.is_y_odd(),
        ));
    }

    let signed = tx.into_signed(tempo_sig);
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
    mut private_key: [u8; 32],
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
    // `[u8; 32]` is `Copy`, so zeroize this caller-frame copy after handing one to
    // build_signed_tx (which wipes its own); nothing keeps the key un-zeroized.
    let result = build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(escrow, close)],
        None,
        None,
        None,
    );
    private_key.zeroize();
    result
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
    mut private_key: [u8; 32],
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
    let result = build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(token, approve), call(escrow, open)],
        None,
        None,
        None,
    );
    private_key.zeroize();
    result
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
    mut private_key: [u8; 32],
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
    let result = build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(token, approve), call(escrow, top_up)],
        None,
        None,
        None,
    );
    private_key.zeroize();
    result
}

/// Builds the signed `0x76` transaction for a recurring subscription charge: a single
/// call to `currency.transferWithMemo(recipient, amount, memo)`, signed by the access
/// key the subscription delegated as a **keychain (V2) signature** for `root_address` (the
/// payer), so the chain executes the transfer for the payer on behalf of the access key.
/// When `key_authorization` is present (the first, provisioning charge) it is attached so
/// the chain registers the access key in the AccountKeychain precompile before verifying
/// this tx's keychain signature; later charges pass `None` (the key is already provisioned).
/// `amount` is a `uint256`.
#[allow(clippy::too_many_arguments)]
pub fn build_subscription_charge_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    mut private_key: [u8; 32],
    root_address: Address,
    currency: Address,
    recipient: Address,
    amount: U256,
    memo: [u8; 32],
    key_authorization: Option<SignedKeyAuthorization>,
    mut fee_payer_key: Option<[u8; 32]>,
) -> Result<Vec<u8>, BuildError> {
    let transfer = transferWithMemoCall {
        recipient,
        amount,
        memo: FixedBytes::<32>::from(memo),
    }
    .abi_encode();
    let result = build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(currency, transfer)],
        key_authorization,
        Some(root_address),
        fee_payer_key,
    );
    // `[u8; 32]` is Copy, so `build_signed_tx` zeroized its own copy but this caller frame keeps
    // one; wipe it too (parity with `private_key`).
    private_key.zeroize();
    fee_payer_key.zeroize();
    result
}

/// Builds the signed `0x76` transaction for a one-time **settled charge**
/// (`draft-tempo-charge-00`): a single call to `currency.transferWithMemo(recipient, amount, memo)`,
/// signed **directly by the payer** as a plain signature. It is the same `transferWithMemo` call as
/// a subscription charge, but the payer signs it itself: there is no access key, so no keychain
/// signature and no `key_authorization` to provision (`build_signed_tx` is invoked with no keychain
/// context, which yields a plain payer signature over the tx hash). `amount` is a `uint256`. The
/// payer pays gas in `fee_token`; fee-payer (sponsor) gas is a separate, later slice.
#[allow(clippy::too_many_arguments)]
pub fn build_transfer_tx(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    gas_limit: u64,
    fee_token: Option<Address>,
    mut private_key: [u8; 32],
    currency: Address,
    recipient: Address,
    amount: U256,
    memo: [u8; 32],
) -> Result<Vec<u8>, BuildError> {
    let transfer = transferWithMemoCall {
        recipient,
        amount,
        memo: FixedBytes::<32>::from(memo),
    }
    .abi_encode();
    let result = build_signed_tx(
        chain_id,
        nonce,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        gas_limit,
        fee_token,
        private_key,
        vec![call(currency, transfer)],
        None, // no access key to provision
        None, // no keychain context -> a plain payer signature over the tx hash
        None, // payer pays gas; sponsored (fee-payer) charge is a later slice
    );
    // `[u8; 32]` is Copy, so `build_signed_tx` zeroized its own copy but this frame keeps one.
    private_key.zeroize();
    result
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

fn parse_optional_address(
    label: &str,
    bytes: Option<Vec<u8>>,
) -> Result<Option<Address>, FfiError> {
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

/// Decodes the subscription-credential wire form `RLP([authorizationTuple, 65-byte
/// r‖s‖v])` (what Swift `TempoKeyAuthorization` and ox `KeyAuthorization.serialize`
/// both emit) into a `SignedKeyAuthorization`. The crate's derived RLP encodes the
/// signature field structurally (not as a 65-byte blob), so we decode the inner tuple
/// with the canonical `KeyAuthorization` decoder and rebuild the signature from the 65
/// bytes, then `into_signed`.
fn decode_key_authorization(bytes: Vec<u8>) -> Result<SignedKeyAuthorization, FfiError> {
    use alloy_rlp::{Decodable, Header};
    let mut slice: &[u8] = &bytes;
    let header = Header::decode(&mut slice)
        .map_err(|_| FfiError::InvalidInput("key_authorization: not RLP".into()))?;
    if !header.list {
        return Err(FfiError::InvalidInput(
            "key_authorization: not an RLP list".into(),
        ));
    }
    // Bound inner decoding to exactly the list's declared payload (the canonical alloy-rlp
    // pattern): decode the items from a sub-slice of `payload_length` bytes and reject any
    // bytes trailing the list, so a header that over- or under-declares its length fails.
    if slice.len() < header.payload_length {
        return Err(FfiError::InvalidInput(
            "key_authorization: truncated list".into(),
        ));
    }
    let (mut payload, rest) = slice.split_at(header.payload_length);
    if !rest.is_empty() {
        return Err(FfiError::InvalidInput(
            "key_authorization: trailing bytes after list".into(),
        ));
    }
    let authorization = KeyAuthorization::decode(&mut payload)
        .map_err(|_| FfiError::InvalidInput("key_authorization: bad authorization tuple".into()))?;
    let signature_bytes = Bytes::decode(&mut payload)
        .map_err(|_| FfiError::InvalidInput("key_authorization: missing signature".into()))?;
    if !payload.is_empty() {
        return Err(FfiError::InvalidInput(
            "key_authorization: trailing bytes in list".into(),
        ));
    }
    let signature = Signature::try_from(signature_bytes.as_ref())
        .map_err(|_| FfiError::InvalidInput("key_authorization: signature not 65 bytes".into()))?;
    Ok(authorization.into_signed(PrimitiveSignature::Secp256k1(signature)))
}

fn decode_optional_key_authorization(
    bytes: Option<Vec<u8>>,
) -> Result<Option<SignedKeyAuthorization>, FfiError> {
    match bytes {
        Some(bytes) => Ok(Some(decode_key_authorization(bytes)?)),
        None => Ok(None),
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

/// UniFFI entry point: build + sign + RLP-encode a subscription-charge `0x76` tx (one
/// `transferWithMemo` call). `amount` is a decimal `u256` string; `currency` / `recipient`
/// are 20-byte addresses; `private_key` (the access key signing the tx) and `memo` are 32
/// bytes; `key_authorization` is the serialized signed authorization on the provisioning
/// charge, or `None` once the access key is provisioned.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_subscription_charge_transaction(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    gas_limit: u64,
    fee_token: Option<Vec<u8>>,
    private_key: Vec<u8>,
    root_address: Vec<u8>,
    currency: Vec<u8>,
    recipient: Vec<u8>,
    amount: String,
    memo: Vec<u8>,
    key_authorization: Option<Vec<u8>>,
    fee_payer_private_key: Option<Vec<u8>>,
) -> Result<Vec<u8>, FfiError> {
    let key = take_key(private_key)?;
    let authorization = decode_optional_key_authorization(key_authorization)?;
    // The optional sponsor key: when present, gas is paid by the fee payer (not drawn from the
    // access key's spending limit). Kept in its `Zeroizing` wrapper (like `key`) so the bytes are
    // wiped when this frame returns; only a Copy is handed down (and wiped there too).
    let fee_payer = match fee_payer_private_key {
        Some(bytes) => Some(take_key(bytes)?),
        None => None,
    };
    build_subscription_charge_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        parse_optional_address("fee_token", fee_token)?,
        *key,
        parse_address("root_address", &root_address)?,
        parse_address("currency", &currency)?,
        parse_address("recipient", &recipient)?,
        parse_u256("amount", &amount)?,
        parse_bytes32("memo", memo)?,
        authorization,
        fee_payer.as_deref().copied(),
    )
    .map_err(map_build_error)
}

/// UniFFI entry point: build + sign + RLP-encode a one-time settled-charge `0x76` tx (one
/// `transferWithMemo` call, signed directly by the payer). `amount` is a decimal `u256` string;
/// `currency` / `recipient` are 20-byte addresses; `private_key` (the payer) and `memo` are 32
/// bytes; `fee_token` is the optional 20-byte gas token.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_transfer_transaction(
    chain_id: u64,
    nonce: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    gas_limit: u64,
    fee_token: Option<Vec<u8>>,
    private_key: Vec<u8>,
    currency: Vec<u8>,
    recipient: Vec<u8>,
    amount: String,
    memo: Vec<u8>,
) -> Result<Vec<u8>, FfiError> {
    let key = take_key(private_key)?;
    build_transfer_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        parse_optional_address("fee_token", fee_token)?,
        *key,
        parse_address("currency", &currency)?,
        parse_address("recipient", &recipient)?,
        parse_u256("amount", &amount)?,
        parse_bytes32("memo", memo)?,
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
            42431,
            7,
            "1".into(),
            "1".into(),
            1,
            None,
            vec![0x11; 31],
            vec![0x55; 20],
            vec![0xAB; 32],
            "1".into(),
            vec![0u8; 65],
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
            [0xAB; 32],                // salt
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
        alloy_primitives::keccak256(signature)[..4]
            .try_into()
            .expect("4 bytes")
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
            42431,
            7,
            "1000000000".into(),
            "1000000".into(),
            100_000,
            None,
            vec![0x11; 32],
            vec![0x55; 20],
            vec![0x22; 20],
            vec![0x33; 20],
            "1000".into(),
            vec![0xAB; 32],
            vec![0x44; 20],
        )
        .expect("build open");
        assert_eq!(
            open.iter().map(|b| format!("{b:02x}")).collect::<String>(),
            GOLDEN_OPEN_TX
        );

        let top_up = build_top_up_transaction(
            42431,
            7,
            "1000000000".into(),
            "1000000".into(),
            100_000,
            None,
            vec![0x11; 32],
            vec![0x55; 20],
            vec![0x22; 20],
            vec![0xAB; 32],
            "1000".into(),
        )
        .expect("build topUp");
        assert_eq!(
            top_up
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
            GOLDEN_TOP_UP_TX
        );
    }

    const GOLDEN_CLOSE_TX: &str = "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555555555555580b8e40d65c51dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0800780808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c";

    const GOLDEN_OPEN_TX: &str = "76f9017a82a5bf830f4240843b9aca00830186a0f9011cf85c94222222222222222222222222222222222222222280b844095ea7b3000000000000000000000000555555555555555555555555555555555555555500000000000000000000000000000000000000000000000000000000000003e8f8bc94555555555555555555555555555555555555555580b8a4c79ea4850000000000000000000000003333333333333333333333333333333333333333000000000000000000000000222222222222222222222222222222222222222200000000000000000000000000000000000000000000000000000000000003e8abababababababababababababababababababababababababababababababab0000000000000000000000004444444444444444444444444444444444444444c0800780808080c0b841de9fb016ce44ed02dca54f29b1ebabe7a64a1a6ac99e83a58cc1adb6cee88d887406777d5e7e3347d60866e9569ae234a3faa625ee643ef6986d7115ec1deb591b";

    const GOLDEN_TOP_UP_TX: &str = "76f9011982a5bf830f4240843b9aca00830186a0f8bcf85c94222222222222222222222222222222222222222280b844095ea7b3000000000000000000000000555555555555555555555555555555555555555500000000000000000000000000000000000000000000000000000000000003e8f85c94555555555555555555555555555555555555555580b844b67644b9abababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e8c0800780808080c0b841614b14a310bd2d62e898ea879e38c84dbd59b869209c51dd4c261b2eddce322439e6f11f9a4b5678909d4ab9bf29e8052abcb7ab9f6c4518e6455ec5d0ae43241b";

    // --- KeyAuthorization differential check vs the chain (tempo-primitives 1.8.0) ---
    // The MPP-swift pure-Swift KeyAuthorization encoder must be byte-identical to the chain's own
    // RLP, and the chain must round-trip MPP-swift's canonical bytes. This is the authoritative peer
    // validation for the subscription key authorization: the chain's alloy-strict codec is the
    // oracle, so we never approximate canonicality by hand. INNER_TUPLE is the
    // RLP([chainId, keyType, keyId, expiry, limits, calls]) that MPP-swift hashes for the sign
    // payload (its `TempoKeyAuthorizationTests.innerTuple`); the chain's KeyAuthorization RLP is
    // exactly this tuple (the signature is carried separately on-chain, not inside it), and the
    // trailing `witness` field is canonically omitted when absent.
    const INNER_TUPLE: &str = "f87182a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880dedd9420c0000000000000000000000000000000000001830f424083093a80f3f29420c0000000000000000000000000000000000001dcdb8495777d59d5941111111111111111111111111111111111111111";

    fn mpp_swift_golden_key_authorization(
    ) -> tempo_primitives::transaction::key_authorization::KeyAuthorization {
        use alloy_primitives::{address, U256};
        use std::num::NonZeroU64;
        use tempo_primitives::transaction::key_authorization::{
            CallScope, KeyAuthorization, SelectorRule, TokenLimit,
        };
        use tempo_primitives::SignatureType;
        let token = address!("20c0000000000000000000000000000000000001");
        KeyAuthorization {
            chain_id: 42431,
            key_type: SignatureType::Secp256k1,
            key_id: address!("be95c3f554e9fc85ec51be69a3d807a0d55bcf2c"),
            expiry: NonZeroU64::new(1_893_456_000),
            limits: Some(vec![TokenLimit {
                token,
                limit: U256::from(1_000_000u64),
                period: 604_800,
            }]),
            allowed_calls: Some(vec![CallScope {
                target: token,
                selector_rules: vec![SelectorRule {
                    selector: [0x95, 0x77, 0x7d, 0x59],
                    recipients: vec![address!("1111111111111111111111111111111111111111")],
                }],
            }]),
            witness: None,
            is_admin: false,
            account: None,
        }
    }

    /// The chain's RLP of the key authorization is byte-identical to MPP-swift's inner tuple, so
    /// keccak256 of it is the same sign payload both sides compute.
    #[test]
    fn key_authorization_encoding_matches_mpp_swift() {
        use alloy_rlp::Encodable;
        let mut buf = Vec::new();
        mpp_swift_golden_key_authorization().encode(&mut buf);
        let hex: String = buf.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, INNER_TUPLE);
    }

    /// The chain's strict decoder accepts MPP-swift's canonical bytes and recovers the same fields.
    #[test]
    fn chain_round_trips_mpp_swift_canonical_bytes() {
        use alloy_rlp::Decodable;
        use tempo_primitives::transaction::key_authorization::KeyAuthorization;
        let bytes = alloy_primitives::hex::decode(INNER_TUPLE).expect("hex");
        let decoded =
            KeyAuthorization::decode(&mut bytes.as_slice()).expect("chain decodes our bytes");
        assert_eq!(decoded, mpp_swift_golden_key_authorization());
    }

    // --- Subscription charge tx (PR-1) ---------------------------------------------
    // Peer-pinned: the exact serialized signed key authorization the reference serializer
    // (ox `KeyAuthorization.serialize`, which mppx uses) emits for the golden authorization
    // signed by root key 0x..01. Its inner tuple is byte-identical to INNER_TUPLE; the
    // trailing b841.. is the 65-byte r‖s‖v signature. Generated via ox/tempo, the same
    // path mppx's subscription credential takes. The recovered signer is account #1's
    // canonical address.
    const PEER_GOLDEN_SIGNED_AUTH: &str = "f8b6f87182a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880dedd9420c0000000000000000000000000000000000001830f424083093a80f3f29420c0000000000000000000000000000000000001dcdb8495777d59d5941111111111111111111111111111111111111111b8412f8b4dba4eea0baaf11a6e6c75ddf3ac45e3884a189f8e0378237693c27caad82401fa516b307698e0c1ddb295b7b919f442dc68658b7357f3d70e2bd51f51d81c";

    /// The FFI decodes the reference serializer's exact wire bytes back into the same
    /// authorization our Swift encoder produces, and recovers the root (payer) that signed
    /// it. This pins the signed-wrapper wire compatibility the offline conformance did not
    /// exercise (it compared the inner tuple only).
    #[test]
    fn peer_golden_signed_authorization_decodes_and_recovers_root() {
        use alloy_primitives::address;
        let bytes = alloy_primitives::hex::decode(PEER_GOLDEN_SIGNED_AUTH).expect("hex");
        let signed = decode_key_authorization(bytes).expect("decodes the peer wire form");
        // SignedKeyAuthorization derefs to its KeyAuthorization.
        assert_eq!(*signed, mpp_swift_golden_key_authorization());
        let root = signed.recover_signer().expect("recovers the signer");
        assert_eq!(root, address!("7e5f4552091a69125d5dfcb7b8c2659029395bdf"));
    }

    /// A stray byte after a well-formed authorization list is rejected: inner decoding is
    /// bound to the list's declared payload, so trailing bytes do not pass silently.
    #[test]
    fn decode_rejects_trailing_bytes_after_the_authorization() {
        let mut bytes = alloy_primitives::hex::decode(PEER_GOLDEN_SIGNED_AUTH).expect("hex");
        bytes.push(0x00);
        assert!(decode_key_authorization(bytes).is_err());
    }

    /// The provisioning charge attaches the key authorization (bytes grow, content differs);
    /// both with and without are 0x76-typed Tempo transactions.
    #[test]
    fn subscription_charge_attaches_key_authorization() {
        use alloy_primitives::{address, U256};
        let access_key = [0x02u8; 32];
        let root = address!("7e5f4552091a69125d5dfcb7b8c2659029395bdf");
        let currency = address!("20c0000000000000000000000000000000000001");
        let recipient = address!("1111111111111111111111111111111111111111");
        let memo = [0xabu8; 32];
        // The same fixed inputs as the Swift test (FFISubscriptionChargeTxBuilderTests).
        let build = |auth: Option<SignedKeyAuthorization>| {
            build_subscription_charge_tx(
                42431,
                7,
                1_000_000_000,
                1_000_000,
                100_000,
                None,
                access_key,
                root,
                currency,
                recipient,
                U256::from(1_000_000u64),
                memo,
                auth,
                None,
            )
            .expect("builds")
        };
        let auth = decode_key_authorization(
            alloy_primitives::hex::decode(PEER_GOLDEN_SIGNED_AUTH).unwrap(),
        )
        .unwrap();
        let with_auth = build(Some(auth));
        let without_auth = build(None);
        assert_ne!(with_auth, without_auth);
        assert!(with_auth.len() > without_auth.len());
        assert_eq!(with_auth[0], 0x76);
        // Byte-exact golden for the no-auth charge (the regression net the other builders
        // have; the Swift test pins the identical bytes for cross-language equivalence).
        let hex: String = without_auth.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_SUBSCRIPTION_CHARGE_TX);
    }

    const GOLDEN_SUBSCRIPTION_CHARGE_TX: &str = "76f8f082a5bf830f4240843b9aca00830186a0f87ef87c9420c000000000000000000000000000000000000180b86495777d59000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000f4240ababababababababababababababababababababababababababababababababc0800780808080c0b856047e5f4552091a69125d5dfcb7b8c2659029395bdf34b62d4b8e525ea50f6941cd3e0b13750c90eb7098290614fe734921ead18c4c471151d237efd57add8ead8e52534aa2f968307173523013f281b0236d3056e81b";

    /// The one-time settled charge (`draft-tempo-charge-00`): a payer-signed `transferWithMemo`.
    /// Same call and inputs as the subscription charge, but signed DIRECTLY by the payer (no
    /// keychain), so the bytes differ from the access-key-signed subscription charge, and the tx is
    /// shorter (a plain signature, not a V2 keychain signature carrying the root address). Byte-
    /// golden as the regression net (k256 RFC-6979 is deterministic); the live-Moderato e2e is the
    /// authoritative on-chain check.
    #[test]
    fn settled_charge_is_a_plain_payer_signed_transfer() {
        use alloy_primitives::{address, U256};
        let payer = [0x01u8; 32]; // account #0 -> 0x7e5f...5bdf
        let currency = address!("20c0000000000000000000000000000000000001");
        let recipient = address!("1111111111111111111111111111111111111111");
        let memo = [0xabu8; 32];
        let transfer = build_transfer_tx(
            42431,
            7,
            1_000_000_000,
            1_000_000,
            100_000,
            None,
            payer,
            currency,
            recipient,
            U256::from(1_000_000u64),
            memo,
        )
        .expect("builds");
        assert_eq!(transfer[0], 0x76, "a Tempo 0x76 typed transaction");

        // The same call signed by an access key (keychain V2) for the payer-as-root is a different,
        // longer transaction: the plain payer signature here carries no root address.
        let subscription = build_subscription_charge_tx(
            42431,
            7,
            1_000_000_000,
            1_000_000,
            100_000,
            None,
            [0x02u8; 32],
            address!("7e5f4552091a69125d5dfcb7b8c2659029395bdf"),
            currency,
            recipient,
            U256::from(1_000_000u64),
            memo,
            None,
            None,
        )
        .expect("builds");
        assert_ne!(transfer, subscription);
        assert!(transfer.len() < subscription.len());

        let hex: String = transfer.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_SETTLED_CHARGE_TX);
    }

    const GOLDEN_SETTLED_CHARGE_TX: &str = "76f8db82a5bf830f4240843b9aca00830186a0f87ef87c9420c000000000000000000000000000000000000180b86495777d59000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000f4240ababababababababababababababababababababababababababababababababc0800780808080c0b841d7b99f66aef71299b88eafbde28f651fff83f108f2991e33f7b0df70d4e6b70840330de8ed936d7def1a41d93e67da4a194b0d59170ed49763c6a91e2c7501971c";

    /// The sponsored provisioning charge: a gas sponsor (`fee_payer`) signs the fee-payer
    /// signature so the access key's per-period spending limit only has to cover the transfer
    /// (the chain meters gas in the fee token and would otherwise draw it from that limit). Locks
    /// the exact sponsored bytes, and asserts the sponsor signature actually changes the output vs
    /// the unsponsored charge. The live-Moderato e2e is the authoritative on-chain check; this
    /// catches byte-level regressions (e.g. a dep bump) without network access.
    #[test]
    fn sponsored_subscription_charge_golden() {
        use alloy_primitives::{address, U256};
        let access_key = [0x02u8; 32];
        let fee_payer = [0x03u8; 32];
        let root = address!("7e5f4552091a69125d5dfcb7b8c2659029395bdf");
        let currency = address!("20c0000000000000000000000000000000000001");
        let recipient = address!("1111111111111111111111111111111111111111");
        let memo = [0xabu8; 32];
        // Same fixed inputs as subscription_charge_attaches_key_authorization, plus the sponsor.
        let build = |fee_payer: Option<[u8; 32]>| {
            let auth = decode_key_authorization(
                alloy_primitives::hex::decode(PEER_GOLDEN_SIGNED_AUTH).unwrap(),
            )
            .unwrap();
            build_subscription_charge_tx(
                42431,
                7,
                1_000_000_000,
                1_000_000,
                100_000,
                None,
                access_key,
                root,
                currency,
                recipient,
                U256::from(1_000_000u64),
                memo,
                Some(auth),
                fee_payer,
            )
            .expect("builds")
        };
        let sponsored = build(Some(fee_payer));
        let unsponsored = build(None);
        // The fee-payer signature is present, so the sponsored encoding differs and is longer.
        assert_ne!(sponsored, unsponsored);
        assert!(sponsored.len() > unsponsored.len());
        assert_eq!(sponsored[0], 0x76);
        let hex: String = sponsored.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, GOLDEN_SPONSORED_SUBSCRIPTION_CHARGE_TX);
    }

    const GOLDEN_SPONSORED_SUBSCRIPTION_CHARGE_TX: &str = "76f901ec82a5bf830f4240843b9aca00830186a0f87ef87c9420c000000000000000000000000000000000000180b86495777d59000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000f4240ababababababababababababababababababababababababababababababababc08007808080f84380a0495dd4c63e0d09a6764fa341ee85e0385d6430d9901f66b70a157967fed370aba07e3f01871f0693c9359df444110e27f44f28145c64f4a1358a8a6e626956bba0c0f8b6f87182a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880dedd9420c0000000000000000000000000000000000001830f424083093a80f3f29420c0000000000000000000000000000000000001dcdb8495777d59d5941111111111111111111111111111111111111111b8412f8b4dba4eea0baaf11a6e6c75ddf3ac45e3884a189f8e0378237693c27caad82401fa516b307698e0c1ddb295b7b919f442dc68658b7357f3d70e2bd51f51d81cb856047e5f4552091a69125d5dfcb7b8c2659029395bdfae31c1f2df41562bb968e1e5b648a530f6add36135862a27f6923478bb2955674a7c130786786b5ab253fbfcc3cec8fb931029b2db9b44924ff7e1ce4c1d3d7d1b";
}
