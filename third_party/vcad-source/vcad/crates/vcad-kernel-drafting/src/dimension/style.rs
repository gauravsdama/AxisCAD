//! Dimension styling configuration.
//!
//! Defines how dimensions are displayed, including text height, arrow styles,
//! extension lines, and tolerance formatting.

use serde::{Deserialize, Serialize};

/// Style configuration for dimension annotations.
///
/// Controls the visual appearance of dimension elements including text,
/// arrows, extension lines, and tolerance display.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DimensionStyle {
    /// Height of dimension text in drawing units (default: 2.5mm).
    pub text_height: f64,

    /// Size of dimension arrows in drawing units (default: 2.0mm).
    pub arrow_size: f64,

    /// Gap between geometry and start of extension line (default: 1.0mm).
    pub extension_line_gap: f64,

    /// How far extension lines extend beyond the dimension line (default: 1.5mm).
    pub extension_line_overshoot: f64,

    /// Offset of dimension line from the geometry (default: 10.0mm).
    pub dimension_line_offset: f64,

    /// Type of arrow to use at dimension line ends.
    pub arrow_type: ArrowType,

    /// Number of decimal places for dimension values (default: 2).
    pub precision: u8,

    /// Where to place dimension text relative to the dimension line.
    pub text_placement: TextPlacement,

    /// Optional suffix to append to dimension values (e.g., "mm").
    pub units_suffix: Option<String>,

    /// How tolerances are displayed.
    pub tolerance_mode: ToleranceMode,

    /// Upper tolerance value (used with Symmetrical, Deviation, Limits modes).
    pub tolerance_upper: Option<f64>,

    /// Lower tolerance value (used with Deviation, Limits modes).
    pub tolerance_lower: Option<f64>,
}

impl Default for DimensionStyle {
    fn default() -> Self {
        Self {
            text_height: 2.5,
            arrow_size: 2.0,
            extension_line_gap: 1.0,
            extension_line_overshoot: 1.5,
            dimension_line_offset: 10.0,
            arrow_type: ArrowType::ClosedFilled,
            precision: 2,
            text_placement: TextPlacement::AboveLine,
            units_suffix: None,
            tolerance_mode: ToleranceMode::None,
            tolerance_upper: None,
            tolerance_lower: None,
        }
    }
}

impl DimensionStyle {
    /// Create a new dimension style with default settings.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the text height.
    pub fn with_text_height(mut self, height: f64) -> Self {
        self.text_height = height;
        self
    }

    /// Set the arrow size.
    pub fn with_arrow_size(mut self, size: f64) -> Self {
        self.arrow_size = size;
        self
    }

    /// Set the arrow type.
    pub fn with_arrow_type(mut self, arrow_type: ArrowType) -> Self {
        self.arrow_type = arrow_type;
        self
    }

    /// Set the precision (decimal places).
    pub fn with_precision(mut self, precision: u8) -> Self {
        self.precision = precision;
        self
    }

    /// Set a symmetrical tolerance (e.g., ±0.05).
    pub fn with_symmetrical_tolerance(mut self, tolerance: f64) -> Self {
        self.tolerance_mode = ToleranceMode::Symmetrical;
        self.tolerance_upper = Some(tolerance);
        self.tolerance_lower = Some(tolerance);
        self
    }

    /// Set a deviation tolerance (e.g., +0.05/-0.02).
    pub fn with_deviation_tolerance(mut self, upper: f64, lower: f64) -> Self {
        self.tolerance_mode = ToleranceMode::Deviation;
        self.tolerance_upper = Some(upper);
        self.tolerance_lower = Some(lower);
        self
    }

    /// Set limits tolerance (shows max/min values).
    pub fn with_limits_tolerance(mut self, upper: f64, lower: f64) -> Self {
        self.tolerance_mode = ToleranceMode::Limits;
        self.tolerance_upper = Some(upper);
        self.tolerance_lower = Some(lower);
        self
    }

    /// Mark as a basic dimension (enclosed in a box).
    pub fn as_basic(mut self) -> Self {
        self.tolerance_mode = ToleranceMode::Basic;
        self
    }

    /// Set units suffix (e.g., "mm", "in").
    pub fn with_units_suffix(mut self, suffix: impl Into<String>) -> Self {
        self.units_suffix = Some(suffix.into());
        self
    }

    /// Set text placement.
    pub fn with_text_placement(mut self, placement: TextPlacement) -> Self {
        self.text_placement = placement;
        self
    }

    /// Format a dimension value according to this style.
    pub fn format_value(&self, value: f64) -> String {
        let formatted = format!("{:.prec$}", value, prec = self.precision as usize);

        let with_suffix = match &self.units_suffix {
            Some(suffix) => format!("{}{}", formatted, suffix),
            None => formatted,
        };

        match self.tolerance_mode {
            ToleranceMode::None => with_suffix,
            ToleranceMode::Symmetrical => {
                if let Some(tol) = self.tolerance_upper {
                    format!(
                        "{} \u{00B1}{:.prec$}",
                        with_suffix,
                        tol,
                        prec = self.precision as usize
                    )
                } else {
                    with_suffix
                }
            }
            ToleranceMode::Deviation => {
                let upper = self.tolerance_upper.unwrap_or(0.0);
                let lower = self.tolerance_lower.unwrap_or(0.0);
                format!(
                    "{} +{:.prec$}/-{:.prec$}",
                    with_suffix,
                    upper,
                    lower,
                    prec = self.precision as usize
                )
            }
            ToleranceMode::Limits => {
                let upper = self.tolerance_upper.unwrap_or(0.0);
                let lower = self.tolerance_lower.unwrap_or(0.0);
                format!(
                    "{:.prec$}/{:.prec$}",
                    value + upper,
                    value - lower,
                    prec = self.precision as usize
                )
            }
            ToleranceMode::Basic => {
                // Basic dimensions are shown in a box (handled by renderer)
                with_suffix
            }
        }
    }
}

/// Arrow type for dimension line terminators.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum ArrowType {
    /// Solid filled arrowhead (most common).
    #[default]
    ClosedFilled,

    /// Closed arrowhead outline (not filled).
    ClosedBlank,

    /// Open arrowhead (two lines forming a V).
    Open,

    /// Tick mark (45-degree slash).
    Tick,

    /// Dot (filled circle).
    Dot,

    /// No terminator.
    None,
}

/// Placement of dimension text relative to the dimension line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum TextPlacement {
    /// Text centered above the dimension line.
    #[default]
    AboveLine,

    /// Text centered in a gap in the dimension line.
    InLine,

    /// Text near the first extension line.
    AtFirstExtension,

    /// Text near the second extension line.
    AtSecondExtension,
}

/// Tolerance display mode for dimensions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum ToleranceMode {
    /// No tolerance shown.
    #[default]
    None,

    /// Symmetrical tolerance (e.g., 50.00 ±0.05).
    Symmetrical,

    /// Deviation tolerance (e.g., 50.00 +0.05/-0.02).
    Deviation,

    /// Limits (shows max and min values, e.g., 50.05/49.98).
    Limits,

    /// Basic dimension (theoretically exact, shown in a box).
    Basic,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_style() {
        let style = DimensionStyle::default();
        assert!((style.text_height - 2.5).abs() < 1e-10);
        assert!((style.arrow_size - 2.0).abs() < 1e-10);
        assert_eq!(style.precision, 2);
        assert_eq!(style.arrow_type, ArrowType::ClosedFilled);
    }

    #[test]
    fn test_format_value_no_tolerance() {
        let style = DimensionStyle::default();
        assert_eq!(style.format_value(100.0), "100.00");
        assert_eq!(style.format_value(50.125), "50.12"); // Rounds
    }

    #[test]
    fn test_format_value_with_suffix() {
        let style = DimensionStyle::default().with_units_suffix("mm");
        assert_eq!(style.format_value(100.0), "100.00mm");
    }

    #[test]
    fn test_format_value_symmetrical() {
        let style = DimensionStyle::default().with_symmetrical_tolerance(0.05);
        assert_eq!(style.format_value(50.0), "50.00 \u{00B1}0.05");
    }

    #[test]
    fn test_format_value_deviation() {
        let style = DimensionStyle::default().with_deviation_tolerance(0.05, 0.02);
        assert_eq!(style.format_value(50.0), "50.00 +0.05/-0.02");
    }

    #[test]
    fn test_format_value_limits() {
        let style = DimensionStyle::default().with_limits_tolerance(0.05, 0.02);
        assert_eq!(style.format_value(50.0), "50.05/49.98");
    }

    #[test]
    fn test_builder_pattern() {
        let style = DimensionStyle::new()
            .with_text_height(3.0)
            .with_arrow_size(2.5)
            .with_precision(3)
            .with_arrow_type(ArrowType::Open);

        assert!((style.text_height - 3.0).abs() < 1e-10);
        assert!((style.arrow_size - 2.5).abs() < 1e-10);
        assert_eq!(style.precision, 3);
        assert_eq!(style.arrow_type, ArrowType::Open);
    }
}
