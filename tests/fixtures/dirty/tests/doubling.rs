#[test]
fn doubles() {
    assert_eq!(dirty::double(2), 4);
}

#[test]
fn doubles_wrongly() {
    assert_eq!(dirty::double(2), 5, "a test that fails");
}
