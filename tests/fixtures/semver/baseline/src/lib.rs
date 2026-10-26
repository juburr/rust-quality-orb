//! Shapes, as released: the baseline semver_checks compares with.

/// The area of a square with sides of `side`.
pub fn square_area(side: u32) -> u32 {
    side * side
}

/// The perimeter of a square with sides of `side`.
pub fn square_perimeter(side: u32) -> u32 {
    4 * side
}
