//! Builds + signs + RLP-encodes the Tempo `0x76` escrow transactions the Swift SDK
//! broadcasts. Swift could encode this, but the format is Tempo-specific and
//! evolving, so binding Tempo's own `tempo-primitives` crate keeps the output
//! byte-identical to the chain's canonical implementation and makes an upgrade a
//! version bump rather than a hand-maintained Swift port. No hand-rolled encoding.
//!
//! Only the escrow `close` (settlement) tx is built for now; `open` / `topUp` follow.
//! Two surfaces: the typed Rust `build_close_tx` (used by the in-crate tests), and
//! the UniFFI-exported `build_close_transaction` (FFI-friendly types: scalars,
//! `Vec<u8>`, and decimal `String`s for `u128`) that the Swift wrapper calls. The
//! xcframework / Linux `.so` packaging + the SwiftPM wiring follow in the next slice.

use alloy_primitives::{Address, Bytes, FixedBytes, Signature, TxKind, U256};
use alloy_sol_types::{sol, SolCall};
use k256::ecdsa::SigningKey;
use tempo_primitives::transaction::Call;
use tempo_primitives::{TempoSignature, TempoTransaction};
use zeroize::Zeroize;

sol! {
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

/// Builds the signed `0x76` transaction that calls `escrow.close(channelId,
/// cumulativeAmount, voucherSignature)`, returning the raw EIP-2718 bytes ready to
/// broadcast via `eth_sendRawTransaction`. `voucher_signature` is the payer/
/// authorized-signer signature the escrow recovers (`ecrecover`); `private_key` is
/// the sender's key (it pays gas). The fee/nonce inputs come from the caller (the
/// Swift side reads them over JSON-RPC).
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
    let calldata = closeCall {
        channelId: FixedBytes::<32>::from(channel_id),
        cumulativeAmount: cumulative_amount,
        signature: Bytes::from(voucher_signature),
    }
    .abi_encode();

    let tx = TempoTransaction {
        chain_id,
        fee_token,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        calls: vec![Call {
            to: TxKind::Call(escrow),
            value: U256::ZERO,
            input: Bytes::from(calldata),
        }],
        nonce_key: U256::ZERO, // 0 = the protocol (sequential) nonce
        nonce,
        ..Default::default()
    };

    let hash = tx.signature_hash();
    // Build the key, then zeroize our copy of the raw bytes immediately (on both the
    // ok and error paths). The k256 SigningKey itself is zeroize-on-drop.
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

fn parse_address(label: &str, bytes: &[u8]) -> Result<Address, FfiError> {
    if bytes.len() != 20 {
        return Err(FfiError::InvalidInput(format!("{label}: need 20 bytes")));
    }
    Ok(Address::from_slice(bytes))
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
    let key: [u8; 32] = private_key
        .try_into()
        .map_err(|_| FfiError::InvalidInput("private_key: need 32 bytes".into()))?;
    let channel: [u8; 32] = channel_id
        .try_into()
        .map_err(|_| FfiError::InvalidInput("channel_id: need 32 bytes".into()))?;
    let fee_token = match fee_token {
        Some(bytes) => Some(parse_address("fee_token", &bytes)?),
        None => None,
    };
    build_close_tx(
        chain_id,
        nonce,
        parse_u128("max_fee_per_gas", &max_fee_per_gas)?,
        parse_u128("max_priority_fee_per_gas", &max_priority_fee_per_gas)?,
        gas_limit,
        fee_token,
        key,
        parse_address("escrow", &escrow)?,
        channel,
        parse_u128("cumulative_amount", &cumulative_amount)?,
        voucher_signature,
    )
    .map_err(|error| match error {
        BuildError::InvalidKey => FfiError::InvalidKey,
        BuildError::SigningFailed => FfiError::SigningFailed,
    })
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

    const GOLDEN_CLOSE_TX: &str = "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555555555555580b8e40d65c51dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0800780808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c";
}
