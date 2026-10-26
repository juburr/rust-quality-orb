//! Shapes, as changed since the baseline: square_perimeter is gone, which a
//! patch release (0.1.0 to 0.1.1) doesn't allow.

/// The area of a square with sides of `side`.
pub fn square_area(side: u32) -> u32 {
    side * side
}
