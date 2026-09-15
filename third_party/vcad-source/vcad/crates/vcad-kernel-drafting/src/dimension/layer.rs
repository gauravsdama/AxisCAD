//! Annotation layer container.
//!
//! Provides a container for all dimension annotations in a drawing,
//! with builder methods for common dimension types.

use serde::{Deserialize, Serialize};

use super::angular::AngularDimension;
use super::gdt::{DatumFeatureSymbol, FeatureControlFrame, GdtSymbol};
use super::geometry_ref::GeometryRef;
use super::linear::LinearDimension;
use super::ordinate::OrdinateDimension;
use super::radial::RadialDimension;
use super::render::RenderedDimension;
use super::style::DimensionStyle;
use crate::types::{Point2D, ProjectedView};

/// Container for all dimension annotations in a drawing.
///
/// Collects linear, angular, radial, ordinate dimensions, and GD&T
/// annotations, then renders them to graphical primitives.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AnnotationLayer {
    /// Linear dimensions (horizontal, vertical, aligned, rotated).
    pub linear_dimensions: Vec<LinearDimension>,

    /// Angular dimensions.
    pub angular_dimensions: Vec<AngularDimension>,

    /// Radial dimensions (radius and diameter).
    pub radial_dimensions: Vec<RadialDimension>,

    /// Ordinate dimensions.
    pub ordinate_dimensions: Vec<OrdinateDimension>,

    /// Feature control frames (GD&T).
    pub feature_control_frames: Vec<FeatureControlFrame>,

    /// Datum feature symbols.
    pub datum_symbols: Vec<DatumFeatureSymbol>,

    /// Default style for all dimensions.
    pub default_style: DimensionStyle,
}

impl AnnotationLayer {
    /// Create a new empty annotation layer with default style.
    pub fn new() -> Self {
        Self::default()
    }

    /// Create an annotation layer with a custom default style.
    pub fn with_style(style: DimensionStyle) -> Self {
        Self {
            default_style: style,
            ..Default::default()
        }
    }

    // ========================================================================
    // Linear dimension builders
    // ========================================================================

    /// Add a horizontal dimension between two points.
    pub fn add_horizontal_dimension(
        &mut self,
        p1: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        offset: f64,
    ) -> &mut Self {
        self.linear_dimensions
            .push(LinearDimension::horizontal(p1, p2, offset));
        self
    }

    /// Add a vertical dimension between two points.
    pub fn add_vertical_dimension(
        &mut self,
        p1: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        offset: f64,
    ) -> &mut Self {
        self.linear_dimensions
            .push(LinearDimension::vertical(p1, p2, offset));
        self
    }

    /// Add an aligned dimension between two points.
    pub fn add_aligned_dimension(
        &mut self,
        p1: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        offset: f64,
    ) -> &mut Self {
        self.linear_dimensions
            .push(LinearDimension::aligned(p1, p2, offset));
        self
    }

    /// Add a rotated dimension.
    pub fn add_rotated_dimension(
        &mut self,
        p1: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        angle: f64,
        offset: f64,
    ) -> &mut Self {
        self.linear_dimensions
            .push(LinearDimension::rotated(p1, p2, angle, offset));
        self
    }

    /// Add a linear dimension with full control.
    pub fn add_linear_dimension(&mut self, dim: LinearDimension) -> &mut Self {
        self.linear_dimensions.push(dim);
        self
    }

    // ========================================================================
    // Angular dimension builders
    // ========================================================================

    /// Add an angular dimension from three points (vertex is middle).
    pub fn add_angle_dimension(
        &mut self,
        p1: impl Into<GeometryRef>,
        vertex: impl Into<GeometryRef>,
        p2: impl Into<GeometryRef>,
        arc_radius: f64,
    ) -> &mut Self {
        self.angular_dimensions
            .push(AngularDimension::from_three_points(
                p1, vertex, p2, arc_radius,
            ));
        self
    }

    /// Add an angular dimension with full control.
    pub fn add_angular_dimension(&mut self, dim: AngularDimension) -> &mut Self {
        self.angular_dimensions.push(dim);
        self
    }

    // ========================================================================
    // Radial dimension builders
    // ========================================================================

    /// Add a radius dimension.
    pub fn add_radius_dimension(
        &mut self,
        circle_ref: impl Into<GeometryRef>,
        leader_angle: f64,
    ) -> &mut Self {
        self.radial_dimensions
            .push(RadialDimension::radius(circle_ref, leader_angle));
        self
    }

    /// Add a diameter dimension.
    pub fn add_diameter_dimension(
        &mut self,
        circle_ref: impl Into<GeometryRef>,
        leader_angle: f64,
    ) -> &mut Self {
        self.radial_dimensions
            .push(RadialDimension::diameter(circle_ref, leader_angle));
        self
    }

    /// Add a radial dimension with full control.
    pub fn add_radial_dimension(&mut self, dim: RadialDimension) -> &mut Self {
        self.radial_dimensions.push(dim);
        self
    }

    // ========================================================================
    // Ordinate dimension builders
    // ========================================================================

    /// Add an X-ordinate dimension.
    pub fn add_x_ordinate(
        &mut self,
        point: impl Into<GeometryRef>,
        datum: Point2D,
        leader_length: f64,
    ) -> &mut Self {
        self.ordinate_dimensions
            .push(OrdinateDimension::x_ordinate(point, datum, leader_length));
        self
    }

    /// Add a Y-ordinate dimension.
    pub fn add_y_ordinate(
        &mut self,
        point: impl Into<GeometryRef>,
        datum: Point2D,
        leader_length: f64,
    ) -> &mut Self {
        self.ordinate_dimensions
            .push(OrdinateDimension::y_ordinate(point, datum, leader_length));
        self
    }

    /// Add an ordinate dimension with full control.
    pub fn add_ordinate_dimension(&mut self, dim: OrdinateDimension) -> &mut Self {
        self.ordinate_dimensions.push(dim);
        self
    }

    // ========================================================================
    // GD&T builders
    // ========================================================================

    /// Add a position tolerance.
    pub fn add_position_tolerance(
        &mut self,
        tolerance: f64,
        position: Point2D,
        datum_a: char,
    ) -> &mut Self {
        self.feature_control_frames.push(
            FeatureControlFrame::new(GdtSymbol::Position, tolerance, position)
                .with_diameter_tolerance()
                .with_datum_a(datum_a),
        );
        self
    }

    /// Add a flatness tolerance.
    pub fn add_flatness_tolerance(&mut self, tolerance: f64, position: Point2D) -> &mut Self {
        self.feature_control_frames.push(FeatureControlFrame::new(
            GdtSymbol::Flatness,
            tolerance,
            position,
        ));
        self
    }

    /// Add a perpendicularity tolerance.
    pub fn add_perpendicularity_tolerance(
        &mut self,
        tolerance: f64,
        position: Point2D,
        datum: char,
    ) -> &mut Self {
        self.feature_control_frames.push(
            FeatureControlFrame::new(GdtSymbol::Perpendicularity, tolerance, position)
                .with_datum_a(datum),
        );
        self
    }

    /// Add a feature control frame with full control.
    pub fn add_feature_control_frame(&mut self, fcf: FeatureControlFrame) -> &mut Self {
        self.feature_control_frames.push(fcf);
        self
    }

    /// Add a datum feature symbol.
    pub fn add_datum_symbol(&mut self, letter: char, position: Point2D) -> &mut Self {
        self.datum_symbols
            .push(DatumFeatureSymbol::new(letter, position));
        self
    }

    /// Add a datum feature symbol with leader.
    pub fn add_datum_symbol_with_leader(
        &mut self,
        letter: char,
        position: Point2D,
        leader_to: impl Into<GeometryRef>,
    ) -> &mut Self {
        self.datum_symbols
            .push(DatumFeatureSymbol::new(letter, position).with_leader(leader_to));
        self
    }

    // ========================================================================
    // Rendering
    // ========================================================================

    /// Render all annotations to graphical primitives.
    ///
    /// If a view is provided, geometry references are resolved against it.
    pub fn render_all(&self, view: Option<&ProjectedView>) -> Vec<RenderedDimension> {
        let mut results = Vec::new();

        // Render linear dimensions
        for dim in &self.linear_dimensions {
            if let Some(rendered) = dim.render(view, &self.default_style) {
                results.push(rendered);
            }
        }

        // Render angular dimensions
        for dim in &self.angular_dimensions {
            if let Some(rendered) = dim.render(view, &self.default_style) {
                results.push(rendered);
            }
        }

        // Render radial dimensions
        for dim in &self.radial_dimensions {
            if let Some(rendered) = dim.render(view, &self.default_style) {
                results.push(rendered);
            }
        }

        // Render ordinate dimensions
        for dim in &self.ordinate_dimensions {
            if let Some(rendered) = dim.render(view, &self.default_style) {
                results.push(rendered);
            }
        }

        // Render feature control frames
        for fcf in &self.feature_control_frames {
            results.push(fcf.render(view, &self.default_style));
        }

        // Render datum symbols
        for symbol in &self.datum_symbols {
            results.push(symbol.render(view, &self.default_style));
        }

        results
    }

    /// Total number of annotations in the layer.
    pub fn annotation_count(&self) -> usize {
        self.linear_dimensions.len()
            + self.angular_dimensions.len()
            + self.radial_dimensions.len()
            + self.ordinate_dimensions.len()
            + self.feature_control_frames.len()
            + self.datum_symbols.len()
    }

    /// Check if the layer has any annotations.
    pub fn is_empty(&self) -> bool {
        self.annotation_count() == 0
    }

    /// Clear all annotations.
    pub fn clear(&mut self) {
        self.linear_dimensions.clear();
        self.angular_dimensions.clear();
        self.radial_dimensions.clear();
        self.ordinate_dimensions.clear();
        self.feature_control_frames.clear();
        self.datum_symbols.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_layer() {
        let layer = AnnotationLayer::new();
        assert!(layer.is_empty());
        assert_eq!(layer.annotation_count(), 0);
    }

    #[test]
    fn test_add_dimensions() {
        let mut layer = AnnotationLayer::new();

        layer
            .add_horizontal_dimension(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
            .add_vertical_dimension(Point2D::new(0.0, 0.0), Point2D::new(0.0, 50.0), 10.0);

        assert_eq!(layer.linear_dimensions.len(), 2);
        assert_eq!(layer.annotation_count(), 2);
    }

    #[test]
    fn test_render_all() {
        let mut layer = AnnotationLayer::new();

        layer
            .add_horizontal_dimension(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
            .add_radius_dimension(
                GeometryRef::Circle {
                    center: Point2D::new(50.0, 50.0),
                    radius: 25.0,
                },
                0.0,
            );

        let rendered = layer.render_all(None);
        assert_eq!(rendered.len(), 2);
    }

    #[test]
    fn test_gdt_annotations() {
        let mut layer = AnnotationLayer::new();

        layer
            .add_position_tolerance(0.05, Point2D::new(100.0, 50.0), 'A')
            .add_flatness_tolerance(0.01, Point2D::new(100.0, 70.0))
            .add_datum_symbol('A', Point2D::new(50.0, 0.0));

        assert_eq!(layer.feature_control_frames.len(), 2);
        assert_eq!(layer.datum_symbols.len(), 1);
        assert_eq!(layer.annotation_count(), 3);
    }

    #[test]
    fn test_clear() {
        let mut layer = AnnotationLayer::new();

        layer
            .add_horizontal_dimension(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0)
            .add_flatness_tolerance(0.01, Point2D::new(100.0, 70.0));

        assert!(!layer.is_empty());

        layer.clear();
        assert!(layer.is_empty());
    }

    #[test]
    fn test_with_custom_style() {
        let style = DimensionStyle::new().with_precision(3);
        let mut layer = AnnotationLayer::with_style(style);

        layer.add_horizontal_dimension(Point2D::new(0.0, 0.0), Point2D::new(100.0, 0.0), 15.0);

        let rendered = layer.render_all(None);
        assert_eq!(rendered[0].texts[0].text, "100.000");
    }
}
