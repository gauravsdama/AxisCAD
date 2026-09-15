//! Example demonstrating the dimension annotation system.
//!
//! Run with: cargo run -p vcad-kernel-drafting --example dimension_test

use vcad_kernel_drafting::dimension::{
    AnnotationLayer, DimensionStyle, FeatureControlFrame, GdtSymbol, GeometryRef, MaterialCondition,
};
use vcad_kernel_drafting::Point2D;

fn main() {
    println!("=== Dimension Annotation System Demo ===\n");

    // Create an annotation layer with default style
    let mut annotations = AnnotationLayer::new();

    // Define a simple bracket profile
    let p1 = Point2D::new(0.0, 0.0);
    let p2 = Point2D::new(100.0, 0.0);
    let p3 = Point2D::new(100.0, 50.0);
    let _p4 = Point2D::new(0.0, 50.0);
    let hole_center = Point2D::new(50.0, 25.0);

    // Add linear dimensions
    println!("Adding linear dimensions...");
    annotations
        .add_horizontal_dimension(p1, p2, 15.0)
        .add_vertical_dimension(p2, p3, 15.0)
        .add_aligned_dimension(p1, p3, -15.0);

    // Add a diameter dimension for a hole
    println!("Adding radial dimension...");
    annotations.add_diameter_dimension(
        GeometryRef::Circle {
            center: hole_center,
            radius: 5.0,
        },
        std::f64::consts::FRAC_PI_4, // 45° leader angle
    );

    // Add angular dimension
    println!("Adding angular dimension...");
    let corner = Point2D::new(0.0, 0.0);
    let on_x = Point2D::new(100.0, 0.0);
    let on_diagonal = Point2D::new(100.0, 50.0);
    annotations.add_angle_dimension(on_x, corner, on_diagonal, 25.0);

    // Add ordinate dimensions
    println!("Adding ordinate dimensions...");
    let datum = Point2D::new(0.0, 0.0);
    annotations
        .add_x_ordinate(hole_center, datum, 20.0)
        .add_y_ordinate(hole_center, datum, 20.0);

    // Add GD&T annotations
    println!("Adding GD&T annotations...");

    // Position tolerance for the hole
    let position_fcf =
        FeatureControlFrame::new(GdtSymbol::Position, 0.05, Point2D::new(70.0, 35.0))
            .with_diameter_tolerance()
            .with_material_condition(MaterialCondition::MMC)
            .with_datum_a('A')
            .with_datum_b('B')
            .with_leader(hole_center);

    annotations.add_feature_control_frame(position_fcf);

    // Flatness tolerance
    annotations.add_flatness_tolerance(0.02, Point2D::new(50.0, -10.0));

    // Datum symbols
    annotations.add_datum_symbol('A', Point2D::new(-10.0, 0.0));
    annotations.add_datum_symbol('B', Point2D::new(0.0, -10.0));

    println!("\n=== Annotation Summary ===");
    println!("Total annotations: {}", annotations.annotation_count());
    println!(
        "  Linear dimensions: {}",
        annotations.linear_dimensions.len()
    );
    println!(
        "  Angular dimensions: {}",
        annotations.angular_dimensions.len()
    );
    println!(
        "  Radial dimensions: {}",
        annotations.radial_dimensions.len()
    );
    println!(
        "  Ordinate dimensions: {}",
        annotations.ordinate_dimensions.len()
    );
    println!(
        "  Feature control frames: {}",
        annotations.feature_control_frames.len()
    );
    println!("  Datum symbols: {}", annotations.datum_symbols.len());

    // Render all annotations
    println!("\n=== Rendering Annotations ===");
    let rendered = annotations.render_all(None);

    println!("Rendered {} dimensions:", rendered.len());
    for (i, dim) in rendered.iter().enumerate() {
        println!(
            "  Dimension {}: {} lines, {} arcs, {} arrows, {} texts",
            i,
            dim.lines.len(),
            dim.arcs.len(),
            dim.arrows.len(),
            dim.texts.len()
        );
    }

    // Demonstrate tolerance formatting
    println!("\n=== Tolerance Formatting Demo ===");
    let style = DimensionStyle::default();
    println!("No tolerance: {}", style.format_value(50.0));

    let sym_tol = DimensionStyle::default().with_symmetrical_tolerance(0.05);
    println!("Symmetrical: {}", sym_tol.format_value(50.0));

    let dev_tol = DimensionStyle::default().with_deviation_tolerance(0.05, 0.02);
    println!("Deviation: {}", dev_tol.format_value(50.0));

    let limits_tol = DimensionStyle::default().with_limits_tolerance(0.05, 0.02);
    println!("Limits: {}", limits_tol.format_value(50.0));

    // Demonstrate GD&T symbols
    println!("\n=== GD&T Symbols ===");
    for symbol in [
        GdtSymbol::Position,
        GdtSymbol::Flatness,
        GdtSymbol::Perpendicularity,
        GdtSymbol::Circularity,
        GdtSymbol::Parallelism,
    ] {
        println!(
            "  {:?}: {} (requires datum: {})",
            symbol,
            symbol.unicode_char(),
            symbol.requires_datum()
        );
    }

    println!("\nDone!");
}
