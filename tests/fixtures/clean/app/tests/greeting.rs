#[test]
fn greeting_ends_with_an_exclamation_mark() {
    assert!(app::greet("Ferris").ends_with('!'));
}
