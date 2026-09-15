//! Geometry reference types for dimension attachment points.
//!
//! Provides flexible ways to specify where dimensions attach to geometry,
//! including direct points, edge references, and computed positions.

use crate::types::{Point2D, ProjectedEdge, ProjectedView};
use serde::{Deserialize, Serialize};

/// Reference to geometry for dimension attachment.
///
/// Allows dimensions to reference geometry in various ways:
/// - Direct 2D point coordinates
/// - Edge indices from a projected view
/// - Circle/arc center and radius
/// - Computed positions (intersections, midpoints, endpoints)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GeometryRef {
    /// Direct 2D point coordinate.
    Point(Point2D),

    /// Reference to an edge by index in the projected view.
    EdgeIndex(usize),

    /// Circle defined by center and radius.
    Circle {
        /// Center point.
        center: Point2D,
        /// Circle radius.
        radius: f64,
    },

    /// Arc defined by center, radius, and angular extent.
    Arc {
        /// Center point.
        center: Point2D,
        /// Arc radius.
        radius: f64,
        /// Start angle in radians.
        start_angle: f64,
        /// End angle in radians.
        end_angle: f64,
    },

    /// Intersection point of two edges.
    EdgeIntersection {
        /// First edge index.
        edge1: usize,
        /// Second edge index.
        edge2: usize,
    },

    /// Midpoint of an edge.
    EdgeMidpoint(usize),

    /// Endpoint of an edge.
    EdgeEndpoint {
        /// Edge index.
        edge: usize,
        /// If true, use the end point; if false, use the start point.
        end: bool,
    },
}

impl GeometryRef {
    /// Create a reference to a direct point.
    pub fn point(x: f64, y: f64) -> Self {
        Self::Point(Point2D::new(x, y))
    }

    /// Create a reference to an edge by index.
    pub fn edge(index: usize) -> Self {
        Self::EdgeIndex(index)
    }

    /// Create a reference to a circle.
    pub fn circle(center: Point2D, radius: f64) -> Self {
        Self::Circle { center, radius }
    }

    /// Create a reference to an arc.
    pub fn arc(center: Point2D, radius: f64, start_angle: f64, end_angle: f64) -> Self {
        Self::Arc {
            center,
            radius,
            start_angle,
            end_angle,
        }
    }

    /// Create a reference to the midpoint of an edge.
    pub fn edge_midpoint(index: usize) -> Self {
        Self::EdgeMidpoint(index)
    }

    /// Create a reference to the start point of an edge.
    pub fn edge_start(index: usize) -> Self {
        Self::EdgeEndpoint {
            edge: index,
            end: false,
        }
    }

    /// Create a reference to the end point of an edge.
    pub fn edge_end(index: usize) -> Self {
        Self::EdgeEndpoint {
            edge: index,
            end: true,
        }
    }

    /// Resolve this reference to a concrete 2D point.
    ///
    /// Returns `None` if the reference cannot be resolved (e.g., edge index
    /// out of bounds or no intersection found).
    pub fn resolve(&self, view: &ProjectedView) -> Option<Point2D> {
        match self {
            GeometryRef::Point(p) => Some(*p),

            GeometryRef::EdgeIndex(idx) => {
                let edge = view.edges.get(*idx)?;
                // Return midpoint of the edge
                Some(Point2D::new(
                    (edge.start.x + edge.end.x) / 2.0,
                    (edge.start.y + edge.end.y) / 2.0,
                ))
            }

            GeometryRef::Circle { center, .. } => Some(*center),

            GeometryRef::Arc { center, .. } => Some(*center),

            GeometryRef::EdgeIntersection { edge1, edge2 } => {
                let e1 = view.edges.get(*edge1)?;
                let e2 = view.edges.get(*edge2)?;
                line_line_intersection(&e1.start, &e1.end, &e2.start, &e2.end)
            }

            GeometryRef::EdgeMidpoint(idx) => {
                let edge = view.edges.get(*idx)?;
                Some(Point2D::new(
                    (edge.start.x + edge.end.x) / 2.0,
                    (edge.start.y + edge.end.y) / 2.0,
                ))
            }

            GeometryRef::EdgeEndpoint { edge, end } => {
                let e = view.edges.get(*edge)?;
                Some(if *end { e.end } else { e.start })
            }
        }
    }

    /// Resolve this reference to a concrete 2D point without a view context.
    ///
    /// Only works for `Point`, `Circle`, and `Arc` variants.
    /// Returns `None` for edge-based references.
    pub fn resolve_standalone(&self) -> Option<Point2D> {
        match self {
            GeometryRef::Point(p) => Some(*p),
            GeometryRef::Circle { center, .. } => Some(*center),
            GeometryRef::Arc { center, .. } => Some(*center),
            _ => None,
        }
    }

    /// Get the edge at this reference, if it refers to an edge.
    pub fn get_edge<'a>(&self, view: &'a ProjectedView) -> Option<&'a ProjectedEdge> {
        match self {
            GeometryRef::EdgeIndex(idx) => view.edges.get(*idx),
            GeometryRef::EdgeMidpoint(idx) => view.edges.get(*idx),
            GeometryRef::EdgeEndpoint { edge, .. } => view.edges.get(*edge),
            _ => None,
        }
    }
}

impl From<Point2D> for GeometryRef {
    fn from(p: Point2D) -> Self {
        Self::Point(p)
    }
}

impl From<(f64, f64)> for GeometryRef {
    fn from((x, y): (f64, f64)) -> Self {
        Self::Point(Point2D::new(x, y))
    }
}

/// Compute the intersection point of two line segments.
///
/// Uses parametric line equations to find the intersection.
/// Returns `None` if lines are parallel or intersection is outside segments.
pub fn line_line_intersection(
    p1: &Point2D,
    p2: &Point2D,
    p3: &Point2D,
    p4: &Point2D,
) -> Option<Point2D> {
    let d1x = p2.x - p1.x;
    let d1y = p2.y - p1.y;
    let d2x = p4.x - p3.x;
    let d2y = p4.y - p3.y;

    let cross = d1x * d2y - d1y * d2x;

    // Lines are parallel (or coincident)
    if cross.abs() < 1e-10 {
        return None;
    }

    let dx = p3.x - p1.x;
    let dy = p3.y - p1.y;

    let t = (dx * d2y - dy * d2x) / cross;
    let u = (dx * d1y - dy * d1x) / cross;

    // Check if intersection is within both line segments
    // Use a small tolerance for edge cases
    const TOL: f64 = 1e-6;
    let range = -TOL..=(1.0 + TOL);
    if range.contains(&t) && range.contains(&u) {
        Some(Point2D::new(p1.x + t * d1x, p1.y + t * d1y))
    } else {
        None
    }
}

/// Compute the intersection point of two infinite lines (not segments).
pub fn line_line_intersection_infinite(
    p1: &Point2D,
    p2: &Point2D,
    p3: &Point2D,
    p4: &Point2D,
) -> Option<Point2D> {
    let d1x = p2.x - p1.x;
    let d1y = p2.y - p1.y;
    let d2x = p4.x - p3.x;
    let d2y = p4.y - p3.y;

    let cross = d1x * d2y - d1y * d2x;

    // Lines are parallel
    if cross.abs() < 1e-10 {
        return None;
    }

    let dx = p3.x - p1.x;
    let dy = p3.y - p1.y;

    let t = (dx * d2y - dy * d2x) / cross;

    Some(Point2D::new(p1.x + t * d1x, p1.y + t * d1y))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_point_resolve() {
        let p = Point2D::new(10.0, 20.0);
        let gr = GeometryRef::Point(p);
        let view = ProjectedView::default();

        let resolved = gr.resolve(&view);
        assert!(resolved.is_some());
        let r = resolved.unwrap();
        assert!((r.x - 10.0).abs() < 1e-10);
        assert!((r.y - 20.0).abs() < 1e-10);
    }

    #[test]
    fn test_circle_resolve() {
        let gr = GeometryRef::circle(Point2D::new(50.0, 50.0), 25.0);
        let view = ProjectedView::default();

        let resolved = gr.resolve(&view);
        assert!(resolved.is_some());
        let r = resolved.unwrap();
        assert!((r.x - 50.0).abs() < 1e-10);
        assert!((r.y - 50.0).abs() < 1e-10);
    }

    #[test]
    fn test_line_intersection() {
        // Perpendicular lines crossing at (5, 5)
        let p1 = Point2D::new(0.0, 5.0);
        let p2 = Point2D::new(10.0, 5.0);
        let p3 = Point2D::new(5.0, 0.0);
        let p4 = Point2D::new(5.0, 10.0);

        let intersection = line_line_intersection(&p1, &p2, &p3, &p4);
        assert!(intersection.is_some());
        let i = intersection.unwrap();
        assert!((i.x - 5.0).abs() < 1e-10);
        assert!((i.y - 5.0).abs() < 1e-10);
    }

    #[test]
    fn test_parallel_lines_no_intersection() {
        // Parallel horizontal lines
        let p1 = Point2D::new(0.0, 0.0);
        let p2 = Point2D::new(10.0, 0.0);
        let p3 = Point2D::new(0.0, 5.0);
        let p4 = Point2D::new(10.0, 5.0);

        let intersection = line_line_intersection(&p1, &p2, &p3, &p4);
        assert!(intersection.is_none());
    }

    #[test]
    fn test_from_tuple() {
        let gr: GeometryRef = (10.0, 20.0).into();
        match gr {
            GeometryRef::Point(p) => {
                assert!((p.x - 10.0).abs() < 1e-10);
                assert!((p.y - 20.0).abs() < 1e-10);
            }
            _ => panic!("Expected Point variant"),
        }
    }
}
