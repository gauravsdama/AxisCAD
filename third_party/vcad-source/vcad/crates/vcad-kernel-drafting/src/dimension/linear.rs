//! Linear dimension types.
//!
//! Provides horizontal, vertical, aligned, and rotated linear dimensions
//! for measuring distances between two points.

use serde::{Deserialize, Serialize};

use super::geometry_ref::GeometryRef;
use super::render::{RenderedArrow, RenderedDimension, RenderedText, TextAlignment};
use super::style::{ArrowType, DimensionStyle, TextPlacement, ToleranceMode};
use crate::types::{Point2D, ProjectedView};

/// Type of linear dimension measurement.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
pub enum LinearDimensionType {
    /// Measure horizontal distance only (projected to X axis).
    #[default]
    Horizontal,

    /// Measure vertical distance only (projected to Y axis).
    Vertical,

    /// Measure true distance between points (along the line connecting them).
    Aligned,

    /// Measure along a specific angle (in radians).
    Rotated(f64),
}

/// A linear dimension measuring distance between two points.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinearDimension {
    /// First measurement point reference.
    pub point1: GeometryRef,

    /// Second measurement point reference.
    pub point2: GeometryRef,

    /// Type of measurement (horizontal, vertical, aligned, rotated).
    pub direction: LinearDimensionType,

    /// Offset of dimension line from geometry (positive = up/right).
    pub offset: f64,

    /// Optional text override (replaces computed value).
    pub text_override: Option<String>,

    /// Optional custom style (uses default if None).
    pub style: Option<DimensionStyle>,
}

impl LinearDimension {
    /// Create a new horizontal dimension.
    pub fn horizontal(
        point1: impl Into<GeometryRef>,
        point2: impl Into<GeometryRef>,
        offset: f64,
    ) -> Self {
        Self {
            point1: point1.into(),
            point2: point2.into(),
            direction: LinearDimensionType::Horizontal,
            offset,
            text_override: None,
            style: None,
        }
    }

    /// Create a new vertical dimension.
    pub fn vertical(
        point1: impl Into<GeometryRef>,
        point2: impl Into<GeometryRef>,
        offset: f64,
    ) -> Self {
        Self {
            point1: point1.into(),
            point2: point2.into(),
            direction: LinearDimensionType::Vertical,
            offset,
            text_override: None,
            style: None,
        }
    }

    /// Create a new aligned dimension.
    pub fn aligned(
        point1: impl Into<GeometryRef>,
        point2: impl Into<GeometryRef>,
        offset: f64,
    ) -> Self {
        Self {
            point1: point1.into(),
            point2: point2.into(),
            direction: LinearDimensionType::Aligned,
            offset,
            text_override: None,
            style: None,
        }
    }

    /// Create a new rotated dimension.
    pub fn rotated(
        point1: impl Into<GeometryRef>,
        point2: impl Into<GeometryRef>,
        angle: f64,
        offset: f64,
    ) -> Self {
        Self {
            point1: point1.into(),
            point2: point2.into(),
            direction: LinearDimensionType::Rotated(angle),
            offset,
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
    ///
    /// If a view is provided, geometry references are resolved against it.
    /// Otherwise, only direct point references work.
    pub fn render(
        &self,
        view: Option<&ProjectedView>,
        default_style: &DimensionStyle,
    ) -> Option<RenderedDimension> {
        let style = self.style.as_ref().unwrap_or(default_style);

        // Resolve points
        let p1 = if let Some(v) = view {
            self.point1.resolve(v)?
        } else {
            self.point1.resolve_standalone()?
        };

        let p2 = if let Some(v) = view {
            self.point2.resolve(v)?
        } else {
            self.point2.resolve_standalone()?
        };

        let mut result = RenderedDimension::new();

        // Calculate measurement direction and value
        let (measure_value, dim_angle) = match self.direction {
            LinearDimensionType::Horizontal => {
                let value = (p2.x - p1.x).abs();
                (value, 0.0)
            }
            LinearDimensionType::Vertical => {
                let value = (p2.y - p1.y).abs();
                (value, std::f64::consts::FRAC_PI_2)
            }
            LinearDimensionType::Aligned => {
                let dx = p2.x - p1.x;
                let dy = p2.y - p1.y;
                let value = (dx * dx + dy * dy).sqrt();
                let angle = dy.atan2(dx);
                (value, angle)
            }
            LinearDimensionType::Rotated(angle) => {
                // Project the distance onto the specified angle
                let dx = p2.x - p1.x;
                let dy = p2.y - p1.y;
                let cos_a = angle.cos();
                let sin_a = angle.sin();
                let value = (dx * cos_a + dy * sin_a).abs();
                (value, angle)
            }
        };

        // Calculate perpendicular direction for offset
        let perp_angle = dim_angle + std::f64::consts::FRAC_PI_2;
        let offset_x = self.offset * perp_angle.cos();
        let offset_y = self.offset * perp_angle.sin();

        // Extension line points
        // For horizontal/vertical, project points onto the measurement axis
        let (ext1_start, ext1_end, ext2_start, ext2_end) = match self.direction {
            LinearDimensionType::Horizontal => {
                // Extension lines are vertical
                let dim_y = if self.offset >= 0.0 {
                    p1.y.max(p2.y) + self.offset
                } else {
                    p1.y.min(p2.y) + self.offset
                };
                let ext1_s =
                    Point2D::new(p1.x, p1.y + style.extension_line_gap * self.offset.signum());
                let ext1_e = Point2D::new(
                    p1.x,
                    dim_y + style.extension_line_overshoot * self.offset.signum(),
                );
                let ext2_s =
                    Point2D::new(p2.x, p2.y + style.extension_line_gap * self.offset.signum());
                let ext2_e = Point2D::new(
                    p2.x,
                    dim_y + style.extension_line_overshoot * self.offset.signum(),
                );
                (ext1_s, ext1_e, ext2_s, ext2_e)
            }
            LinearDimensionType::Vertical => {
                // Extension lines are horizontal
                let dim_x = if self.offset >= 0.0 {
                    p1.x.max(p2.x) + self.offset
                } else {
                    p1.x.min(p2.x) + self.offset
                };
                let ext1_s =
                    Point2D::new(p1.x + style.extension_line_gap * self.offset.signum(), p1.y);
                let ext1_e = Point2D::new(
                    dim_x + style.extension_line_overshoot * self.offset.signum(),
                    p1.y,
                );
                let ext2_s =
                    Point2D::new(p2.x + style.extension_line_gap * self.offset.signum(), p2.y);
                let ext2_e = Point2D::new(
                    dim_x + style.extension_line_overshoot * self.offset.signum(),
                    p2.y,
                );
                (ext1_s, ext1_e, ext2_s, ext2_e)
            }
            LinearDimensionType::Aligned | LinearDimensionType::Rotated(_) => {
                // Extension lines perpendicular to dimension line
                let gap = style.extension_line_gap * self.offset.signum();
                let overshoot = style.extension_line_overshoot * self.offset.signum();

                let ext1_s =
                    Point2D::new(p1.x + gap * perp_angle.cos(), p1.y + gap * perp_angle.sin());
                let ext1_e = Point2D::new(
                    p1.x + offset_x + overshoot * perp_angle.cos(),
                    p1.y + offset_y + overshoot * perp_angle.sin(),
                );
                let ext2_s =
                    Point2D::new(p2.x + gap * perp_angle.cos(), p2.y + gap * perp_angle.sin());
                let ext2_e = Point2D::new(
                    p2.x + offset_x + overshoot * perp_angle.cos(),
                    p2.y + offset_y + overshoot * perp_angle.sin(),
                );
                (ext1_s, ext1_e, ext2_s, ext2_e)
            }
        };

        // Add extension lines
        result.add_line(ext1_start, ext1_end);
        result.add_line(ext2_start, ext2_end);

        // Calculate dimension line endpoints
        let (dim_start, dim_end) = match self.direction {
            LinearDimensionType::Horizontal => {
                let dim_y = if self.offset >= 0.0 {
                    p1.y.max(p2.y) + self.offset
                } else {
                    p1.y.min(p2.y) + self.offset
                };
                (Point2D::new(p1.x, dim_y), Point2D::new(p2.x, dim_y))
            }
            LinearDimensionType::Vertical => {
                let dim_x = if self.offset >= 0.0 {
                    p1.x.max(p2.x) + self.offset
                } else {
                    p1.x.min(p2.x) + self.offset
                };
                (Point2D::new(dim_x, p1.y), Point2D::new(dim_x, p2.y))
            }
            LinearDimensionType::Aligned | LinearDimensionType::Rotated(_) => (
                Point2D::new(p1.x + offset_x, p1.y + offset_y),
                Point2D::new(p2.x + offset_x, p2.y + offset_y),
            ),
        };

        // Calculate text position and content
        let text_position = Point2D::new(
            (dim_start.x + dim_end.x) / 2.0,
            (dim_start.y + dim_end.y) / 2.0,
        );

        let text_content = self
            .text_override
            .clone()
            .unwrap_or_else(|| style.format_value(measure_value));

        // Add dimension line (potentially split for InLine text placement)
        let text_width_approx = text_content.len() as f64 * style.text_height * 0.6;
        let arrow_direction_start = dim_angle + std::f64::consts::PI; // Points inward
        let arrow_direction_end = dim_angle; // Points inward

        match style.text_placement {
            TextPlacement::InLine => {
                // Split dimension line around text
                let half_gap = text_width_approx / 2.0 + style.text_height * 0.5;
                let gap_start = Point2D::new(
                    text_position.x - half_gap * dim_angle.cos(),
                    text_position.y - half_gap * dim_angle.sin(),
                );
                let gap_end = Point2D::new(
                    text_position.x + half_gap * dim_angle.cos(),
                    text_position.y + half_gap * dim_angle.sin(),
                );
                result.add_line(dim_start, gap_start);
                result.add_line(gap_end, dim_end);
            }
            _ => {
                // Continuous dimension line
                result.add_line(dim_start, dim_end);
            }
        }

        // Add arrows
        if style.arrow_type != ArrowType::None {
            result.add_arrow(RenderedArrow::new(
                dim_start,
                arrow_direction_start,
                style.arrow_type,
                style.arrow_size,
            ));
            result.add_arrow(RenderedArrow::new(
                dim_end,
                arrow_direction_end,
                style.arrow_type,
                style.arrow_size,
            ));
        }

        // Add text
        let text_offset_y = match style.text_placement {
            TextPlacement::AboveLine => style.text_height * 0.5,
            TextPlacement::InLine => 0.0,
            TextPlacement::AtFirstExtension | TextPlacement::AtSecondExtension => 0.0,
        };

        let final_text_position = match style.text_placement {
            TextPlacement::AboveLine | TextPlacement::InLine => Point2D::new(
                text_position.x + text_offset_y * perp_angle.cos(),
                text_position.y + text_offset_y * perp_angle.sin(),
            ),
            TextPlacement::AtFirstExtension => Point2D::new(
                dim_start.x + style.arrow_size * 2.0 * dim_angle.cos(),
                dim_start.y + style.arrow_size * 2.0 * dim_angle.sin() + text_offset_y,
            ),
            TextPlacement::AtSecondExtension => Point2D::new(
                dim_end.x - style.arrow_size * 2.0 * dim_angle.cos(),
                dim_end.y - style.arrow_size * 2.0 * dim_angle.sin() + text_offset_y,
            ),
        };

        let text_rotation = match self.direction {
            LinearDimensionType::Vertical => std::f64::consts::FRAC_PI_2,
            _ => dim_angle,
        };

        let alignment = match style.text_placement {
            TextPlacement::AboveLine => TextAlignment::BottomCenter,
            TextPlacement::InLine => TextAlignment::MiddleCenter,
            TextPlacement::AtFirstExtension => TextAlignment::MiddleLeft,
            TextPlacement::AtSecondExtension => TextAlignment::MiddleRight,
        };

        result.add_text(
            RenderedText::new(final_text_position, text_content, style.text_height)
                .with_rotation(text_rotation)
                .with_alignment(alignment),
        );

        // Mark as basic dimension if applicable
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
    fn test_horizontal_dimension() {
        let dim =
            LinearDimension::horizontal(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 2 extension lines + 1 dimension line = 3 lines
        assert_eq!(rendered.lines.len(), 3);

        // Should have 2 arrows
        assert_eq!(rendered.arrows.len(), 2);

        // Should have 1 text element
        assert_eq!(rendered.texts.len(), 1);
        assert_eq!(rendered.texts[0].text, "100.00");
    }

    #[test]
    fn test_vertical_dimension() {
        let dim = LinearDimension::vertical(Point2D::new(0.0, 0.0), Point2D::new(0.0, 50.0), 10.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert_eq!(rendered.texts[0].text, "50.00");
    }

    #[test]
    fn test_aligned_dimension() {
        let dim = LinearDimension::aligned(Point2D::new(0.0, 0.0), Point2D::new(30.0, 40.0), 10.0);

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // 3-4-5 triangle: distance should be 50
        assert_eq!(rendered.texts[0].text, "50.00");
    }

    #[test]
    fn test_text_override() {
        let dim =
            LinearDimension::horizontal(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
                .with_text_override("CUSTOM");

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert_eq!(rendered.texts[0].text, "CUSTOM");
    }

    #[test]
    fn test_with_tolerance() {
        let dim =
            LinearDimension::horizontal(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
                .with_style(DimensionStyle::default().with_symmetrical_tolerance(0.05));

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        assert!(rendered.texts[0].text.contains("\u{00B1}0.05"));
    }

    #[test]
    fn test_inline_text_placement() {
        let dim =
            LinearDimension::horizontal(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
                .with_style(DimensionStyle::default().with_text_placement(TextPlacement::InLine));

        let style = DimensionStyle::default();
        let rendered = dim.render(None, &style).unwrap();

        // Should have 2 extension lines + 2 split dimension lines = 4 lines
        assert_eq!(rendered.lines.len(), 4);
    }
}
