//! The `Sketch2D` struct for managing entities and constraints.
//!
//! This is the main user-facing API for building constrained 2D sketches.

use crate::constraint::{Constraint, EntityRef};
use crate::entity::{EntityId, SketchArc, SketchCircle, SketchEntity, SketchLine, SketchPoint};
use crate::solver::{solve, SolveResult, SolverConfig};
use slotmap::SlotMap;
use vcad_kernel_math::{Dir3, Point3, Vec3};

/// A 2D sketch with entities and constraints.
///
/// The sketch exists in a local coordinate system defined by an origin point
/// and two orthogonal direction vectors (x_dir, y_dir).
#[derive(Debug, Clone)]
pub struct Sketch2D {
    /// Origin point of the sketch plane in 3D.
    pub origin: Point3,
    /// Unit vector along the local X axis.
    pub x_dir: Dir3,
    /// Unit vector along the local Y axis.
    pub y_dir: Dir3,
    /// The sketch entities (points, lines, arcs, circles).
    pub entities: SlotMap<EntityId, SketchEntity>,
    /// The constraints on the entities.
    pub constraints: Vec<Constraint>,
    /// The parameter vector (X, Y coordinates of points, radii of circles).
    pub parameters: Vec<f64>,
}

impl Default for Sketch2D {
    fn default() -> Self {
        Self::new()
    }
}

impl Sketch2D {
    /// Create a new empty sketch on the XY plane.
    pub fn new() -> Self {
        Self {
            origin: Point3::origin(),
            x_dir: Dir3::new_normalize(Vec3::x()),
            y_dir: Dir3::new_normalize(Vec3::y()),
            entities: SlotMap::with_key(),
            constraints: Vec::new(),
            parameters: Vec::new(),
        }
    }

    /// Create a new sketch on a custom plane.
    ///
    /// # Arguments
    ///
    /// * `origin` - Origin point of the sketch plane in 3D
    /// * `x_dir` - Direction vector for the local X axis (will be normalized)
    /// * `y_dir` - Direction vector for the local Y axis (will be normalized)
    pub fn on_plane(origin: Point3, x_dir: Vec3, y_dir: Vec3) -> Self {
        Self {
            origin,
            x_dir: Dir3::new_normalize(x_dir),
            y_dir: Dir3::new_normalize(y_dir),
            entities: SlotMap::with_key(),
            constraints: Vec::new(),
            parameters: Vec::new(),
        }
    }

    // =========================================================================
    // Entity creation
    // =========================================================================

    /// Add a point at the given (x, y) coordinates.
    ///
    /// Returns the entity ID of the new point.
    pub fn add_point(&mut self, x: f64, y: f64) -> EntityId {
        let param_x = self.parameters.len();
        let param_y = param_x + 1;
        self.parameters.push(x);
        self.parameters.push(y);
        self.entities
            .insert(SketchEntity::Point(SketchPoint { param_x, param_y }))
    }

    /// Add a line between two existing point entities.
    ///
    /// Returns the entity ID of the new line.
    pub fn add_line(&mut self, start: EntityId, end: EntityId) -> EntityId {
        self.entities
            .insert(SketchEntity::Line(SketchLine { start, end }))
    }

    /// Add a line by creating two new points at the given coordinates.
    ///
    /// Returns (line_id, start_point_id, end_point_id).
    pub fn add_line_by_coords(
        &mut self,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
    ) -> (EntityId, EntityId, EntityId) {
        let start = self.add_point(x1, y1);
        let end = self.add_point(x2, y2);
        let line = self.add_line(start, end);
        (line, start, end)
    }

    /// Add an arc defined by start, end, and center points.
    ///
    /// Returns the entity ID of the new arc.
    pub fn add_arc(
        &mut self,
        start: EntityId,
        end: EntityId,
        center: EntityId,
        ccw: bool,
    ) -> EntityId {
        self.entities.insert(SketchEntity::Arc(SketchArc {
            start,
            end,
            center,
            ccw,
        }))
    }

    /// Add a circle with an existing center point and given radius.
    ///
    /// Returns the entity ID of the new circle.
    pub fn add_circle(&mut self, center: EntityId, radius: f64) -> EntityId {
        let param_radius = self.parameters.len();
        self.parameters.push(radius);
        self.entities.insert(SketchEntity::Circle(SketchCircle {
            center,
            param_radius,
        }))
    }

    /// Add a circle by creating a new center point.
    ///
    /// Returns (circle_id, center_point_id).
    pub fn add_circle_by_coords(&mut self, cx: f64, cy: f64, radius: f64) -> (EntityId, EntityId) {
        let center = self.add_point(cx, cy);
        let circle = self.add_circle(center, radius);
        (circle, center)
    }

    // =========================================================================
    // Constraint creation
    // =========================================================================

    /// Add a constraint to the sketch.
    pub fn add_constraint(&mut self, constraint: Constraint) {
        self.constraints.push(constraint);
    }

    /// Constrain two points to be coincident.
    pub fn constrain_coincident(&mut self, point_a: EntityRef, point_b: EntityRef) {
        self.add_constraint(Constraint::Coincident { point_a, point_b });
    }

    /// Constrain a point to lie on a line.
    pub fn constrain_point_on_line(&mut self, point: EntityRef, line: EntityId) {
        self.add_constraint(Constraint::PointOnLine { point, line });
    }

    /// Constrain two lines to be parallel.
    pub fn constrain_parallel(&mut self, line_a: EntityId, line_b: EntityId) {
        self.add_constraint(Constraint::Parallel { line_a, line_b });
    }

    /// Constrain two lines to be perpendicular.
    pub fn constrain_perpendicular(&mut self, line_a: EntityId, line_b: EntityId) {
        self.add_constraint(Constraint::Perpendicular { line_a, line_b });
    }

    /// Constrain a line to be horizontal.
    pub fn constrain_horizontal(&mut self, line: EntityId) {
        self.add_constraint(Constraint::Horizontal { line });
    }

    /// Constrain a line to be vertical.
    pub fn constrain_vertical(&mut self, line: EntityId) {
        self.add_constraint(Constraint::Vertical { line });
    }

    /// Constrain a point to be fixed at a position.
    pub fn constrain_fixed(&mut self, point: EntityRef, x: f64, y: f64) {
        self.add_constraint(Constraint::Fixed { point, x, y });
    }

    /// Constrain the distance between two points.
    pub fn constrain_distance(&mut self, point_a: EntityRef, point_b: EntityRef, distance: f64) {
        self.add_constraint(Constraint::Distance {
            point_a,
            point_b,
            distance,
        });
    }

    /// Constrain the length of a line.
    pub fn constrain_length(&mut self, line: EntityId, length: f64) {
        self.add_constraint(Constraint::Length { line, length });
    }

    /// Constrain the radius of a circle.
    pub fn constrain_radius(&mut self, circle: EntityId, radius: f64) {
        self.add_constraint(Constraint::Radius { circle, radius });
    }

    /// Constrain two lines to have equal length.
    pub fn constrain_equal_length(&mut self, line_a: EntityId, line_b: EntityId) {
        self.add_constraint(Constraint::EqualLength { line_a, line_b });
    }

    /// Constrain the angle between two lines.
    pub fn constrain_angle(&mut self, line_a: EntityId, line_b: EntityId, angle_deg: f64) {
        self.add_constraint(Constraint::Angle {
            line_a,
            line_b,
            angle_rad: angle_deg.to_radians(),
        });
    }

    // =========================================================================
    // Solving
    // =========================================================================

    /// Solve the constraint system.
    ///
    /// This adjusts the parameters to satisfy all constraints using
    /// Levenberg-Marquardt optimization.
    pub fn solve(&mut self, config: &SolverConfig) -> SolveResult {
        solve(
            &self.constraints,
            &mut self.parameters,
            &self.entities,
            config,
        )
    }

    /// Solve with default configuration.
    pub fn solve_default(&mut self) -> SolveResult {
        self.solve(&SolverConfig::default())
    }

    // =========================================================================
    // Querying
    // =========================================================================

    /// Get the current (x, y) coordinates of a point.
    pub fn get_point(&self, id: EntityId) -> Option<(f64, f64)> {
        if let Some(SketchEntity::Point(p)) = self.entities.get(id) {
            Some((self.parameters[p.param_x], self.parameters[p.param_y]))
        } else {
            None
        }
    }

    /// Get the current radius of a circle.
    pub fn get_radius(&self, id: EntityId) -> Option<f64> {
        if let Some(SketchEntity::Circle(c)) = self.entities.get(id) {
            Some(self.parameters[c.param_radius])
        } else {
            None
        }
    }

    /// Get the line endpoints as ((x1, y1), (x2, y2)).
    pub fn get_line_endpoints(&self, id: EntityId) -> Option<((f64, f64), (f64, f64))> {
        if let Some(SketchEntity::Line(l)) = self.entities.get(id) {
            let start = self.get_point(l.start)?;
            let end = self.get_point(l.end)?;
            Some((start, end))
        } else {
            None
        }
    }

    /// Get the length of a line.
    pub fn get_line_length(&self, id: EntityId) -> Option<f64> {
        let ((x1, y1), (x2, y2)) = self.get_line_endpoints(id)?;
        Some(((x2 - x1).powi(2) + (y2 - y1).powi(2)).sqrt())
    }

    /// Convert a 2D sketch point to 3D world coordinates.
    pub fn to_3d(&self, x: f64, y: f64) -> Point3 {
        self.origin + x * self.x_dir.as_ref() + y * self.y_dir.as_ref()
    }

    /// Get a point's 3D world coordinates.
    pub fn get_point_3d(&self, id: EntityId) -> Option<Point3> {
        let (x, y) = self.get_point(id)?;
        Some(self.to_3d(x, y))
    }

    /// Calculate the degrees of freedom of the sketch.
    ///
    /// DOF = (number of parameters) - (number of constraint equations)
    ///
    /// A fully constrained sketch has DOF = 0.
    /// An over-constrained sketch has DOF < 0.
    /// An under-constrained sketch has DOF > 0.
    pub fn degrees_of_freedom(&self) -> i32 {
        let num_params = self.parameters.len() as i32;
        let num_constraints: i32 = self
            .constraints
            .iter()
            .map(|c| c.num_residuals() as i32)
            .sum();
        num_params - num_constraints
    }

    /// Check if the sketch is fully constrained (DOF = 0).
    pub fn is_fully_constrained(&self) -> bool {
        self.degrees_of_freedom() == 0
    }

    /// Check if the sketch is over-constrained (DOF < 0).
    pub fn is_over_constrained(&self) -> bool {
        self.degrees_of_freedom() < 0
    }

    /// Get the number of entities in the sketch.
    pub fn num_entities(&self) -> usize {
        self.entities.len()
    }

    /// Get the number of constraints in the sketch.
    pub fn num_constraints(&self) -> usize {
        self.constraints.len()
    }

    /// Get all point entity IDs.
    pub fn point_ids(&self) -> Vec<EntityId> {
        self.entities
            .iter()
            .filter_map(|(id, e)| if e.is_point() { Some(id) } else { None })
            .collect()
    }

    /// Get all line entity IDs.
    pub fn line_ids(&self) -> Vec<EntityId> {
        self.entities
            .iter()
            .filter_map(|(id, e)| if e.is_line() { Some(id) } else { None })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_point() {
        let mut sketch = Sketch2D::new();
        let p = sketch.add_point(5.0, 10.0);
        assert_eq!(sketch.get_point(p), Some((5.0, 10.0)));
    }

    #[test]
    fn test_add_line() {
        let mut sketch = Sketch2D::new();
        let (line, start, end) = sketch.add_line_by_coords(0.0, 0.0, 10.0, 0.0);
        assert!(sketch.entities.get(line).is_some());
        assert_eq!(sketch.get_point(start), Some((0.0, 0.0)));
        assert_eq!(sketch.get_point(end), Some((10.0, 0.0)));
    }

    #[test]
    fn test_add_circle() {
        let mut sketch = Sketch2D::new();
        let (circle, center) = sketch.add_circle_by_coords(5.0, 5.0, 3.0);
        assert_eq!(sketch.get_point(center), Some((5.0, 5.0)));
        assert_eq!(sketch.get_radius(circle), Some(3.0));
    }

    #[test]
    fn test_degrees_of_freedom_unconstrained() {
        let mut sketch = Sketch2D::new();
        let _p = sketch.add_point(0.0, 0.0);
        // 1 point = 2 parameters, 0 constraints
        assert_eq!(sketch.degrees_of_freedom(), 2);
    }

    #[test]
    fn test_degrees_of_freedom_fixed() {
        let mut sketch = Sketch2D::new();
        let p = sketch.add_point(0.0, 0.0);
        sketch.constrain_fixed(EntityRef::Point(p), 0.0, 0.0);
        // 2 params - 2 constraint equations = 0
        assert_eq!(sketch.degrees_of_freedom(), 0);
        assert!(sketch.is_fully_constrained());
    }

    #[test]
    fn test_solve_rectangle() {
        let mut sketch = Sketch2D::new();

        // Create 4 points for a rectangle
        let p0 = sketch.add_point(0.0, 0.0);
        let p1 = sketch.add_point(12.0, 1.0); // Intentionally off
        let p2 = sketch.add_point(11.0, 8.0);
        let p3 = sketch.add_point(1.0, 7.0);

        // Create 4 lines
        let l0 = sketch.add_line(p0, p1); // Bottom
        let l1 = sketch.add_line(p1, p2); // Right
        let l2 = sketch.add_line(p2, p3); // Top
        let l3 = sketch.add_line(p3, p0); // Left

        // Fix the origin
        sketch.constrain_fixed(EntityRef::Point(p0), 0.0, 0.0);

        // Make it a rectangle
        sketch.constrain_horizontal(l0);
        sketch.constrain_horizontal(l2);
        sketch.constrain_vertical(l1);
        sketch.constrain_vertical(l3);

        // Set dimensions
        sketch.constrain_length(l0, 10.0);
        sketch.constrain_length(l1, 5.0);

        let result = sketch.solve_default();
        assert!(result.converged, "Solver should converge");

        // Verify corners
        let (x0, y0) = sketch.get_point(p0).unwrap();
        let (x1, y1) = sketch.get_point(p1).unwrap();
        let (x2, y2) = sketch.get_point(p2).unwrap();
        let (x3, y3) = sketch.get_point(p3).unwrap();

        assert!((x0 - 0.0).abs() < 1e-6);
        assert!((y0 - 0.0).abs() < 1e-6);
        assert!((x1 - 10.0).abs() < 1e-6);
        assert!((y1 - 0.0).abs() < 1e-6);
        assert!((x2 - 10.0).abs() < 1e-6);
        assert!((y2 - 5.0).abs() < 1e-6);
        assert!((x3 - 0.0).abs() < 1e-6);
        assert!((y3 - 5.0).abs() < 1e-6);
    }

    #[test]
    fn test_line_length() {
        let mut sketch = Sketch2D::new();
        let (line, _, _) = sketch.add_line_by_coords(0.0, 0.0, 3.0, 4.0);
        assert!((sketch.get_line_length(line).unwrap() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn test_to_3d() {
        let sketch = Sketch2D::on_plane(Point3::new(10.0, 0.0, 0.0), Vec3::y(), Vec3::z());
        let p = sketch.to_3d(5.0, 3.0);
        assert!((p.x - 10.0).abs() < 1e-12);
        assert!((p.y - 5.0).abs() < 1e-12);
        assert!((p.z - 3.0).abs() < 1e-12);
    }
}
