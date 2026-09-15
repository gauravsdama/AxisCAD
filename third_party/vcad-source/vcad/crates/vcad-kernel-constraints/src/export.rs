//! Export a solved sketch to `SketchProfile` for use with extrude/revolve.
//!
//! This module converts the constraint solver's internal representation to
//! the `SketchProfile` type used by `vcad-kernel-sketch`.

use crate::entity::{EntityId, SketchEntity};
use crate::sketch::Sketch2D;
use thiserror::Error;
use vcad_kernel_math::Point2;
use vcad_kernel_sketch::{SketchProfile, SketchSegment};

/// Errors that can occur during sketch export.
#[derive(Debug, Clone, Error)]
pub enum ExportError {
    /// The sketch has no line or arc entities to export.
    #[error("sketch has no exportable segments (lines or arcs)")]
    NoSegments,

    /// The segments don't form a closed loop.
    #[error("segments do not form a closed loop: gap of {0:.6} mm")]
    NotClosed(f64),

    /// An entity referenced by a segment was not found.
    #[error("entity not found: {0:?}")]
    EntityNotFound(EntityId),

    /// A segment references a non-point entity.
    #[error("expected point entity at {0:?}")]
    NotAPoint(EntityId),

    /// Failed to order segments into a closed loop.
    #[error("could not order segments into a closed loop")]
    CannotOrderSegments,
}

/// A segment with its start and end point coordinates (for sorting).
#[derive(Debug, Clone)]
struct OrderedSegment {
    start: Point2,
    end: Point2,
    segment: SketchSegment,
}

impl Sketch2D {
    /// Export the sketch to a `SketchProfile`.
    ///
    /// This collects all line and arc entities, orders them into a closed loop,
    /// and creates a `SketchProfile` that can be used with extrude/revolve.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The sketch has no line or arc segments
    /// - The segments don't form a closed loop
    /// - An entity is missing or invalid
    pub fn to_profile(&self) -> Result<SketchProfile, ExportError> {
        // Collect all segments
        let mut ordered_segments = Vec::new();

        for (_id, entity) in &self.entities {
            match entity {
                SketchEntity::Line(line) => {
                    let start = self.get_point_2d(line.start)?;
                    let end = self.get_point_2d(line.end)?;
                    ordered_segments.push(OrderedSegment {
                        start,
                        end,
                        segment: SketchSegment::Line { start, end },
                    });
                }
                SketchEntity::Arc(arc) => {
                    let start = self.get_point_2d(arc.start)?;
                    let end = self.get_point_2d(arc.end)?;
                    let center = self.get_point_2d(arc.center)?;
                    ordered_segments.push(OrderedSegment {
                        start,
                        end,
                        segment: SketchSegment::Arc {
                            start,
                            end,
                            center,
                            ccw: arc.ccw,
                        },
                    });
                }
                _ => continue, // Skip points and circles
            }
        }

        if ordered_segments.is_empty() {
            return Err(ExportError::NoSegments);
        }

        // Order segments to form a closed loop
        let ordered = order_segments(ordered_segments)?;

        // Extract just the SketchSegment values
        let segments: Vec<SketchSegment> = ordered.into_iter().map(|s| s.segment).collect();

        // Create the profile
        SketchProfile::new(
            self.origin,
            *self.x_dir.as_ref(),
            *self.y_dir.as_ref(),
            segments,
        )
        .map_err(|e| match e {
            vcad_kernel_sketch::SketchError::NotClosed(gap) => ExportError::NotClosed(gap),
            _ => ExportError::CannotOrderSegments,
        })
    }

    /// Get a point's 2D coordinates.
    fn get_point_2d(&self, id: EntityId) -> Result<Point2, ExportError> {
        let entity = self
            .entities
            .get(id)
            .ok_or(ExportError::EntityNotFound(id))?;
        match entity {
            SketchEntity::Point(p) => Ok(Point2::new(
                self.parameters[p.param_x],
                self.parameters[p.param_y],
            )),
            _ => Err(ExportError::NotAPoint(id)),
        }
    }
}

/// Order segments to form a closed loop.
///
/// Starts with the first segment and finds the next segment whose start
/// matches the current segment's end, continuing until we return to the
/// start.
fn order_segments(mut segments: Vec<OrderedSegment>) -> Result<Vec<OrderedSegment>, ExportError> {
    if segments.is_empty() {
        return Err(ExportError::NoSegments);
    }

    if segments.len() == 1 {
        // Single segment must close on itself
        let s = &segments[0];
        if !points_close(s.start, s.end) {
            return Err(ExportError::NotClosed((s.end - s.start).norm()));
        }
        return Ok(segments);
    }

    let mut result = Vec::with_capacity(segments.len());

    // Start with the first segment
    result.push(segments.remove(0));

    // Keep finding the next segment
    while !segments.is_empty() {
        let current_end = result.last().unwrap().end;

        // Find a segment that starts at current_end
        let next_idx = segments
            .iter()
            .position(|s| points_close(s.start, current_end));

        if let Some(idx) = next_idx {
            result.push(segments.remove(idx));
        } else {
            // Try finding a segment that ends at current_end (needs reversal)
            let reverse_idx = segments
                .iter()
                .position(|s| points_close(s.end, current_end));

            if let Some(idx) = reverse_idx {
                let mut seg = segments.remove(idx);
                // Reverse the segment
                std::mem::swap(&mut seg.start, &mut seg.end);
                seg.segment = reverse_segment(&seg.segment);
                result.push(seg);
            } else {
                return Err(ExportError::CannotOrderSegments);
            }
        }
    }

    // Verify closure
    let first_start = result.first().unwrap().start;
    let last_end = result.last().unwrap().end;
    if !points_close(first_start, last_end) {
        return Err(ExportError::NotClosed((last_end - first_start).norm()));
    }

    Ok(result)
}

/// Check if two points are close enough to be considered the same.
fn points_close(a: Point2, b: Point2) -> bool {
    (b - a).norm() < 1e-6
}

/// Reverse a segment (swap start and end, flip arc direction).
fn reverse_segment(seg: &SketchSegment) -> SketchSegment {
    match seg {
        SketchSegment::Line { start, end } => SketchSegment::Line {
            start: *end,
            end: *start,
        },
        SketchSegment::Arc {
            start,
            end,
            center,
            ccw,
        } => SketchSegment::Arc {
            start: *end,
            end: *start,
            center: *center,
            ccw: !ccw,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constraint::EntityRef;

    #[test]
    fn test_export_rectangle() {
        let mut sketch = Sketch2D::new();

        // Create a rectangle
        let p0 = sketch.add_point(0.0, 0.0);
        let p1 = sketch.add_point(10.0, 0.0);
        let p2 = sketch.add_point(10.0, 5.0);
        let p3 = sketch.add_point(0.0, 5.0);

        let _l0 = sketch.add_line(p0, p1);
        let _l1 = sketch.add_line(p1, p2);
        let _l2 = sketch.add_line(p2, p3);
        let _l3 = sketch.add_line(p3, p0);

        let profile = sketch.to_profile().unwrap();
        assert_eq!(profile.segments.len(), 4);
    }

    #[test]
    fn test_export_solved_rectangle() {
        let mut sketch = Sketch2D::new();

        // Create 4 points (intentionally offset)
        let p0 = sketch.add_point(0.0, 0.0);
        let p1 = sketch.add_point(12.0, 1.0);
        let p2 = sketch.add_point(11.0, 6.0);
        let p3 = sketch.add_point(1.0, 5.0);

        let l0 = sketch.add_line(p0, p1);
        let l1 = sketch.add_line(p1, p2);
        let l2 = sketch.add_line(p2, p3);
        let l3 = sketch.add_line(p3, p0);

        // Constrain to be a 10x5 rectangle
        sketch.constrain_fixed(EntityRef::Point(p0), 0.0, 0.0);
        sketch.constrain_horizontal(l0);
        sketch.constrain_horizontal(l2);
        sketch.constrain_vertical(l1);
        sketch.constrain_vertical(l3);
        sketch.constrain_length(l0, 10.0);
        sketch.constrain_length(l1, 5.0);

        let result = sketch.solve_default();
        assert!(result.converged);

        let profile = sketch.to_profile().unwrap();
        assert_eq!(profile.segments.len(), 4);

        // Verify dimensions
        let verts = profile.vertices_2d();
        assert!((verts[0].x - 0.0).abs() < 1e-5);
        assert!((verts[0].y - 0.0).abs() < 1e-5);
        assert!((verts[1].x - 10.0).abs() < 1e-5);
        assert!((verts[1].y - 0.0).abs() < 1e-5);
    }

    #[test]
    fn test_export_no_segments() {
        let mut sketch = Sketch2D::new();
        let _p = sketch.add_point(0.0, 0.0);
        let result = sketch.to_profile();
        assert!(matches!(result, Err(ExportError::NoSegments)));
    }

    #[test]
    fn test_export_unclosed() {
        let mut sketch = Sketch2D::new();
        let p0 = sketch.add_point(0.0, 0.0);
        let p1 = sketch.add_point(10.0, 0.0);
        let p2 = sketch.add_point(10.0, 5.0);

        // Two lines that don't close
        let _l0 = sketch.add_line(p0, p1);
        let _l1 = sketch.add_line(p1, p2);

        let result = sketch.to_profile();
        assert!(matches!(
            result,
            Err(ExportError::NotClosed(_)) | Err(ExportError::CannotOrderSegments)
        ));
    }
}
