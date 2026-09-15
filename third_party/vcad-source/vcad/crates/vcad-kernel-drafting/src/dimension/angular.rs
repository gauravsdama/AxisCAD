//! Angular dimension types.
//!
//! Provides angular dimensions for measuring angles between edges,
//! at vertices, or between three points.

use serde::{Deserialize, Serialize};

use super::geometry_ref::GeometryRef;
use super::render::{RenderedArc, RenderedArrow, RenderedDimension, RenderedText, TextAlignment};
use super::style::{ArrowType, DimensionStyle, ToleranceMode};
use crate::types::{Point2D, ProjectedView};

/// Definition of the angle to measure.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AngleDefinition {
    /// Angle between two edges (uses edge directions).
    TwoEdges {
        /// First edge reference.
        edge1: GeometryRef,
        /// Second edge reference.
        edge2: GeometryRef,
    },

    /// Angle at a vertex defined by three points (vertex is the middle point).
    ThreePoints {
        /// First point (on one ray).
        p1: GeometryRef,
        /// Vertex point (center of the angle).
        vertex: GeometryRef,
        /// Second point (on the other ray).
        p2: GeometryRef,
    },

    /// Angle of a single edge from the horizontal.
    EdgeAngle {
        /// The edge to measure.
        edge: GeometryRef,
    },
}

/// An angular dimension measuring an angle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AngularDimension {
    /// Definition of the angle to measure.
    pub definition: AngleDefinition,

    /// Radius of the dimension arc from the vertex.
    pub arc_radius: f64,

    /// Optional text override (replaces computed value).
    pub text_override: Option<String>,

    /// Optional custom style (uses default if None).
    pub style: Option<DimensionStyle>,
}

impl AngularDimension {
    /// Create an angular dimension between two edges.
    pub fn between_edges(
        edge1: impl Into<GeometryRef>,
        edge2: impl Into<GeometryRef>,
        arc_radius: f64,
    ) -> Self {
        Self {
            definition: AngleDefinition::TwoEdges {
                edge1: edge1.into(),
                edge2: edge2.into(),
            },
            arc_radius,
            text_override: None,
            style: None,
        }
    }

    /// Create an angular dimension from three points (vertex is middle).
    pub fn from_three_points(
        p1: impl Into<GeometryRef>,
        vertex: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        arc_radius: f64,
    ) -> Self {
        Self {
            definition: AngleDefinition::ThreePoints {
                p1: p1.into(),
                vertex: vertex.into(),
                p2: p2.into(),
            },
            arc_radius,
            text_override: None,
            style: None,
        }
    }

    /// Create an angular dimension showing angle of an edge from horizontal.
    pub fn edge_angle(edge: impl Into<GeometryRef>, arc_radius: f64) -> Self {
        Self {
            definition: AngleDefinition::EdgeAngle { edge: edge.into() },
            arc_radius,
            text_override: None,
            style: None,
        }
    }

    /// Set a custom style.
    pub fn with_style(mut self, style: DimensionStyle) -> Self {
        self.style = Some(style);
        self
    }

    /// Set a text override.
    pub fn with_text_override(mut self, text: impl Into<String>) -> Self {
        self.text_override = Some(text.into());
        self
    }

    /// Render the dimension to graphical primitives.
    pub fn render(
        &self,
        view: Option<&ProjectedView>,
        default_style: &DimensionStyle,
    ) -> Option<RenderedDimension> {
        let style = self.style.as_ref().unwrap_or(default_style);

        // Resolve angle definition to get vertex and two angles
        let (vertex, start_angle, end_angle) = match &self.definition {
            AngleDefinition::TwoEdges { edge1, edge2 } => {
                self.resolve_two_edges(edge1, edge2, view)?
            }
            AngleDefinition::ThreePoints { p1, vertex, p2 } => {
                self.resolve_three_points(p1, vertex, p2, view)?
            }
            AngleDefinition::EdgeAngle { edge } => self.resolve_edge_angle(edge, view)?,
        };

        // Calculate angle value in degrees
        let mut angle_radians = end_angle - start_angle;
        if angle_radians < 0.0 {
            angle_radians += 2.0 * std::f64::consts::PI;
        }
        if angle_radians > std::f64::consts::PI {
            // Use the smaller angle
            angle_radians = 2.0 * std::f64::consts::PI - angle_radians;
        }
        let angle_degrees = angle_radians.to_degrees();

        let mut result = RenderedDimension::new();

        // Add extension lines from vertex along each ray
        let ext_length = self.arc_radius + style.extension_line_overshoot;

        let ext1_end = Point2D::new(
            vertex.x + ext_length * start_angle.cos(),
            vertex.y + ext_length * start_angle.sin(),
        );
        let ext2_end = Point2D::new(
            vertex.x + ext_length * end_angle.cos(),
            vertex.y + ext_length * end_angle.sin(),
        );

        // Start extension lines with a small gap from vertex
        let ext1_start = Point2D::new(
            vertex.x + style.extension_line_gap * start_angle.cos(),
            vertex.y + style.extension_line_gap * start_angle.sin(),
        );
        let ext2_start = Point2D::new(
            vertex.x + style.extension_line_gap * end_angle.cos(),
            vertex.y + style.extension_line_gap * end_angle.sin(),
        );

        result.add_line(ext1_start, ext1_end);
        result.add_line(ext2_start, ext2_end);

        // Add dimension arc
        result.add_arc(RenderedArc::new(
            vertex,
            self.arc_radius,
            start_angle,
            end_angle,
        ));

        // Add arrows at arc ends
        if style.arrow_type != ArrowType::None {
            // Arrow at start of arc (perpendicular to radius, pointing CCW)
            let arrow1_dir = start_angle + std::f64::consts::FRAC_PI_2;
            let arrow1_pos = Point2D::new(
                vertex.x + self.arc_radius * start_angle.cos(),
                vertex.y + self.arc_radius * start_angle.sin(),
            );

            // Arrow at end of arc (perpendicular to radius, pointing CW)
            let arrow2_dir = end_angle - std::f64::consts::FRAC_PI_2;
            let arrow2_pos = Point2D::new(
                vertex.x + self.arc_radius * end_angle.cos(),
                vertex.y + self.arc_radius * end_angle.sin(),
            );

            result.add_arrow(RenderedArrow::new(
                arrow1_pos,
                arrow1_dir,
                style.arrow_type,
                style.arrow_size,
            ));
            result.add_arrow(RenderedArrow::new(
                arrow2_pos,
                arrow2_dir,
                style.arrow_type,
                style.arrow_size,
            ));
        }

        // Add text at midpoint of arc
        let mid_angle = (start_angle + end_angle) / 2.0;
        let text_radius = self.arc_radius + style.text_height * 0.5;
        let text_position = Point2D::new(
            vertex.x + text_radius * mid_angle.cos(),
            vertex.y + text_radius * mid_angle.sin(),
        );

        let text_content = self.text_override.clone().unwrap_or_else(|| {
            format!(
                "{:.prec$}\u{00B0}",
                angle_degrees,
                prec = style.precision as usize
            )
        });

        result.add_text(
            RenderedText::new(text_position, text_content, style.text_height)
                .with_alignment(TextAlignment::MiddleCenter),
        );

        if style.tolerance_mode == ToleranceMode::Basic {
            result.set_basic(true);
        }

        Some(result)
    }

    /// Resolve two edges to vertex and angles.
    fn resolve_two_edges(
        &self,
        edge1: &GeometryRef,
        edge2: &GeometryRef,
        view: Option<&ProjectedView>,
    ) -> Option<(Point2D, f64, f64)> {
        let view = view?;
        let e1 = edge1.get_edge(view)?;
        let e2 = edge2.get_edge(view)?;

        // Find intersection of the two edges (extended as lines)
        let vertex = super::geometry_ref::line_line_intersection_infinite(
            &e1.start, &e1.end, &e2.start, &e2.end,
        )?;

        // Calculate angles of each edge from the vertex
        let angle1 = (e1.end.y - e1.start.y).atan2(e1.end.x - e1.start.x);
        let angle2 = (e2.end.y - e2.start.y).atan2(e2.end.x - e2.start.x);

        // Normalize angles to [0, 2π)
        let angle1 = normalize_angle(angle1);
        let angle2 = normalize_angle(angle2);

        // Order angles so we measure the smaller angle
        let (start, end) = if angle1 < angle2 {
            (angle1, angle2)
        } else {
            (angle2, angle1)
        };

        Some((vertex, start, end))
    }

    /// Resolve three points to vertex and angles.
    fn resolve_three_points(
        &self,
        p1: &GeometryRef,
        vertex: &GeometryRef,
        p2: &GeometryRef,
        view: Option<&ProjectedView>,
    ) -> Option<(Point2D, f64, f64)> {
        let v = if let Some(view) = view {
            vertex.resolve(view)?
        } else {
            vertex.resolve_standalone()?
        };

        let point1 = if let Some(view) = view {
            p1.resolve(view)?
        } else {
            p1.resolve_standalone()?
        };

        let point2 = if let Some(view) = view {
            p2.resolve(view)?
        } else {
            p2.resolve_standalone()?
        };

        let angle1 = (point1.y - v.y).atan2(point1.x - v.x);
        let angle2 = (point2.y - v.y).atan2(point2.x - v.x);

        let angle1 = normalize_angle(angle1);
        let angle2 = normalize_angle(angle2);

        // Order to measure the smaller angle
        let (start, end) = if angle1 < angle2 {
            (angle1, angle2)
        } else {
            (angle2, angle1)
        };

        // If the arc would be greater than 180°, swap to get smaller arc
        if end - start > std::f64::consts::PI {
            Some((v, end, start + 2.0 * std::f64::consts::PI))
        } else {
            Some((v, start, end))
        }
    }

    /// Resolve edge angle from horizontal.
    fn resolve_edge_angle(
        &self,
        edge: &GeometryRef,
        view: Option<&ProjectedView>,
    ) -> Option<(Point2D, f64, f64)> {
        let view = view?;
        let e = edge.get_edge(view)?;

        let vertex = e.start;
        let edge_angle = (e.end.y - e.start.y).atan2(e.end.x - e.start.x);
        let edge_angle = normalize_angle(edge_angle);

        // Measure from horizontal (0°) to the edge angle
        Some((vertex, 0.0, edge_angle))
    }
}

/// Normalize an angle to the range [0, 2π).
fn normalize_angle(angle: f64) -> f64 {
    let two_pi = 2.0 * std::f64::consts::PI;
    let mut result = angle % two_pi;
    if result < 0.0 {
        result += two_pi;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_three_point_angle_45() {
        let dim = AngularDimension::from_three_points(
            Point2D::new(10.0, 0.0),  // Point on X axis
            Point2D::new(0.0, 0.0),   // Vertex at origin
            Point2D::new(10.0, 10.0), // Point at 45°
            15.0,
        );

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 2 extension lines
        assert_eq!(rendered.lines.len(), 2);

        // Should have 1 arc
        assert_eq!(rendered.arcs.len(), 1);

        // Should have 2 arrows
        assert_eq!(rendered.arrows.len(), 2);

        // Text should show 45°
        assert!(rendered.texts[0].text.contains("45"));
    }

    #[test]
    fn test_three_point_angle_90() {
        let dim = AngularDimension::from_three_points(
            Point2D::new(10.0, 0.0), // Point on +X
            Point2D::new(0.0, 0.0),  // Vertex
            Point2D::new(0.0, 10.0), // Point on +Y
            15.0,
        );

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Text should show 90°
        assert!(rendered.texts[0].text.contains("90"));
    }

    #[test]
    fn test_normalize_angle() {
        assert!((normalize_angle(0.0) - 0.0).abs() < 1e-10);
        assert!((normalize_angle(std::f64::consts::PI) - std::f64::consts::PI).abs() < 1e-10);
        assert!(
            (normalize_angle(-std::f64::consts::FRAC_PI_2) - (3.0 * std::f64::consts::FRAC_PI_2))
                .abs()
                < 1e-10
        );
    }

    #[test]
    fn test_text_override() {
        let dim = AngularDimension::from_three_points(
            Point2D::new(10.0, 0.0),
            Point2D::new(0.0, 0.0),
            Point2D::new(10.0, 10.0),
            15.0,
        )
        .with_text_override("CUSTOM");

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert_eq!(rendered.texts[0].text, "CUSTOM");
    }
}
