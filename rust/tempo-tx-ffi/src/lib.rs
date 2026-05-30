//! Builds + signs + RLP-encodes the Tempo `0x76` escrow transactions the Swift SDK
//! broadcasts (the one operation Swift cannot do natively). It binds Tempo's own
//! `tempo-primitives` crate so the format stays byte-identical to the chain's
//! canonical implementation, with no hand-rolled transaction encoding.
//!
//! Only the escrow `close` (settlement) tx is built here for now; `open` / `topUp`
//! and the UniFFI + xcframework wiring follow in later slices. The functions are
//! plain Rust today; the UniFFI-friendly surface (bytes/strings, not `Address`)
//! arrives with the bindings.

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

    const GOLDEN_CLOSE_TX: &str = "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555555555555580b8e40d65c51dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0800780808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c";
}
