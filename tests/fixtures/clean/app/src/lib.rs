//! A crate every rust-quality-orb check passes: formatted, without lints,
//! documented, tested, and building with every feature combination on its
//! declared rust-version.

/// Greets `name`, more loudly with the `loud` feature.
///
/// ```
/// assert!(app::greet("Ferris").contains("Ferris"));
/// ```
pub fn greet(name: &str) -> String {
    let greeting = helper::greeting(name);
    if cfg!(feature = "loud") {
        greeting.to_uppercase()
    } else {
        greeting
    }
}

#[cfg(test)]
mod tests {
    use super::greet;

    #[test]
    fn greets_by_name() {
        assert!(greet("Ferris").contains("Ferris"));
    }
}
