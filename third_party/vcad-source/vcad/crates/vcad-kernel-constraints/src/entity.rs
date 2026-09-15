//! Sketch entity types for the constraint solver.
//!
//! Entities are the geometric objects in a 2D sketch: points, lines, arcs,
//! and circles. Each entity references indices into a parameter vector,
//! enabling the solver to modify geometry via parameter updates.

use slotmap::new_key_type;

new_key_type! {
    /// Unique identifier for a sketch entity.
    pub struct EntityId;
}

/// A point entity in the sketch.
///
/// Points contribute 2 parameters to the solver (x, y coordinates).
#[derive(Debug, Clone, Copy)]
pub struct SketchPoint {
    /// Index of the X coordinate in the parameter vector.
    pub param_x: usize,
    /// Index of the Y coordinate in the parameter vector.
    pub param_y: usize,
}

/// A line segment entity connecting two points.
///
/// Lines don't add parameters themselves; they reference existing point entities.
#[derive(Debug, Clone, Copy)]
pub struct SketchLine {
    /// Entity ID of the start point.
    pub start: EntityId,
    /// Entity ID of the end point.
    pub end: EntityId,
}

/// A circular arc entity.
///
/// Arcs are defined by start, end, and center points. The arc direction
/// determines whether it sweeps counter-clockwise or clockwise.
#[derive(Debug, Clone, Copy)]
pub struct SketchArc {
    /// Entity ID of the start point.
    pub start: EntityId,
    /// Entity ID of the end point.
    pub end: EntityId,
    /// Entity ID of the center point.
    pub center: EntityId,
    /// If true, arc goes counter-clockwise from start to end.
    pub ccw: bool,
}

/// A circle entity.
///
/// Circles contribute 1 additional parameter (radius) beyond their center point.
#[derive(Debug, Clone, Copy)]
pub struct SketchCircle {
    /// Entity ID of the center point.
    pub center: EntityId,
    /// Index of the radius in the parameter vector.
    pub param_radius: usize,
}

/// A sketch entity (point, line, arc, or circle).
#[derive(Debug, Clone)]
pub enum SketchEntity {
    /// A point in 2D.
    Point(SketchPoint),
    /// A line segment between two points.
    Line(SketchLine),
    /// A circular arc.
    Arc(SketchArc),
    /// A circle.
    Circle(SketchCircle),
}

impl SketchEntity {
    /// Check if this entity is a point.
    pub fn is_point(&self) -> bool {
        matches!(self, SketchEntity::Point(_))
    }

    /// Check if this entity is a line.
    pub fn is_line(&self) -> bool {
        matches!(self, SketchEntity::Line(_))
    }

    /// Check if this entity is an arc.
    pub fn is_arc(&self) -> bool {
        matches!(self, SketchEntity::Arc(_))
    }

    /// Check if this entity is a circle.
    pub fn is_circle(&self) -> bool {
        matches!(self, SketchEntity::Circle(_))
    }

    /// Get the point data if this is a point entity.
    pub fn as_point(&self) -> Option<&SketchPoint> {
        match self {
            SketchEntity::Point(p) => Some(p),
            _ => None,
        }
    }

    /// Get the line data if this is a line entity.
    pub fn as_line(&self) -> Option<&SketchLine> {
        match self {
            SketchEntity::Line(l) => Some(l),
            _ => None,
        }
    }

    /// Get the arc data if this is an arc entity.
    pub fn as_arc(&self) -> Option<&SketchArc> {
        match self {
            SketchEntity::Arc(a) => Some(a),
            _ => None,
        }
    }

    /// Get the circle data if this is a circle entity.
    pub fn as_circle(&self) -> Option<&SketchCircle> {
        match self {
            SketchEntity::Circle(c) => Some(c),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entity_type_checks() {
        let point = SketchEntity::Point(SketchPoint {
            param_x: 0,
            param_y: 1,
        });
        assert!(point.is_point());
        assert!(!point.is_line());

        let line = SketchEntity::Line(SketchLine {
            start: EntityId::default(),
            end: EntityId::default(),
        });
        assert!(line.is_line());
        assert!(!line.is_point());
    }

    #[test]
    fn test_entity_as_methods() {
        let point = SketchEntity::Point(SketchPoint {
            param_x: 5,
            param_y: 6,
        });
        let p = point.as_point().unwrap();
        assert_eq!(p.param_x, 5);
        assert_eq!(p.param_y, 6);
        assert!(point.as_line().is_none());
    }
}
