//! Exact geometric predicates using adaptive-precision arithmetic.
//!
//! This module provides robust geometric predicates based on Shewchuk's
//! algorithms. These predicates use adaptive precision: fast when possible,
//! exact when needed. They eliminate the need for epsilon-based tolerance
//! tuning that doesn't scale with geometry size.
//!
//! # Primary Predicates
//!
//! - [`orient2d`]: Determines which side of a line a point lies on (2D)
//! - [`orient3d`]: Determines which side of a plane a point lies on (3D)
//! - [`incircle`]: Determines if a point is inside/outside a circle (2D)
//! - [`insphere`]: Determines if a point is inside/outside a sphere (3D)
//!
//! # Derived Predicates
//!
//! - [`point_on_segment_2d`]: Test if a point lies on a line segment
//! - [`point_on_plane`]: Test if a point lies on a plane defined by three points

use crate::{Point2, Point3};

/// The sign of a geometric predicate result.
///
/// For orientation predicates:
/// - `Positive`: Counter-clockwise (2D) or above plane (3D)
/// - `Zero`: Collinear (2D) or coplanar (3D)
/// - `Negative`: Clockwise (2D) or below plane (3D)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Sign {
    /// Strictly negative value
    Negative,
    /// Exactly zero
    Zero,
    /// Strictly positive value
    Positive,
}

impl Sign {
    /// Create a Sign from an f64 value.
    ///
    /// Note: This should only be used with results from exact predicates,
    /// not with raw floating-point computations.
    #[inline]
    pub fn from_f64(v: f64) -> Self {
        if v > 0.0 {
            Sign::Positive
        } else if v < 0.0 {
            Sign::Negative
        } else {
            Sign::Zero
        }
    }

    /// Returns true if the sign is positive.
    #[inline]
    pub fn is_positive(self) -> bool {
        matches!(self, Sign::Positive)
    }

    /// Returns true if the sign is negative.
    #[inline]
    pub fn is_negative(self) -> bool {
        matches!(self, Sign::Negative)
    }

    /// Returns true if the sign is zero.
    #[inline]
    pub fn is_zero(self) -> bool {
        matches!(self, Sign::Zero)
    }
}

// =============================================================================
// 2D Predicates
// =============================================================================

/// Determine the orientation of point `c` relative to the directed line from `a` to `b`.
///
/// Returns:
/// - `Positive`: `c` is to the left of the line (counter-clockwise)
/// - `Zero`: `c` is on the line (collinear with `a` and `b`)
/// - `Negative`: `c` is to the right of the line (clockwise)
///
/// This is equivalent to the sign of the 2D cross product `(b - a) × (c - a)`.
///
/// # Example
///
/// ```
/// use vcad_kernel_math::{Point2, predicates::{orient2d, Sign}};
///
/// let a = Point2::new(0.0, 0.0);
/// let b = Point2::new(1.0, 0.0);
/// let c = Point2::new(0.5, 1.0);
///
/// assert_eq!(orient2d(&a, &b, &c), Sign::Positive); // c is above the line
/// ```
#[inline]
pub fn orient2d(a: &Point2, b: &Point2, c: &Point2) -> Sign {
    let result = robust::orient2d(
        robust::Coord { x: a.x, y: a.y },
        robust::Coord { x: b.x, y: b.y },
        robust::Coord { x: c.x, y: c.y },
    );
    Sign::from_f64(result)
}

/// Determine if point `d` is inside, on, or outside the circumcircle of triangle `abc`.
///
/// The triangle `abc` must be oriented counter-clockwise. If `abc` is clockwise,
/// the result is negated.
///
/// Returns:
/// - `Positive`: `d` is inside the circumcircle
/// - `Zero`: `d` is on the circumcircle
/// - `Negative`: `d` is outside the circumcircle
///
/// # Example
///
/// ```
/// use vcad_kernel_math::{Point2, predicates::{incircle, Sign}};
///
/// let a = Point2::new(0.0, 0.0);
/// let b = Point2::new(1.0, 0.0);
/// let c = Point2::new(0.5, 0.866); // approximately equilateral
/// let d = Point2::new(0.5, 0.3);   // inside the circle
///
/// assert_eq!(incircle(&a, &b, &c, &d), Sign::Positive);
/// ```
#[inline]
pub fn incircle(a: &Point2, b: &Point2, c: &Point2, d: &Point2) -> Sign {
    let result = robust::incircle(
        robust::Coord { x: a.x, y: a.y },
        robust::Coord { x: b.x, y: b.y },
        robust::Coord { x: c.x, y: c.y },
        robust::Coord { x: d.x, y: d.y },
    );
    Sign::from_f64(result)
}

// =============================================================================
// 3D Predicates
// =============================================================================

/// Determine the orientation of point `d` relative to the plane through `a`, `b`, `c`.
///
/// Returns the sign of the determinant:
/// ```text
/// | ax-dx  ay-dy  az-dz |
/// | bx-dx  by-dy  bz-dz |
/// | cx-dx  cy-dy  cz-dz |
/// ```
///
/// Interpretation:
/// - `Positive`: `d` is below the plane (when `a`, `b`, `c` appear counter-clockwise
///   viewed from above)
/// - `Zero`: `d` is on the plane (coplanar with `a`, `b`, `c`)
/// - `Negative`: `d` is above the plane
///
/// Note: "above" and "below" are relative to the plane's orientation defined by
/// the right-hand rule applied to the counter-clockwise vertex ordering.
///
/// # Example
///
/// ```
/// use vcad_kernel_math::{Point3, predicates::{orient3d, Sign}};
///
/// // Triangle in XY plane with vertices going counter-clockwise when viewed from +Z
/// let a = Point3::new(0.0, 0.0, 0.0);
/// let b = Point3::new(1.0, 0.0, 0.0);
/// let c = Point3::new(0.0, 1.0, 0.0);
/// let d = Point3::new(0.0, 0.0, 1.0);
///
/// // d is at +Z, which is "above" the plane, so orient3d returns Negative
/// assert_eq!(orient3d(&a, &b, &c, &d), Sign::Negative);
/// ```
#[inline]
pub fn orient3d(a: &Point3, b: &Point3, c: &Point3, d: &Point3) -> Sign {
    let result = robust::orient3d(
        robust::Coord3D {
            x: a.x,
            y: a.y,
            z: a.z,
        },
        robust::Coord3D {
            x: b.x,
            y: b.y,
            z: b.z,
        },
        robust::Coord3D {
            x: c.x,
            y: c.y,
            z: c.z,
        },
        robust::Coord3D {
            x: d.x,
            y: d.y,
            z: d.z,
        },
    );
    Sign::from_f64(result)
}

/// Determine if point `e` is inside, on, or outside the circumsphere of tetrahedron `abcd`.
///
/// The tetrahedron `abcd` must be positively oriented (orient3d(a,b,c,d) > 0).
/// If negatively oriented, the result is negated.
///
/// Returns:
/// - `Positive`: `e` is inside the circumsphere
/// - `Zero`: `e` is on the circumsphere
/// - `Negative`: `e` is outside the circumsphere
#[inline]
pub fn insphere(a: &Point3, b: &Point3, c: &Point3, d: &Point3, e: &Point3) -> Sign {
    let result = robust::insphere(
        robust::Coord3D {
            x: a.x,
            y: a.y,
            z: a.z,
        },
        robust::Coord3D {
            x: b.x,
            y: b.y,
            z: b.z,
        },
        robust::Coord3D {
            x: c.x,
            y: c.y,
            z: c.z,
        },
        robust::Coord3D {
            x: d.x,
            y: d.y,
            z: d.z,
        },
        robust::Coord3D {
            x: e.x,
            y: e.y,
            z: e.z,
        },
    );
    Sign::from_f64(result)
}

// =============================================================================
// Derived Predicates
// =============================================================================

/// Test if point `p` lies on the line segment from `a` to `b`.
///
/// Returns true if `p` is collinear with `a` and `b`, and lies between them
/// (inclusive of endpoints).
///
/// # Example
///
/// ```
/// use vcad_kernel_math::{Point2, predicates::point_on_segment_2d};
///
/// let a = Point2::new(0.0, 0.0);
/// let b = Point2::new(2.0, 0.0);
/// let p = Point2::new(1.0, 0.0);
///
/// assert!(point_on_segment_2d(&p, &a, &b)); // p is on the segment
/// ```
pub fn point_on_segment_2d(p: &Point2, a: &Point2, b: &Point2) -> bool {
    // First check collinearity using exact predicate
    if !orient2d(a, b, p).is_zero() {
        return false;
    }

    // Now we know p is collinear with a and b.
    // Check if p is between a and b by checking that dot products have correct signs.
    // p is on segment if (p - a) · (b - a) >= 0 and (p - b) · (a - b) >= 0
    //
    // Since we already know collinearity, we can use a simpler bounding box check:
    // p is on segment if its coords are within the bbox of a and b.
    let min_x = a.x.min(b.x);
    let max_x = a.x.max(b.x);
    let min_y = a.y.min(b.y);
    let max_y = a.y.max(b.y);

    p.x >= min_x && p.x <= max_x && p.y >= min_y && p.y <= max_y
}

/// Test if point `p` lies on the plane defined by points `a`, `b`, and `c`.
///
/// Returns true if `p` is coplanar with the triangle `abc`.
///
/// # Example
///
/// ```
/// use vcad_kernel_math::{Point3, predicates::point_on_plane};
///
/// let a = Point3::new(0.0, 0.0, 0.0);
/// let b = Point3::new(1.0, 0.0, 0.0);
/// let c = Point3::new(0.0, 1.0, 0.0);
/// let p = Point3::new(0.5, 0.5, 0.0);
///
/// assert!(point_on_plane(&p, &a, &b, &c)); // p is on the XY plane
/// ```
#[inline]
pub fn point_on_plane(p: &Point3, a: &Point3, b: &Point3, c: &Point3) -> bool {
    orient3d(a, b, c, p).is_zero()
}

/// Test if four points are coplanar.
///
/// Returns true if points `a`, `b`, `c`, and `d` all lie on the same plane.
#[inline]
pub fn are_coplanar(a: &Point3, b: &Point3, c: &Point3, d: &Point3) -> bool {
    orient3d(a, b, c, d).is_zero()
}

/// Test if three 2D points are collinear.
///
/// Returns true if points `a`, `b`, and `c` all lie on the same line.
#[inline]
pub fn are_collinear_2d(a: &Point2, b: &Point2, c: &Point2) -> bool {
    orient2d(a, b, c).is_zero()
}

/// Determine which side of a line segment a point is on, with segment endpoint handling.
///
/// This is useful for ray casting algorithms. Returns:
/// - `Some(Sign::Positive)`: point is strictly left of the line
/// - `Some(Sign::Negative)`: point is strictly right of the line
/// - `None`: point is on the line (collinear)
#[inline]
pub fn point_side_of_line(p: &Point2, a: &Point2, b: &Point2) -> Option<Sign> {
    let sign = orient2d(a, b, p);
    if sign.is_zero() {
        None
    } else {
        Some(sign)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ==========================================================================
    // orient2d tests
    // ==========================================================================

    #[test]
    fn test_orient2d_ccw() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 0.0);
        let c = Point2::new(0.5, 1.0);
        assert_eq!(orient2d(&a, &b, &c), Sign::Positive);
    }

    #[test]
    fn test_orient2d_cw() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 0.0);
        let c = Point2::new(0.5, -1.0);
        assert_eq!(orient2d(&a, &b, &c), Sign::Negative);
    }

    #[test]
    fn test_orient2d_collinear() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(2.0, 0.0);
        let c = Point2::new(1.0, 0.0);
        assert_eq!(orient2d(&a, &b, &c), Sign::Zero);
    }

    #[test]
    fn test_orient2d_near_collinear() {
        // Points that are very close to collinear but not exactly
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 0.0);
        let c = Point2::new(0.5, 1e-15);
        // The exact predicate should detect this tiny offset
        assert_eq!(orient2d(&a, &b, &c), Sign::Positive);
    }

    // ==========================================================================
    // orient3d tests
    // ==========================================================================

    #[test]
    fn test_orient3d_above_plane() {
        // Triangle in XY plane, CCW when viewed from +Z
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let d = Point3::new(0.0, 0.0, 1.0);
        // d is at +Z (above the plane), so orient3d returns Negative
        assert_eq!(orient3d(&a, &b, &c, &d), Sign::Negative);
    }

    #[test]
    fn test_orient3d_below_plane() {
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let d = Point3::new(0.0, 0.0, -1.0);
        // d is at -Z (below the plane), so orient3d returns Positive
        assert_eq!(orient3d(&a, &b, &c, &d), Sign::Positive);
    }

    #[test]
    fn test_orient3d_coplanar() {
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let d = Point3::new(0.5, 0.5, 0.0);
        assert_eq!(orient3d(&a, &b, &c, &d), Sign::Zero);
    }

    #[test]
    fn test_orient3d_near_coplanar() {
        // Point very slightly above the XY plane
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let d = Point3::new(0.5, 0.5, 1e-15);
        // The exact predicate should detect this tiny offset
        // d is slightly above, so orient3d returns Negative
        assert_eq!(orient3d(&a, &b, &c, &d), Sign::Negative);
    }

    // ==========================================================================
    // incircle tests
    // ==========================================================================

    #[test]
    fn test_incircle_inside() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 0.0);
        let c = Point2::new(0.5, 0.866025403784); // equilateral triangle
        let d = Point2::new(0.5, 0.3);
        assert_eq!(incircle(&a, &b, &c, &d), Sign::Positive);
    }

    #[test]
    fn test_incircle_outside() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 0.0);
        let c = Point2::new(0.5, 0.866025403784);
        let d = Point2::new(2.0, 2.0);
        assert_eq!(incircle(&a, &b, &c, &d), Sign::Negative);
    }

    // ==========================================================================
    // insphere tests
    // ==========================================================================

    #[test]
    fn test_insphere_inside() {
        // Regular tetrahedron centered at origin
        let a = Point3::new(1.0, 1.0, 1.0);
        let b = Point3::new(1.0, -1.0, -1.0);
        let c = Point3::new(-1.0, 1.0, -1.0);
        let d = Point3::new(-1.0, -1.0, 1.0);
        let e = Point3::new(0.0, 0.0, 0.0); // center
        assert_eq!(insphere(&a, &b, &c, &d, &e), Sign::Positive);
    }

    #[test]
    fn test_insphere_outside() {
        let a = Point3::new(1.0, 1.0, 1.0);
        let b = Point3::new(1.0, -1.0, -1.0);
        let c = Point3::new(-1.0, 1.0, -1.0);
        let d = Point3::new(-1.0, -1.0, 1.0);
        let e = Point3::new(10.0, 10.0, 10.0);
        assert_eq!(insphere(&a, &b, &c, &d, &e), Sign::Negative);
    }

    // ==========================================================================
    // Derived predicate tests
    // ==========================================================================

    #[test]
    fn test_point_on_segment_2d_middle() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(2.0, 0.0);
        let p = Point2::new(1.0, 0.0);
        assert!(point_on_segment_2d(&p, &a, &b));
    }

    #[test]
    fn test_point_on_segment_2d_endpoint() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(2.0, 0.0);
        assert!(point_on_segment_2d(&a, &a, &b));
        assert!(point_on_segment_2d(&b, &a, &b));
    }

    #[test]
    fn test_point_on_segment_2d_off_segment() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(2.0, 0.0);
        let p = Point2::new(1.0, 0.1);
        assert!(!point_on_segment_2d(&p, &a, &b));
    }

    #[test]
    fn test_point_on_segment_2d_collinear_but_outside() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(2.0, 0.0);
        let p = Point2::new(3.0, 0.0);
        assert!(!point_on_segment_2d(&p, &a, &b));
    }

    #[test]
    fn test_point_on_plane_on() {
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let p = Point3::new(0.5, 0.5, 0.0);
        assert!(point_on_plane(&p, &a, &b, &c));
    }

    #[test]
    fn test_point_on_plane_off() {
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let p = Point3::new(0.5, 0.5, 0.1);
        assert!(!point_on_plane(&p, &a, &b, &c));
    }

    #[test]
    fn test_are_coplanar() {
        let a = Point3::new(0.0, 0.0, 0.0);
        let b = Point3::new(1.0, 0.0, 0.0);
        let c = Point3::new(0.0, 1.0, 0.0);
        let d = Point3::new(1.0, 1.0, 0.0);
        assert!(are_coplanar(&a, &b, &c, &d));

        let e = Point3::new(1.0, 1.0, 1.0);
        assert!(!are_coplanar(&a, &b, &c, &e));
    }

    #[test]
    fn test_are_collinear_2d() {
        let a = Point2::new(0.0, 0.0);
        let b = Point2::new(1.0, 1.0);
        let c = Point2::new(2.0, 2.0);
        assert!(are_collinear_2d(&a, &b, &c));

        let d = Point2::new(2.0, 2.1);
        assert!(!are_collinear_2d(&a, &b, &d));
    }
}
