//! A crate in which every rust-quality-orb check finds something.

use std::sync::LazyLock;

mod format;

/// The answer, computed once. Rust 1.80 stabilized LazyLock, so this
/// doesn't build on the rust-version Cargo.toml declares.
pub static ANSWER: LazyLock<u32> = LazyLock::new(|| 42);

/// Doubles `n`. See [`Tripler`], which doesn't exist: a broken intra-doc link.
pub fn double(n: u32) -> u32 {
    return n * 2;
}

/// The formatted number.
pub fn formatted(n: u32) -> String {
    format::number(n)
}

#[cfg(feature = "fast")]
fn speed() -> &'static str {
    "fast"
}

/// What the extra feature adds, which needs speed() from fast.
#[cfg(feature = "extra")]
pub fn extra() -> &'static str {
    speed()
}
