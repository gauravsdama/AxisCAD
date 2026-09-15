//! Radial dimension types.
//!
//! Provides radius and diameter dimensions for circles and arcs.

use serde::{Deserialize, Serialize};

use super::geometry_ref::GeometryRef;
use super::render::{RenderedArrow, RenderedDimension, RenderedText, TextAlignment};
use super::style::{ArrowType, DimensionStyle, ToleranceMode};
use crate::types::{Point2D, ProjectedView};

/// A radial dimension measuring radius or diameter of a circle/arc.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RadialDimension {
    /// Reference to the circle or arc being dimensioned.
    pub circle_ref: GeometryRef,

    /// If true, show diameter; if false, show radius.
    pub is_diameter: bool,

    /// Angle at which the leader line extends (in radians, 0 = right).
    pub leader_angle: f64,

    /// Optional text override (replaces computed value).
    pub text_override: Option<String>,

    /// Optional custom style (uses default if None).
    pub style: Option<DimensionStyle>,
}

impl RadialDimension {
    /// Create a radius dimension.
    pub fn radius(circle_ref: impl Into<GeometryRef>, leader_angle: f64) -> Self {
        Self {
            circle_ref: circle_ref.into(),
            is_diameter: false,
            leader_angle,
            text_override: None,
            style: None,
        }
    }

    /// Create a diameter dimension.
    pub fn diameter(circle_ref: impl Into<GeometryRef>, leader_angle: f64) -> Self {
        Self {
            circle_ref: circle_ref.into(),
            is_diameter: true,
            leader_angle,
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
        _view: Option<&ProjectedView>,
        default_style: &DimensionStyle,
    ) -> Option<RenderedDimension> {
        let style = self.style.as_ref().unwrap_or(default_style);

        // Get circle center and radius
        let (center, radius) = match &self.circle_ref {
            GeometryRef::Circle { center, radius } => (*center, *radius),
            GeometryRef::Arc { center, radius, .. } => (*center, *radius),
            _ => return None, // Only circles and arcs supported
        };

        let mut result = RenderedDimension::new();

        // Calculate measurement value
        let measure_value = if self.is_diameter {
            radius * 2.0
        } else {
            radius
        };

        // Calculate leader line direction
        let cos_a = self.leader_angle.cos();
        let sin_a = self.leader_angle.sin();

        if self.is_diameter {
            // Diameter: line through center with arrows at both ends
            let p1 = Point2D::new(center.x - radius * cos_a, center.y - radius * sin_a);
            let p2 = Point2D::new(center.x + radius * cos_a, center.y + radius * sin_a);

            result.add_line(p1, p2);

            // Add arrows at both ends pointing inward
            if style.arrow_type != ArrowType::None {
                result.add_arrow(RenderedArrow::new(
                    p1,
                    self.leader_angle,
                    style.arrow_type,
                    style.arrow_size,
                ));
                result.add_arrow(RenderedArrow::new(
                    p2,
                    self.leader_angle + std::f64::consts::PI,
                    style.arrow_type,
                    style.arrow_size,
                ));
            }

            // Text at center, offset perpendicular to leader
            let text_offset = style.text_height * 0.5;
            let perp_angle = self.leader_angle + std::f64::consts::FRAC_PI_2;
            let text_position = Point2D::new(
                center.x + text_offset * perp_angle.cos(),
                center.y + text_offset * perp_angle.sin(),
            );

            let text_content = self.text_override.clone().unwrap_or_else(|| {
                format!(
                    "\u{2300}{:.prec$}",
                    measure_value,
                    prec = style.precision as usize
                )
            });

            result.add_text(
                RenderedText::new(text_position, text_content, style.text_height)
                    .with_rotation(self.leader_angle)
                    .with_alignment(TextAlignment::BottomCenter),
            );
        } else {
            // Radius: line from center to edge with arrow at edge
            let edge_point = Point2D::new(center.x + radius * cos_a, center.y + radius * sin_a);

            // Extend beyond circle for text
            let text_extension = style.text_height * 3.0;
            let leader_end = Point2D::new(
                center.x + (radius + text_extension) * cos_a,
                center.y + (radius + text_extension) * sin_a,
            );

            result.add_line(center, leader_end);

            // Arrow at the edge of the circle, pointing outward
            if style.arrow_type != ArrowType::None {
                result.add_arrow(RenderedArrow::new(
                    edge_point,
                    self.leader_angle,
                    style.arrow_type,
                    style.arrow_size,
                ));
            }

            // Text beyond the arrow
            let text_position = Point2D::new(
                center.x + (radius + text_extension * 0.5) * cos_a,
                center.y + (radius + text_extension * 0.5) * sin_a + style.text_height * 0.5,
            );

            let text_content = self.text_override.clone().unwrap_or_else(|| {
                format!("R{:.prec$}", measure_value, prec = style.precision as usize)
            });

            result.add_text(
                RenderedText::new(text_position, text_content, style.text_height)
                    .with_rotation(if cos_a >= 0.0 {
                        0.0
                    } else {
                        std::f64::consts::PI
                    })
                    .with_alignment(TextAlignment::MiddleCenter),
            );
        }

        if style.tolerance_mode == ToleranceMode::Basic {
            result.set_basic(true);
        }

        Some(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_radius_dimension() {
        let dim = RadialDimension::radius(
            GeometryRef::Circle {
                center: Point2D::new(50.0, 50.0),
                radius: 25.0,
            },
            0.0, // Leader to the right
        );

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 1 leader line
        assert_eq!(rendered.lines.len(), 1);

        // Should have 1 arrow
        assert_eq!(rendered.arrows.len(), 1);

        // Text should show R25.00
        assert!(rendered.texts[0].text.contains("R25"));
    }

    #[test]
    fn test_diameter_dimension() {
        let dim = RadialDimension::diameter(
            GeometryRef::Circle {
                center: Point2D::new(50.0, 50.0),
                radius: 25.0,
            },
            std::f64::consts::FRAC_PI_4, // Leader at 45°
        );

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 1 diameter line
        assert_eq!(rendered.lines.len(), 1);

        // Should have 2 arrows (both ends)
        assert_eq!(rendered.arrows.len(), 2);

        // Text should show diameter symbol and 50.00
        assert!(rendered.texts[0].text.contains("\u{2300}"));
        assert!(rendered.texts[0].text.contains("50"));
    }

    #[test]
    fn test_text_override() {
        let dim = RadialDimension::radius(
            GeometryRef::Circle {
                center: Point2D::new(50.0, 50.0),
                radius: 25.0,
            },
            0.0,
        )
        .with_text_override("R25 TYP");

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert_eq!(rendered.texts[0].text, "R25 TYP");
    }

    #[test]
    fn test_arc_dimension() {
        let dim = RadialDimension::radius(
            GeometryRef::Arc {
                center: Point2D::new(0.0, 0.0),
                radius: 30.0,
                start_angle: 0.0,
                end_angle: std::f64::consts::FRAC_PI_2,
            },
            std::f64::consts::FRAC_PI_4, // Leader at 45° (middle of arc)
        );

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert!(rendered.texts[0].text.contains("R30"));
    }
}
