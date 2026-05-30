// Binding generator entry point: `cargo run --bin uniffi-bindgen -- generate ...`.
// Kept in-crate so binding generation uses the exact uniffi version we depend on.
fn main() {
    uniffi::uniffi_bindgen_main()
}
