//! Rendered dimension output types.
//!
//! These types represent the final graphical elements that make up
//! a dimension: lines, arcs, arrows, and text.

use crate::types::Point2D;
use serde::{Deserialize, Serialize};

use super::style::ArrowType;

/// A fully rendered dimension ready for export.
///
/// Contains all the graphical primitives needed to draw a dimension:
/// lines, arcs, arrows, and text elements.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RenderedDimension {
    /// Straight line segments (extension lines, dimension lines).
    pub lines: Vec<(Point2D, Point2D)>,

    /// Arc segments (for angular dimensions).
    pub arcs: Vec<RenderedArc>,

    /// Arrow terminators.
    pub arrows: Vec<RenderedArrow>,

    /// Text labels.
    pub texts: Vec<RenderedText>,

    /// Whether this is a basic dimension (should be enclosed in a box).
    pub is_basic: bool,
}

impl RenderedDimension {
    /// Create a new empty rendered dimension.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a line segment.
    pub fn add_line(&mut self, start: Point2D, end: Point2D) {
        self.lines.push((start, end));
    }

    /// Add an arc segment.
    pub fn add_arc(&mut self, arc: RenderedArc) {
        self.arcs.push(arc);
    }

    /// Add an arrow.
    pub fn add_arrow(&mut self, arrow: RenderedArrow) {
        self.arrows.push(arrow);
    }

    /// Add a text element.
    pub fn add_text(&mut self, text: RenderedText) {
        self.texts.push(text);
    }

    /// Mark this as a basic dimension.
    pub fn set_basic(&mut self, basic: bool) {
        self.is_basic = basic;
    }

    /// Check if the dimension has any content.
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
            && self.arcs.is_empty()
            && self.arrows.is_empty()
            && self.texts.is_empty()
    }

    /// Compute the bounding box of all elements.
    pub fn bounds(&self) -> Option<(Point2D, Point2D)> {
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;

        for (p1, p2) in &self.lines {
            min_x = min_x.min(p1.x).min(p2.x);
            min_y = min_y.min(p1.y).min(p2.y);
            max_x = max_x.max(p1.x).max(p2.x);
            max_y = max_y.max(p1.y).max(p2.y);
        }

        for arc in &self.arcs {
            // Approximate arc bounds
            let r = arc.radius;
            min_x = min_x.min(arc.center.x - r);
            min_y = min_y.min(arc.center.y - r);
            max_x = max_x.max(arc.center.x + r);
            max_y = max_y.max(arc.center.y + r);
        }

        for arrow in &self.arrows {
            min_x = min_x.min(arrow.tip.x);
            min_y = min_y.min(arrow.tip.y);
            max_x = max_x.max(arrow.tip.x);
            max_y = max_y.max(arrow.tip.y);
        }

        for text in &self.texts {
            min_x = min_x.min(text.position.x);
            min_y = min_y.min(text.position.y);
            max_x = max_x.max(text.position.x);
            max_y = max_y.max(text.position.y);
        }

        if min_x.is_finite() && min_y.is_finite() && max_x.is_finite() && max_y.is_finite() {
            Some((Point2D::new(min_x, min_y), Point2D::new(max_x, max_y)))
        } else {
            None
        }
    }
}

/// A rendered arc segment.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderedArc {
    /// Center of the arc.
    pub center: Point2D,

    /// Radius of the arc.
    pub radius: f64,

    /// Start angle in radians.
    pub start_angle: f64,

    /// End angle in radians.
    pub end_angle: f64,
}

impl RenderedArc {
    /// Create a new arc.
    pub fn new(center: Point2D, radius: f64, start_angle: f64, end_angle: f64) -> Self {
        Self {
            center,
            radius,
            start_angle,
            end_angle,
        }
    }

    /// Get the start point of the arc.
    pub fn start_point(&self) -> Point2D {
        Point2D::new(
            self.center.x + self.radius * self.start_angle.cos(),
            self.center.y + self.radius * self.start_angle.sin(),
        )
    }

    /// Get the end point of the arc.
    pub fn end_point(&self) -> Point2D {
        Point2D::new(
            self.center.x + self.radius * self.end_angle.cos(),
            self.center.y + self.radius * self.end_angle.sin(),
        )
    }

    /// Get the angular span of the arc in radians.
    pub fn span(&self) -> f64 {
        (self.end_angle - self.start_angle).abs()
    }
}

/// A rendered arrow terminator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderedArrow {
    /// Position of the arrow tip.
    pub tip: Point2D,

    /// Direction the arrow points (angle in radians, 0 = right).
    pub direction: f64,

    /// Type of arrow to draw.
    pub arrow_type: ArrowType,

    /// Size of the arrow.
    pub size: f64,
}

impl RenderedArrow {
    /// Create a new arrow.
    pub fn new(tip: Point2D, direction: f64, arrow_type: ArrowType, size: f64) -> Self {
        Self {
            tip,
            direction,
            arrow_type,
            size,
        }
    }

    /// Get the points that form a closed filled arrowhead.
    ///
    /// Returns three points: the tip and two base corners.
    pub fn arrowhead_points(&self) -> (Point2D, Point2D, Point2D) {
        let angle = self.direction;
        let half_angle = std::f64::consts::FRAC_PI_6; // 30 degrees
        let length = self.size;

        // Arrow points backward from tip
        let base_angle1 = angle + std::f64::consts::PI - half_angle;
        let base_angle2 = angle + std::f64::consts::PI + half_angle;

        let p1 = Point2D::new(
            self.tip.x + length * base_angle1.cos(),
            self.tip.y + length * base_angle1.sin(),
        );
        let p2 = Point2D::new(
            self.tip.x + length * base_angle2.cos(),
            self.tip.y + length * base_angle2.sin(),
        );

        (self.tip, p1, p2)
    }

    /// Get the lines for an open arrowhead.
    ///
    /// Returns two line segments from tip to each barb.
    pub fn open_arrowhead_lines(&self) -> ((Point2D, Point2D), (Point2D, Point2D)) {
        let (tip, p1, p2) = self.arrowhead_points();
        ((tip, p1), (tip, p2))
    }
}

/// A rendered text label.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderedText {
    /// Position of the text anchor point.
    pub position: Point2D,

    /// The text content.
    pub text: String,

    /// Text height in drawing units.
    pub height: f64,

    /// Rotation angle in radians (0 = horizontal).
    pub rotation: f64,

    /// Text alignment relative to the position.
    pub alignment: TextAlignment,
}

impl RenderedText {
    /// Create a new text element.
    pub fn new(position: Point2D, text: impl Into<String>, height: f64) -> Self {
        Self {
            position,
            text: text.into(),
            height,
            rotation: 0.0,
            alignment: TextAlignment::MiddleCenter,
        }
    }

    /// Set the rotation angle.
    pub fn with_rotation(mut self, rotation: f64) -> Self {
        self.rotation = rotation;
        self
    }

    /// Set the text alignment.
    pub fn with_alignment(mut self, alignment: TextAlignment) -> Self {
        self.alignment = alignment;
        self
    }
}

/// Text alignment options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum TextAlignment {
    /// Top-left corner at position.
    TopLeft,
    /// Top-center at position.
    TopCenter,
    /// Top-right corner at position.
    TopRight,
    /// Middle-left at position.
    MiddleLeft,
    /// Center of text at position.
    #[default]
    MiddleCenter,
    /// Middle-right at position.
    MiddleRight,
    /// Bottom-left corner at position.
    BottomLeft,
    /// Bottom-center at position.
    BottomCenter,
    /// Bottom-right corner at position.
    BottomRight,
}

impl TextAlignment {
    /// Get DXF horizontal alignment code.
    pub fn dxf_horizontal(&self) -> u8 {
        match self {
            TextAlignment::TopLeft | TextAlignment::MiddleLeft | TextAlignment::BottomLeft => 0,
            TextAlignment::TopCenter
            | TextAlignment::MiddleCenter
            | TextAlignment::BottomCenter => 1,
            TextAlignment::TopRight | TextAlignment::MiddleRight | TextAlignment::BottomRight => 2,
        }
    }

    /// Get DXF vertical alignment code.
    pub fn dxf_vertical(&self) -> u8 {
        match self {
            TextAlignment::BottomLeft
            | TextAlignment::BottomCenter
            | TextAlignment::BottomRight => 1,
            TextAlignment::MiddleLeft
            | TextAlignment::MiddleCenter
            | TextAlignment::MiddleRight => 2,
            TextAlignment::TopLeft | TextAlignment::TopCenter | TextAlignment::TopRight => 3,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rendered_dimension_empty() {
        let rd = RenderedDimension::new();
        assert!(rd.is_empty());
        assert!(rd.bounds().is_none());
    }

    #[test]
    fn test_rendered_dimension_with_line() {
        let mut rd = RenderedDimension::new();
        rd.add_line(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0));

        assert!(!rd.is_empty());
        let bounds = rd.bounds().unwrap();
        assert!((bounds.0.x - 0.0).abs() < 1e-10);
        assert!((bounds.1.x - 100.0).abs() < 1e-10);
    }

    #[test]
    fn test_arrowhead_points() {
        let arrow = RenderedArrow::new(
            Point2D::new(0.0, 0.0),
            0.0, // Pointing right
            ArrowType::ClosedFilled,
            2.0,
        );

        let (tip, p1, p2) = arrow.arrowhead_points();
        assert!((tip.x - 0.0).abs() < 1e-10);
        assert!((tip.y - 0.0).abs() < 1e-10);

        // Base points should be behind the tip (negative X)
        assert!(p1.x < 0.0);
        assert!(p2.x < 0.0);

        // Symmetrical about the X axis
        assert!((p1.y + p2.y).abs() < 1e-10);
    }

    #[test]
    fn test_arc_points() {
        let arc = RenderedArc::new(
            Point2D::new(0.0, 0.0),
            10.0,
            0.0,
            std::f64::consts::FRAC_PI_2,
        );

        let start = arc.start_point();
        assert!((start.x - 10.0).abs() < 1e-10);
        assert!(start.y.abs() < 1e-10);

        let end = arc.end_point();
        assert!(end.x.abs() < 1e-10);
        assert!((end.y - 10.0).abs() < 1e-10);
    }

    #[test]
    fn test_text_builder() {
        let text = RenderedText::new(Point2D::new(50.0, 10.0), "100.00", 2.5)
            .with_rotation(std::f64::consts::FRAC_PI_4)
            .with_alignment(TextAlignment::BottomCenter);

        assert!((text.rotation - std::f64::consts::FRAC_PI_4).abs() < 1e-10);
        assert_eq!(text.alignment, TextAlignment::BottomCenter);
    }
}
