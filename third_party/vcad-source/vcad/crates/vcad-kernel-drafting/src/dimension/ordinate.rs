//! Ordinate dimension types.
//!
//! Provides ordinate (datum-relative) dimensions that show X or Y
//! coordinates relative to a datum point.

use serde::{Deserialize, Serialize};

use super::geometry_ref::GeometryRef;
use super::render::{RenderedDimension, RenderedText, TextAlignment};
use super::style::{DimensionStyle, ToleranceMode};
use crate::types::{Point2D, ProjectedView};

/// An ordinate dimension showing coordinate relative to a datum.
///
/// Ordinate dimensions are used in precision manufacturing drawings
/// to show X or Y coordinates from a common datum point, reducing
/// tolerance stack-up compared to chain dimensions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrdinateDimension {
    /// The point being dimensioned.
    pub point: GeometryRef,

    /// If true, show X ordinate; if false, show Y ordinate.
    pub is_x_ordinate: bool,

    /// The datum (origin) point for measurement.
    pub datum: Point2D,

    /// Length of the leader line extending from the point.
    pub leader_length: f64,

    /// Optional text override (replaces computed value).
    pub text_override: Option<String>,

    /// Optional custom style (uses default if None).
    pub style: Option<DimensionStyle>,
}

impl OrdinateDimension {
    /// Create an X-ordinate dimension (horizontal distance from datum).
    pub fn x_ordinate(point: impl Into<GeometryRef>, datum: Point2D, leader_length: f64) -> Self {
        Self {
            point: point.into(),
            is_x_ordinate: true,
            datum,
            leader_length,
            text_override: None,
            style: None,
        }
    }

    /// Create a Y-ordinate dimension (vertical distance from datum).
    pub fn y_ordinate(point: impl Into<GeometryRef>, datum: Point2D, leader_length: f64) -> Self {
        Self {
            point: point.into(),
            is_x_ordinate: false,
            datum,
            leader_length,
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

        // Resolve the point
        let point = if let Some(v) = view {
            self.point.resolve(v)?
        } else {
            self.point.resolve_standalone()?
        };

        let mut result = RenderedDimension::new();

        // Calculate ordinate value
        let ordinate_value = if self.is_x_ordinate {
            point.x - self.datum.x
        } else {
            point.y - self.datum.y
        };

        // Ordinate dimensions have a leader that extends perpendicular
        // to the ordinate direction, then turns to run parallel
        if self.is_x_ordinate {
            // X ordinate: leader goes up/down, then horizontal
            let vertical_direction: f64 = if self.leader_length >= 0.0 { 1.0 } else { -1.0 };
            let leader_end_y = point.y + self.leader_length;

            // Vertical segment from point
            let leader_knee = Point2D::new(point.x, leader_end_y);
            result.add_line(point, leader_knee);

            // Horizontal segment for text
            let text_extension = style.text_height * 3.0;
            let leader_final = Point2D::new(
                point.x + text_extension * vertical_direction.signum(),
                leader_end_y,
            );
            result.add_line(leader_knee, leader_final);

            // Text at end of leader
            let text_content = self
                .text_override
                .clone()
                .unwrap_or_else(|| style.format_value(ordinate_value.abs()));

            let text_position = Point2D::new(
                leader_final.x + style.text_height * vertical_direction.signum(),
                leader_final.y,
            );

            result.add_text(
                RenderedText::new(text_position, text_content, style.text_height).with_alignment(
                    if vertical_direction > 0.0 {
                        TextAlignment::MiddleLeft
                    } else {
                        TextAlignment::MiddleRight
                    },
                ),
            );
        } else {
            // Y ordinate: leader goes left/right, then vertical
            let horizontal_direction: f64 = if self.leader_length >= 0.0 { 1.0 } else { -1.0 };
            let leader_end_x = point.x + self.leader_length;

            // Horizontal segment from point
            let leader_knee = Point2D::new(leader_end_x, point.y);
            result.add_line(point, leader_knee);

            // Vertical segment for text
            let text_extension = style.text_height * 3.0;
            let leader_final = Point2D::new(
                leader_end_x,
                point.y + text_extension * horizontal_direction.signum(),
            );
            result.add_line(leader_knee, leader_final);

            // Text at end of leader
            let text_content = self
                .text_override
                .clone()
                .unwrap_or_else(|| style.format_value(ordinate_value.abs()));

            let text_position = Point2D::new(
                leader_final.x,
                leader_final.y + style.text_height * horizontal_direction.signum(),
            );

            result.add_text(
                RenderedText::new(text_position, text_content, style.text_height)
                    .with_rotation(std::f64::consts::FRAC_PI_2)
                    .with_alignment(if horizontal_direction > 0.0 {
                        TextAlignment::MiddleLeft
                    } else {
                        TextAlignment::MiddleRight
                    }),
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
    fn test_x_ordinate() {
        let datum = Point2D::new(0.0, 0.0);
        let dim = OrdinateDimension::x_ordinate(Point2D::new(50.0, 10.0), datum, 20.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 2 leader line segments
        assert_eq!(rendered.lines.len(), 2);

        // Should have 1 text showing 50.00
        assert_eq!(rendered.texts[0].text, "50.00");
    }

    #[test]
    fn test_y_ordinate() {
        let datum = Point2D::new(0.0, 0.0);
        let dim = OrdinateDimension::y_ordinate(Point2D::new(10.0, 75.0), datum, 20.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 2 leader line segments
        assert_eq!(rendered.lines.len(), 2);

        // Should have 1 text showing 75.00
        assert_eq!(rendered.texts[0].text, "75.00");
    }

    #[test]
    fn test_negative_leader() {
        let datum = Point2D::new(0.0, 0.0);
        let dim = OrdinateDimension::x_ordinate(Point2D::new(50.0, 10.0), datum, -20.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should still work with negative leader
        assert_eq!(rendered.lines.len(), 2);
    }

    #[test]
    fn test_text_override() {
        let datum = Point2D::new(0.0, 0.0);
        let dim = OrdinateDimension::x_ordinate(Point2D::new(50.0, 10.0), datum, 20.0)
            .with_text_override("50 REF");

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert_eq!(rendered.texts[0].text, "50 REF");
    }
}
