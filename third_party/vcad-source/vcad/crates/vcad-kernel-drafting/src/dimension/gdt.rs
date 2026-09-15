//! Geometric Dimensioning and Tolerancing (GD&T) types.
//!
//! Provides feature control frames, datum symbols, and GD&T symbols
//! following ASME Y14.5-2018 standards.

use std::fmt;

use serde::{Deserialize, Serialize};

use super::geometry_ref::GeometryRef;
use super::render::{RenderedDimension, RenderedText, TextAlignment};
use super::style::DimensionStyle;
use crate::types::{Point2D, ProjectedView};

/// GD&T characteristic symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GdtSymbol {
    // Form tolerances (no datum required)
    /// Straightness (\u{23E4}) - controls straightness of a line or axis.
    Straightness,
    /// Flatness (\u{23E5}) - controls flatness of a surface.
    Flatness,
    /// Circularity (\u{25CB}) - controls roundness of a cross-section.
    Circularity,
    /// Cylindricity (\u{232D}) - controls cylindrical form.
    Cylindricity,

    // Profile tolerances
    /// Profile of a line (\u{2312}) - controls 2D profile.
    ProfileOfLine,
    /// Profile of a surface (\u{2313}) - controls 3D profile.
    ProfileOfSurface,

    // Orientation tolerances (require datum)
    /// Angularity (\u{2220}) - controls angle relative to datum.
    Angularity,
    /// Perpendicularity (\u{27C2}) - controls 90° relationship.
    Perpendicularity,
    /// Parallelism (\u{2225}) - controls parallel relationship.
    Parallelism,

    // Location tolerances (require datum)
    /// Position (\u{2316}) - controls location relative to datums.
    Position,
    /// Concentricity (\u{25CE}) - controls center point alignment.
    Concentricity,
    /// Symmetry (\u{232F}) - controls symmetrical relationship.
    Symmetry,

    // Runout tolerances (require datum)
    /// Circular runout (\u{2197}) - controls circular cross-section variation.
    CircularRunout,
    /// Total runout (\u{2197}\u{2197}) - controls total surface variation.
    TotalRunout,
}

impl GdtSymbol {
    /// Get the Unicode character for this symbol.
    pub fn unicode_char(&self) -> &'static str {
        match self {
            GdtSymbol::Straightness => "\u{23E4}",
            GdtSymbol::Flatness => "\u{23E5}",
            GdtSymbol::Circularity => "\u{25CB}",
            GdtSymbol::Cylindricity => "\u{232D}",
            GdtSymbol::ProfileOfLine => "\u{2312}",
            GdtSymbol::ProfileOfSurface => "\u{2313}",
            GdtSymbol::Angularity => "\u{2220}",
            GdtSymbol::Perpendicularity => "\u{27C2}",
            GdtSymbol::Parallelism => "\u{2225}",
            GdtSymbol::Position => "\u{2316}",
            GdtSymbol::Concentricity => "\u{25CE}",
            GdtSymbol::Symmetry => "\u{232F}",
            GdtSymbol::CircularRunout => "\u{2197}",
            GdtSymbol::TotalRunout => "\u{2197}\u{2197}",
        }
    }

    /// Get text representation for DXF export (using simple ASCII where Unicode isn't supported).
    pub fn dxf_text(&self) -> &'static str {
        match self {
            GdtSymbol::Straightness => "%%c-",     // Straightness
            GdtSymbol::Flatness => "%%cF",         // Flatness (custom)
            GdtSymbol::Circularity => "%%c",       // Circle
            GdtSymbol::Cylindricity => "%%cC",     // Cylindricity
            GdtSymbol::ProfileOfLine => "%%cL",    // Profile line
            GdtSymbol::ProfileOfSurface => "%%cS", // Profile surface
            GdtSymbol::Angularity => "%%cA",       // Angularity
            GdtSymbol::Perpendicularity => "%%cP", // Perpendicularity
            GdtSymbol::Parallelism => "//",        // Parallelism
            GdtSymbol::Position => "%%cPOS",       // Position
            GdtSymbol::Concentricity => "(O)",     // Concentricity
            GdtSymbol::Symmetry => "=",            // Symmetry
            GdtSymbol::CircularRunout => "%%cR",   // Circular runout
            GdtSymbol::TotalRunout => "%%cRR",     // Total runout
        }
    }

    /// Check if this symbol requires a datum reference.
    pub fn requires_datum(&self) -> bool {
        matches!(
            self,
            GdtSymbol::Angularity
                | GdtSymbol::Perpendicularity
                | GdtSymbol::Parallelism
                | GdtSymbol::Position
                | GdtSymbol::Concentricity
                | GdtSymbol::Symmetry
                | GdtSymbol::CircularRunout
                | GdtSymbol::TotalRunout
        )
    }
}

/// Material condition modifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MaterialCondition {
    /// Maximum Material Condition (M) - largest shaft, smallest hole.
    MMC,
    /// Least Material Condition (L) - smallest shaft, largest hole.
    LMC,
    /// Regardless of Feature Size (implicit, no symbol).
    RFS,
}

impl MaterialCondition {
    /// Get the Unicode symbol for this condition.
    pub fn unicode_char(&self) -> &'static str {
        match self {
            MaterialCondition::MMC => "\u{24C2}", // Circled M
            MaterialCondition::LMC => "\u{24C1}", // Circled L
            MaterialCondition::RFS => "",         // No symbol (implicit)
        }
    }

    /// Get text for DXF export.
    pub fn dxf_text(&self) -> &'static str {
        match self {
            MaterialCondition::MMC => "(M)",
            MaterialCondition::LMC => "(L)",
            MaterialCondition::RFS => "",
        }
    }
}

/// Reference to a datum feature.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatumRef {
    /// Datum letter (A, B, C, etc.).
    pub letter: char,
    /// Optional material condition modifier.
    pub material_condition: Option<MaterialCondition>,
}

impl DatumRef {
    /// Create a simple datum reference.
    pub fn new(letter: char) -> Self {
        Self {
            letter: letter.to_ascii_uppercase(),
            material_condition: None,
        }
    }

    /// Create a datum reference with material condition.
    pub fn with_modifier(letter: char, condition: MaterialCondition) -> Self {
        Self {
            letter: letter.to_ascii_uppercase(),
            material_condition: Some(condition),
        }
    }
}

impl fmt::Display for DatumRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.material_condition {
            Some(mc) => write!(f, "{}{}", self.letter, mc.unicode_char()),
            None => write!(f, "{}", self.letter),
        }
    }
}

/// A datum feature symbol (triangle with letter).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatumFeatureSymbol {
    /// Datum letter (A, B, C, etc.).
    pub letter: char,
    /// Position of the symbol.
    pub position: Point2D,
    /// Optional leader line to geometry.
    pub leader_to: Option<GeometryRef>,
}

impl DatumFeatureSymbol {
    /// Create a new datum feature symbol.
    pub fn new(letter: char, position: Point2D) -> Self {
        Self {
            letter: letter.to_ascii_uppercase(),
            position,
            leader_to: None,
        }
    }

    /// Add a leader to geometry.
    pub fn with_leader(mut self, target: impl Into<GeometryRef>) -> Self {
        self.leader_to = Some(target.into());
        self
    }

    /// Render the datum symbol.
    pub fn render(
        &self,
        view: Option<&ProjectedView>,
        default_style: &DimensionStyle,
    ) -> RenderedDimension {
        let _ = view; // May be used for leader resolution
        let mut result = RenderedDimension::new();

        // Draw filled triangle
        let height = default_style.text_height * 2.0;
        let half_base = height * 0.6;

        let p1 = Point2D::new(self.position.x, self.position.y + height / 2.0); // Top
        let p2 = Point2D::new(self.position.x - half_base, self.position.y - height / 2.0); // Bottom left
        let p3 = Point2D::new(self.position.x + half_base, self.position.y - height / 2.0); // Bottom right

        // Triangle outline
        result.add_line(p1, p2);
        result.add_line(p2, p3);
        result.add_line(p3, p1);

        // Datum letter inside
        result.add_text(
            RenderedText::new(
                Point2D::new(self.position.x, self.position.y - height * 0.1),
                self.letter.to_string(),
                default_style.text_height,
            )
            .with_alignment(TextAlignment::MiddleCenter),
        );

        // Leader line if specified
        if let Some(ref target) = self.leader_to {
            if let Some(target_point) = target.resolve_standalone() {
                result.add_line(self.position, target_point);
            } else if let Some(v) = view {
                if let Some(target_point) = target.resolve(v) {
                    result.add_line(self.position, target_point);
                }
            }
        }

        result
    }
}

/// A feature control frame (the rectangular GD&T callout).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeatureControlFrame {
    /// The GD&T symbol (position, flatness, etc.).
    pub symbol: GdtSymbol,
    /// Tolerance value.
    pub tolerance: f64,
    /// Whether the tolerance zone is a diameter (cylindrical).
    pub tolerance_is_diameter: bool,
    /// Material condition modifier for the tolerance.
    pub material_condition: Option<MaterialCondition>,
    /// Primary datum reference.
    pub datum_a: Option<DatumRef>,
    /// Secondary datum reference.
    pub datum_b: Option<DatumRef>,
    /// Tertiary datum reference.
    pub datum_c: Option<DatumRef>,
    /// Position of the frame.
    pub position: Point2D,
    /// Optional leader line to geometry.
    pub leader_to: Option<GeometryRef>,
}

impl FeatureControlFrame {
    /// Create a new feature control frame.
    pub fn new(symbol: GdtSymbol, tolerance: f64, position: Point2D) -> Self {
        Self {
            symbol,
            tolerance,
            tolerance_is_diameter: false,
            material_condition: None,
            datum_a: None,
            datum_b: None,
            datum_c: None,
            position,
            leader_to: None,
        }
    }

    /// Set the tolerance as a diameter zone.
    pub fn with_diameter_tolerance(mut self) -> Self {
        self.tolerance_is_diameter = true;
        self
    }

    /// Set the material condition.
    pub fn with_material_condition(mut self, condition: MaterialCondition) -> Self {
        self.material_condition = Some(condition);
        self
    }

    /// Set the primary datum.
    pub fn with_datum_a(mut self, letter: char) -> Self {
        self.datum_a = Some(DatumRef::new(letter));
        self
    }

    /// Set the primary datum with material condition.
    pub fn with_datum_a_modifier(mut self, letter: char, condition: MaterialCondition) -> Self {
        self.datum_a = Some(DatumRef::with_modifier(letter, condition));
        self
    }

    /// Set the secondary datum.
    pub fn with_datum_b(mut self, letter: char) -> Self {
        self.datum_b = Some(DatumRef::new(letter));
        self
    }

    /// Set the tertiary datum.
    pub fn with_datum_c(mut self, letter: char) -> Self {
        self.datum_c = Some(DatumRef::new(letter));
        self
    }

    /// Add a leader to geometry.
    pub fn with_leader(mut self, target: impl Into<GeometryRef>) -> Self {
        self.leader_to = Some(target.into());
        self
    }

    /// Render the feature control frame.
    pub fn render(
        &self,
        view: Option<&ProjectedView>,
        default_style: &DimensionStyle,
    ) -> RenderedDimension {
        let mut result = RenderedDimension::new();

        let cell_height = default_style.text_height * 2.0;
        let cell_width = default_style.text_height * 2.5;

        // Calculate total width based on content
        let mut total_width = cell_width; // Symbol cell
        total_width += cell_width * 1.5; // Tolerance cell

        if self.datum_a.is_some() {
            total_width += cell_width;
        }
        if self.datum_b.is_some() {
            total_width += cell_width;
        }
        if self.datum_c.is_some() {
            total_width += cell_width;
        }

        // Draw outer frame
        let x1 = self.position.x - total_width / 2.0;
        let x2 = self.position.x + total_width / 2.0;
        let y1 = self.position.y - cell_height / 2.0;
        let y2 = self.position.y + cell_height / 2.0;

        // Outer rectangle
        result.add_line(Point2D::new(x1, y1), Point2D::new(x2, y1));
        result.add_line(Point2D::new(x2, y1), Point2D::new(x2, y2));
        result.add_line(Point2D::new(x2, y2), Point2D::new(x1, y2));
        result.add_line(Point2D::new(x1, y2), Point2D::new(x1, y1));

        // Cell dividers and content
        let mut x = x1;

        // Symbol cell
        let symbol_center = Point2D::new(x + cell_width / 2.0, self.position.y);
        result.add_text(
            RenderedText::new(
                symbol_center,
                self.symbol.unicode_char(),
                default_style.text_height,
            )
            .with_alignment(TextAlignment::MiddleCenter),
        );
        x += cell_width;

        // Divider
        result.add_line(Point2D::new(x, y1), Point2D::new(x, y2));

        // Tolerance cell
        let tol_width = cell_width * 1.5;
        let mut tol_text = String::new();
        if self.tolerance_is_diameter {
            tol_text.push('\u{2300}'); // Diameter symbol
        }
        tol_text.push_str(&format!("{:.2}", self.tolerance));
        if let Some(mc) = self.material_condition {
            tol_text.push_str(mc.unicode_char());
        }

        let tol_center = Point2D::new(x + tol_width / 2.0, self.position.y);
        result.add_text(
            RenderedText::new(tol_center, tol_text, default_style.text_height * 0.8)
                .with_alignment(TextAlignment::MiddleCenter),
        );
        x += tol_width;

        // Datum cells
        let datums: [&Option<DatumRef>; 3] = [&self.datum_a, &self.datum_b, &self.datum_c];
        for datum in datums.iter().filter_map(|d| d.as_ref()) {
            // Divider
            result.add_line(Point2D::new(x, y1), Point2D::new(x, y2));

            let datum_center = Point2D::new(x + cell_width / 2.0, self.position.y);
            result.add_text(
                RenderedText::new(
                    datum_center,
                    datum.to_string(),
                    default_style.text_height * 0.8,
                )
                .with_alignment(TextAlignment::MiddleCenter),
            );
            x += cell_width;
        }

        // Leader line if specified
        if let Some(ref target) = self.leader_to {
            let frame_bottom = Point2D::new(self.position.x, y1);
            if let Some(target_point) = target.resolve_standalone() {
                result.add_line(frame_bottom, target_point);
            } else if let Some(v) = view {
                if let Some(target_point) = target.resolve(v) {
                    result.add_line(frame_bottom, target_point);
                }
            }
        }

        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gdt_symbol_unicode() {
        assert_eq!(GdtSymbol::Position.unicode_char(), "\u{2316}");
        assert_eq!(GdtSymbol::Flatness.unicode_char(), "\u{23E5}");
    }

    #[test]
    fn test_requires_datum() {
        assert!(GdtSymbol::Position.requires_datum());
        assert!(GdtSymbol::Perpendicularity.requires_datum());
        assert!(!GdtSymbol::Flatness.requires_datum());
        assert!(!GdtSymbol::Circularity.requires_datum());
    }

    #[test]
    fn test_datum_ref() {
        let datum = DatumRef::new('a');
        assert_eq!(datum.letter, 'A');
        assert_eq!(datum.to_string(), "A");

        let datum_with_mod = DatumRef::with_modifier('b', MaterialCondition::MMC);
        assert!(datum_with_mod.to_string().contains('B'));
    }

    #[test]
    fn test_feature_control_frame() {
        let fcf = FeatureControlFrame::new(GdtSymbol::Position, 0.05, Point2D::new(50.0, 50.0))
            .with_diameter_tolerance()
            .with_material_condition(MaterialCondition::MMC)
            .with_datum_a('A')
            .with_datum_b('B');

        let style = DimensionStyle::default();
        let rendered = fcf.render(None, &style);

        // Should have frame lines
        assert!(!rendered.lines.is_empty());

        // Should have text elements (symbol, tolerance, datums)
        assert!(!rendered.texts.is_empty());
    }

    #[test]
    fn test_datum_feature_symbol() {
        let symbol = DatumFeatureSymbol::new('A', Point2D::new(100.0, 100.0));

        let style = DimensionStyle::default();
        let rendered = symbol.render(None, &style);

        // Should have triangle (3 lines)
        assert_eq!(rendered.lines.len(), 3);

        // Should have datum letter
        assert_eq!(rendered.texts.len(), 1);
        assert_eq!(rendered.texts[0].text, "A");
    }
}
