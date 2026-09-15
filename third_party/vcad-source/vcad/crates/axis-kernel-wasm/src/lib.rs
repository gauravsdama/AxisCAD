//! Axis CAD WASM bindings for the pinned VCAD B-rep kernel.

use serde::{Deserialize, Serialize};
use vcad_kernel::vcad_kernel_math::{Point2, Point3, Vec2, Vec3};
use vcad_kernel::vcad_kernel_sketch::{SketchProfile, SketchSegment};
use wasm_bindgen::prelude::*;

const KERNEL_VERSION: &str = env!("CARGO_PKG_VERSION");

#[wasm_bindgen(start)]
pub fn init() {
    console_error_panic_hook::set_once();
    web_sys::console::log_1(&format!("[WASM] Axis CAD kernel {} loaded", KERNEL_VERSION).into());
}

/// Triangle mesh output for rendering.
#[derive(Serialize, Deserialize)]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub struct WasmMesh {
    /// Flat array of vertex positions: [x0, y0, z0, x1, y1, z1, ...]
    pub positions: Vec<f32>,
    /// Flat array of triangle indices: [i0, i1, i2, ...]
    pub indices: Vec<u32>,
    /// Flat array of vertex normals: [nx0, ny0, nz0, ...] (same length as positions).
    /// When present, these are analytical surface normals for moiré-free rendering.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub normals: Option<Vec<f32>>,
    /// Optional per-triangle face-kind tag (same length as `indices / 3`).
    /// Values: 0 = Unknown, 1 = Plane, 2 = Cylinder, 3 = Sphere,
    /// 4 = Cone, 5 = Bilinear, 6 = Torus, 7 = BSpline, 8 = FanFill.
    /// Used by the viewport's click-to-inspect debugger.
    #[serde(rename = "faceKinds", skip_serializing_if = "Option::is_none")]
    pub face_kinds: Option<Vec<u8>>,
    /// Stable B-rep face ordinal for each triangle.
    #[serde(rename = "faceIds", skip_serializing_if = "Option::is_none")]
    pub face_ids: Option<Vec<u32>>,
    /// Stable, measurable B-rep boundary edges.
    #[serde(rename = "topologyEdges", skip_serializing_if = "Option::is_none")]
    pub topology_edges: Option<Vec<WasmTopologyEdge>>,
    /// Stable, measurable B-rep faces.
    #[serde(rename = "topologyFaces", skip_serializing_if = "Option::is_none")]
    pub topology_faces: Option<Vec<WasmTopologyFace>>,
}

#[derive(Serialize, Deserialize)]
pub struct WasmTopologyEdge {
    pub id: u32,
    #[serde(rename = "faceIds")]
    pub face_ids: Vec<u32>,
    pub positions: Vec<f32>,
    pub anchor: Vec<f32>,
    pub length: f64,
    #[serde(rename = "lengthExact")]
    pub length_exact: bool,
    #[serde(rename = "curveKind")]
    pub curve_kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub radius: Option<f64>,
}

#[derive(Serialize, Deserialize)]
pub struct WasmTopologyFace {
    pub id: u32,
    pub area: f64,
    #[serde(rename = "areaExact")]
    pub area_exact: bool,
    #[serde(rename = "surfaceKind")]
    pub surface_kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub radius: Option<f64>,
}

/// Mesh-to-mesh clearance result: minimum separation (or penetration
/// depth if negative) between two solids/meshes.
#[derive(Serialize, Deserialize)]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub struct WasmClearance {
    /// Signed distance in mm: minimum separation when non-negative, the
    /// negated deepest penetration when the meshes intersect.
    pub distance: f64,
    /// True when the meshes intersect (crossing surfaces or containment).
    pub intersecting: bool,
    /// Point on the first mesh realizing the reported distance.
    #[serde(rename = "pointA")]
    pub point_a: [f64; 3],
    /// Point on the second mesh realizing the reported distance.
    #[serde(rename = "pointB")]
    pub point_b: [f64; 3],
}

impl From<vcad_kernel::ClearanceResult> for WasmClearance {
    fn from(r: vcad_kernel::ClearanceResult) -> Self {
        Self {
            distance: r.distance,
            intersecting: r.intersecting,
            point_a: r.point_a,
            point_b: r.point_b,
        }
    }
}

/// Mesh-to-mesh clearance over raw evaluated-mesh buffers (see
/// `WasmClearance`). Operates on already-placed geometry, so callers can
/// measure between any two evaluated parts (or merged part groups) without
/// re-building solids.
#[wasm_bindgen]
pub fn mesh_clearance(
    positions_a: &[f32],
    indices_a: &[u32],
    positions_b: &[f32],
    indices_b: &[u32],
) -> Result<JsValue, JsError> {
    let mesh_of = |positions: &[f32], indices: &[u32]| {
        let mut m = vcad_kernel_tessellate::TriangleMesh::new();
        m.vertices = positions.to_vec();
        m.indices = indices.to_vec();
        m
    };
    let a = mesh_of(positions_a, indices_a);
    let b = mesh_of(positions_b, indices_b);
    let r = vcad_kernel_tessellate::mesh_clearance(&a, &b)
        .ok_or_else(|| JsError::new("clearance requires two non-empty meshes"))?;
    serde_wasm_bindgen::to_value(&WasmClearance::from(r)).map_err(|e| JsError::new(&e.to_string()))
}

/// Result of a topology optimization run (see `vcad-kernel-topopt`).
#[derive(Serialize, Deserialize)]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub struct WasmTopoOptResult {
    /// Optimized structure as a watertight surface mesh (mm, Z-up).
    pub mesh: WasmMesh,
    /// Compliance after each SIMP iteration (decreasing = stiffer).
    #[serde(rename = "complianceHistory")]
    pub compliance_history: Vec<f64>,
    /// SIMP iterations actually run.
    pub iterations: u32,
    /// Whether the density change converged below the spec tolerance.
    pub converged: bool,
    /// Material fraction of the design domain actually used.
    #[serde(rename = "volumeFraction")]
    pub volume_fraction: f64,
    /// Voxel grid dimensions `[nx, ny, nz]`.
    pub grid: [u32; 3],
    /// Voxel edge length in mm.
    #[serde(rename = "voxelSize")]
    pub voxel_size: f64,
}

fn topopt_response(
    result: vcad_kernel::vcad_kernel_topopt::TopoOptResult,
) -> Result<JsValue, JsError> {
    let out = WasmTopoOptResult {
        mesh: WasmMesh {
            positions: result.mesh.vertices,
            indices: result.mesh.indices,
            normals: if result.mesh.normals.is_empty() {
                None
            } else {
                Some(result.mesh.normals)
            },
            face_kinds: None,
            face_ids: None,
            topology_edges: None,
            topology_faces: None,
        },
        compliance_history: result.compliance_history,
        iterations: result.iterations as u32,
        converged: result.converged,
        volume_fraction: result.volume_fraction_achieved,
        grid: [
            result.grid[0] as u32,
            result.grid[1] as u32,
            result.grid[2] as u32,
        ],
        voxel_size: result.voxel_size,
    };
    serde_wasm_bindgen::to_value(&out).map_err(|e| JsError::new(&e.to_string()))
}

/// SIMP topology optimization over a box design domain.
///
/// `spec_json` is a serialized `vcad_kernel_topopt::TopoOptSpec` (loads,
/// supports, volume fraction, resolution, ...). Returns a
/// `WasmTopoOptResult`.
#[wasm_bindgen(js_name = topologyOptimizeBox)]
#[allow(clippy::too_many_arguments)]
pub fn topology_optimize_box(
    spec_json: &str,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
) -> Result<JsValue, JsError> {
    let spec: vcad_kernel::vcad_kernel_topopt::TopoOptSpec =
        serde_json::from_str(spec_json).map_err(|e| JsError::new(&format!("bad spec: {e}")))?;
    let result = vcad_kernel::vcad_kernel_topopt::optimize_box(
        [min_x, min_y, min_z],
        [max_x, max_y, max_z],
        &spec,
    )
    .map_err(|e| JsError::new(&e.to_string()))?;
    topopt_response(result)
}

/// SIMP topology optimization inside an existing (closed) evaluated mesh:
/// the mesh's interior becomes the design domain, so material only appears
/// where the original part had volume.
#[wasm_bindgen(js_name = topologyOptimizeMesh)]
pub fn topology_optimize_mesh(
    spec_json: &str,
    positions: &[f32],
    indices: &[u32],
) -> Result<JsValue, JsError> {
    let spec: vcad_kernel::vcad_kernel_topopt::TopoOptSpec =
        serde_json::from_str(spec_json).map_err(|e| JsError::new(&format!("bad spec: {e}")))?;
    let mut mesh = vcad_kernel_tessellate::TriangleMesh::new();
    mesh.vertices = positions.to_vec();
    mesh.indices = indices.to_vec();
    let result = vcad_kernel::vcad_kernel_topopt::optimize_mesh(&mesh, &spec)
        .map_err(|e| JsError::new(&e.to_string()))?;
    topopt_response(result)
}

/// Result of a static structural analysis solve (see
/// `vcad_kernel_topopt::analyze`). Two-tier contract: at coarse resolution
/// this is the fast `predicted` path; the same solver at fine resolution is
/// the `verified` path.
#[derive(Serialize, Deserialize)]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub struct WasmStaticAnalysis {
    /// Compliance `fᵀu` in N·mm (lower = stiffer under these loads).
    pub compliance: f64,
    /// Maximum nodal displacement magnitude in mm.
    #[serde(rename = "maxDisplacementMm")]
    pub max_displacement_mm: f64,
    /// World position of the most-displaced node, mm.
    #[serde(rename = "maxDisplacementAt")]
    pub max_displacement_at: [f64; 3],
    /// Maximum element-centroid von Mises stress in MPa (voxel estimate).
    #[serde(rename = "maxVonMisesMpa")]
    pub max_von_mises_mpa: f64,
    /// World position of the most-stressed element centroid, mm.
    #[serde(rename = "maxStressAt")]
    pub max_stress_at: [f64; 3],
    /// Voxel grid dimensions `[nx, ny, nz]`.
    pub grid: [u32; 3],
    /// Voxel edge length in mm.
    #[serde(rename = "voxelSizeMm")]
    pub voxel_size_mm: f64,
    /// Relative residual the PCG solve reached.
    #[serde(rename = "relativeResidual")]
    pub relative_residual: f64,
    /// Whether the solve converged.
    pub converged: bool,
}

fn analysis_response(
    a: vcad_kernel::vcad_kernel_topopt::StaticAnalysis,
) -> Result<JsValue, JsError> {
    let out = WasmStaticAnalysis {
        compliance: a.compliance_n_mm,
        max_displacement_mm: a.max_displacement_mm,
        max_displacement_at: a.max_displacement_at,
        max_von_mises_mpa: a.max_von_mises_mpa,
        max_stress_at: a.max_stress_at,
        grid: [a.grid[0] as u32, a.grid[1] as u32, a.grid[2] as u32],
        voxel_size_mm: a.voxel_size_mm,
        relative_residual: a.relative_residual,
        converged: a.converged,
    };
    serde_wasm_bindgen::to_value(&out).map_err(|e| JsError::new(&e.to_string()))
}

/// Static structural analysis of a box solid.
///
/// `spec_json` is a serialized `vcad_kernel_topopt::AnalysisSpec` (loads,
/// supports, resolution, youngs_modulus_mpa, poisson).
#[wasm_bindgen(js_name = analyzeStaticsBox)]
#[allow(clippy::too_many_arguments)]
pub fn analyze_statics_box(
    spec_json: &str,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
) -> Result<JsValue, JsError> {
    let spec: vcad_kernel::vcad_kernel_topopt::AnalysisSpec =
        serde_json::from_str(spec_json).map_err(|e| JsError::new(&format!("bad spec: {e}")))?;
    let a = vcad_kernel::vcad_kernel_topopt::analyze_box(
        [min_x, min_y, min_z],
        [max_x, max_y, max_z],
        &spec,
    )
    .map_err(|e| JsError::new(&e.to_string()))?;
    analysis_response(a)
}

/// Static structural analysis of an existing (closed) evaluated mesh: the
/// mesh interior is voxelized and solved under the given loads/supports.
#[wasm_bindgen(js_name = analyzeStaticsMesh)]
pub fn analyze_statics_mesh(
    spec_json: &str,
    positions: &[f32],
    indices: &[u32],
) -> Result<JsValue, JsError> {
    let spec: vcad_kernel::vcad_kernel_topopt::AnalysisSpec =
        serde_json::from_str(spec_json).map_err(|e| JsError::new(&format!("bad spec: {e}")))?;
    let mut mesh = vcad_kernel_tessellate::TriangleMesh::new();
    mesh.vertices = positions.to_vec();
    mesh.indices = indices.to_vec();
    let a = vcad_kernel::vcad_kernel_topopt::analyze_mesh(&mesh, &spec)
        .map_err(|e| JsError::new(&e.to_string()))?;
    analysis_response(a)
}

/// A 2D sketch segment (line or arc) for WASM input.
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub enum WasmSketchSegment {
    Line {
        start: [f64; 2],
        end: [f64; 2],
    },
    Arc {
        start: [f64; 2],
        end: [f64; 2],
        center: [f64; 2],
        ccw: bool,
    },
}

/// Input for creating a sketch profile from JS.
#[derive(Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "ts-rs", derive(TS))]
#[cfg_attr(feature = "ts-rs", ts(export, export_to = "generated/"))]
pub struct WasmSketchProfile {
    /// Origin point of the sketch plane [x, y, z].
    pub origin: [f64; 3],
    /// X direction vector [x, y, z].
    pub x_dir: [f64; 3],
    /// Y direction vector [x, y, z].
    pub y_dir: [f64; 3],
    /// Segments forming the closed profile.
    pub segments: Vec<WasmSketchSegment>,
    /// Optional interior hole loops, each a closed loop of segments in the
    /// same sketch coordinate system, strictly inside the outer profile.
    /// Only `extrude` honors holes; other profile consumers reject them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[cfg_attr(feature = "ts-rs", ts(optional))]
    pub holes: Option<Vec<Vec<WasmSketchSegment>>>,
}

#[derive(Deserialize)]
struct WasmSweepScaleStation {
    position: f64,
    scale: f64,
}

#[derive(Deserialize)]
struct WasmSweepProfileStation {
    position: f64,
    profile: WasmSketchProfile,
}

/// Convert one JS sketch segment to its kernel equivalent.
fn to_kernel_segment(s: &WasmSketchSegment) -> SketchSegment {
    match s {
        WasmSketchSegment::Line { start, end } => SketchSegment::Line {
            start: Point2::new(start[0], start[1]),
            end: Point2::new(end[0], end[1]),
        },
        WasmSketchSegment::Arc {
            start,
            end,
            center,
            ccw,
        } => SketchSegment::Arc {
            start: Point2::new(start[0], start[1]),
            end: Point2::new(end[0], end[1]),
            center: Point2::new(center[0], center[1]),
            ccw: *ccw,
        },
    }
}

impl WasmSketchProfile {
    /// Interior hole loops converted to kernel segments (empty when absent).
    fn kernel_holes(&self) -> Vec<Vec<SketchSegment>> {
        self.holes
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .map(|hole| hole.iter().map(to_kernel_segment).collect())
            .collect()
    }

    /// Error when the profile carries interior holes, which `op_name`
    /// doesn't support.
    fn reject_holes(&self, op_name: &str) -> Result<(), JsError> {
        if self.holes.as_ref().is_some_and(|h| !h.is_empty()) {
            return Err(JsError::new(&format!(
                "interior hole loops are not supported for {op_name}"
            )));
        }
        Ok(())
    }

    fn to_kernel_profile(&self) -> Result<SketchProfile, String> {
        let segments: Vec<SketchSegment> = self.segments.iter().map(to_kernel_segment).collect();

        SketchProfile::new(
            Point3::new(self.origin[0], self.origin[1], self.origin[2]),
            Vec3::new(self.x_dir[0], self.x_dir[1], self.x_dir[2]),
            Vec3::new(self.y_dir[0], self.y_dir[1], self.y_dir[2]),
            segments,
        )
        .map_err(|e| e.to_string())
    }

    /// Convert to kernel profile with coordinates centered around (0, 0).
    /// This is useful for sweep operations where the profile should be
    /// centered on the path.
    fn to_kernel_profile_centered(&self) -> Result<SketchProfile, String> {
        // Filter out degenerate (zero-length) segments first
        let valid_segments: Vec<_> = self
            .segments
            .iter()
            .filter(|seg| {
                let (start, end) = match seg {
                    WasmSketchSegment::Line { start, end } => (start, end),
                    WasmSketchSegment::Arc { start, end, .. } => (start, end),
                };
                let dx = end[0] - start[0];
                let dy = end[1] - start[1];
                (dx * dx + dy * dy).sqrt() > 1e-9
            })
            .collect();

        if valid_segments.is_empty() {
            return Err("No valid (non-degenerate) segments in profile".into());
        }

        // Compute centroid of valid segment start points only
        let mut sum_x = 0.0;
        let mut sum_y = 0.0;
        let mut count = 0;

        for seg in &valid_segments {
            let (sx, sy) = match seg {
                WasmSketchSegment::Line { start, .. } => (start[0], start[1]),
                WasmSketchSegment::Arc { start, .. } => (start[0], start[1]),
            };
            sum_x += sx;
            sum_y += sy;
            count += 1;
        }

        let (cx, cy) = if count > 0 {
            (sum_x / count as f64, sum_y / count as f64)
        } else {
            (0.0, 0.0)
        };

        // Create centered segments from valid segments only
        let segments: Vec<SketchSegment> = valid_segments
            .iter()
            .map(|s| match s {
                WasmSketchSegment::Line { start, end } => SketchSegment::Line {
                    start: Point2::new(start[0] - cx, start[1] - cy),
                    end: Point2::new(end[0] - cx, end[1] - cy),
                },
                WasmSketchSegment::Arc {
                    start,
                    end,
                    center,
                    ccw,
                } => SketchSegment::Arc {
                    start: Point2::new(start[0] - cx, start[1] - cy),
                    end: Point2::new(end[0] - cx, end[1] - cy),
                    center: Point2::new(center[0] - cx, center[1] - cy),
                    ccw: *ccw,
                },
            })
            .collect();

        SketchProfile::new(
            Point3::new(self.origin[0], self.origin[1], self.origin[2]),
            Vec3::new(self.x_dir[0], self.x_dir[1], self.x_dir[2]),
            Vec3::new(self.y_dir[0], self.y_dir[1], self.y_dir[2]),
            segments,
        )
        .map_err(|e| e.to_string())
    }
}

fn scale_profile(mut profile: SketchProfile, scale: f64, origin: Point3) -> SketchProfile {
    profile.origin = origin;
    profile.segments = profile
        .segments
        .into_iter()
        .map(|segment| match segment {
            SketchSegment::Line { start, end } => SketchSegment::Line {
                start: Point2::new(start.x * scale, start.y * scale),
                end: Point2::new(end.x * scale, end.y * scale),
            },
            SketchSegment::Arc {
                start,
                end,
                center,
                ccw,
            } => SketchSegment::Arc {
                start: Point2::new(start.x * scale, start.y * scale),
                end: Point2::new(end.x * scale, end.y * scale),
                center: Point2::new(center.x * scale, center.y * scale),
                ccw,
            },
        })
        .collect();
    profile
}

fn station_scale(
    position: f64,
    scale_start: f64,
    scale_end: f64,
    stations: &[WasmSweepScaleStation],
) -> f64 {
    let mut left = (0.0, scale_start);
    for station in stations {
        if station.position >= position {
            let span = station.position - left.0;
            let amount = if span <= 1e-12 {
                1.0
            } else {
                (position - left.0) / span
            };
            return left.1 + (station.scale - left.1) * amount;
        }
        left = (station.position, station.scale);
    }
    let span = 1.0 - left.0;
    let amount = if span <= 1e-12 {
        1.0
    } else {
        (position - left.0) / span
    };
    left.1 + (scale_end - left.1) * amount
}

fn resample_profile(profile: &SketchProfile, sample_count: usize) -> Vec<Point2> {
    let lengths: Vec<f64> = profile.segments.iter().map(SketchSegment::length).collect();
    let perimeter: f64 = lengths.iter().sum();
    (0..sample_count)
        .map(|sample_index| {
            let mut distance = perimeter * sample_index as f64 / sample_count as f64;
            let mut segment_index = 0usize;
            while segment_index + 1 < lengths.len() && distance > lengths[segment_index] {
                distance -= lengths[segment_index];
                segment_index += 1;
            }
            let amount = if lengths[segment_index] <= 1e-12 {
                0.0
            } else {
                (distance / lengths[segment_index]).clamp(0.0, 1.0)
            };
            match &profile.segments[segment_index] {
                SketchSegment::Line { start, end } => *start + (*end - *start) * amount,
                SketchSegment::Arc {
                    start,
                    end,
                    center,
                    ccw,
                } => {
                    let start_angle = (start.y - center.y).atan2(start.x - center.x);
                    let end_angle = (end.y - center.y).atan2(end.x - center.x);
                    let mut sweep = end_angle - start_angle;
                    if *ccw && sweep < 0.0 {
                        sweep += std::f64::consts::TAU;
                    } else if !*ccw && sweep > 0.0 {
                        sweep -= std::f64::consts::TAU;
                    }
                    let radius = (*start - *center).norm();
                    let angle = start_angle + sweep * amount;
                    *center + Vec2::new(radius * angle.cos(), radius * angle.sin())
                }
            }
        })
        .collect()
}

fn align_closed_profile(reference: &[Point2], candidate: &[Point2]) -> Vec<Point2> {
    if reference.len() != candidate.len() || candidate.is_empty() {
        return candidate.to_vec();
    }
    let shift = (0..candidate.len())
        .min_by(|left, right| {
            let score = |offset: usize| {
                reference
                    .iter()
                    .enumerate()
                    .map(|(index, point)| {
                        let delta = *point - candidate[(index + offset) % candidate.len()];
                        delta.dot(&delta)
                    })
                    .sum::<f64>()
            };
            score(*left).total_cmp(&score(*right))
        })
        .unwrap_or(0);
    (0..candidate.len())
        .map(|index| candidate[(index + shift) % candidate.len()])
        .collect()
}

fn line_profile_from_points(
    points: &[Point2],
    origin: Point3,
    x_dir: Vec3,
    y_dir: Vec3,
) -> Result<SketchProfile, JsError> {
    let segments = (0..points.len())
        .map(|index| SketchSegment::Line {
            start: points[index],
            end: points[(index + 1) % points.len()],
        })
        .collect();
    SketchProfile::new(origin, x_dir, y_dir, segments)
        .map_err(|error| JsError::new(&error.to_string()))
}

#[allow(clippy::too_many_arguments)]
fn loft_line_stations(
    profile: WasmSketchProfile,
    start: Point3,
    end: Point3,
    scale_start: f64,
    scale_end: f64,
    scale_stations_json: Option<String>,
    profile_stations_json: Option<String>,
) -> Result<Option<Solid>, JsError> {
    let mut scale_stations: Vec<WasmSweepScaleStation> =
        serde_json::from_str(scale_stations_json.as_deref().unwrap_or("[]"))
            .map_err(|error| JsError::new(&format!("Invalid sweep scale stations: {error}")))?;
    let mut profile_stations: Vec<WasmSweepProfileStation> =
        serde_json::from_str(profile_stations_json.as_deref().unwrap_or("[]"))
            .map_err(|error| JsError::new(&format!("Invalid sweep profile stations: {error}")))?;
    if scale_stations.is_empty() && profile_stations.is_empty() {
        return Ok(None);
    }
    scale_stations.sort_by(|left, right| left.position.total_cmp(&right.position));
    profile_stations.sort_by(|left, right| left.position.total_cmp(&right.position));
    if scale_stations
        .iter()
        .any(|station| !(0.0..=1.0).contains(&station.position) || station.scale <= 0.0)
        || profile_stations
            .iter()
            .any(|station| !(0.0..=1.0).contains(&station.position))
    {
        return Err(JsError::new(
            "Sweep station positions must be between 0 and 1 and scales must be positive",
        ));
    }

    let base = profile
        .to_kernel_profile_centered()
        .map_err(|error| JsError::new(&format!("Invalid profile: {error}")))?;
    let mut key_positions = vec![0.0, 1.0];
    key_positions.extend(profile_stations.iter().map(|station| station.position));
    key_positions.sort_by(f64::total_cmp);
    key_positions.dedup_by(|left, right| (*left - *right).abs() <= 1e-12);

    let mut section_index = 0usize;
    let mut current_profile = base.clone();
    let mut key_profiles = Vec::with_capacity(key_positions.len());
    for position in &key_positions {
        while section_index < profile_stations.len()
            && profile_stations[section_index].position <= *position + 1e-12
        {
            current_profile = profile_stations[section_index]
                .profile
                .to_kernel_profile_centered()
                .map_err(|error| JsError::new(&format!("Invalid profile station: {error}")))?;
            section_index += 1;
        }
        key_profiles.push(current_profile.clone());
    }

    let sample_count = 32usize;
    let mut sampled_keys: Vec<Vec<Point2>> = Vec::with_capacity(key_profiles.len());
    for profile in &key_profiles {
        let sampled = resample_profile(profile, sample_count);
        let aligned = sampled_keys.last().map_or(sampled.clone(), |previous| {
            align_closed_profile(previous, &sampled)
        });
        sampled_keys.push(aligned);
    }
    let mut path_positions: Vec<f64> = (0..=32).map(|index| index as f64 / 32.0).collect();
    path_positions.extend(key_positions.iter().copied());
    path_positions.extend(scale_stations.iter().map(|station| station.position));
    path_positions.sort_by(f64::total_cmp);
    path_positions.dedup_by(|left, right| (*left - *right).abs() <= 1e-12);

    let direction = end - start;
    let mut profiles = Vec::with_capacity(path_positions.len());
    for position in path_positions {
        let right_index = key_positions
            .iter()
            .position(|key| *key >= position - 1e-12)
            .unwrap_or(key_positions.len() - 1);
        let left_index = right_index.saturating_sub(1);
        let span = key_positions[right_index] - key_positions[left_index];
        let mix = if right_index == left_index || span <= 1e-12 {
            0.0
        } else {
            (position - key_positions[left_index]) / span
        };
        let points: Vec<Point2> = sampled_keys[left_index]
            .iter()
            .zip(&sampled_keys[right_index])
            .map(|(left, right)| *left + (*right - *left) * mix)
            .collect();
        let scale = station_scale(position, scale_start, scale_end, &scale_stations);
        let profile = line_profile_from_points(
            &points,
            Point3::origin(),
            *base.x_dir.as_ref(),
            *base.y_dir.as_ref(),
        )?;
        profiles.push(scale_profile(profile, scale, start + direction * position));
    }
    vcad_kernel::Solid::loft(
        &profiles,
        vcad_kernel::vcad_kernel_sweep::LoftOptions {
            mode: vcad_kernel::vcad_kernel_sweep::LoftMode::Ruled,
            closed: false,
        },
    )
    .map(|inner| Some(Solid { inner }))
    .map_err(|error| JsError::new(&error.to_string()))
}

/// A 3D solid geometry object.
///
/// Create solids from primitives, combine with boolean operations,
/// transform, and extract triangle meshes for rendering.
#[wasm_bindgen]
pub struct Solid {
    inner: vcad_kernel::Solid,
}

fn triangle_area(mesh: &vcad_kernel_tessellate::TriangleMesh) -> f64 {
    mesh.indices
        .chunks_exact(3)
        .map(|triangle| {
            let point = |index: u32| {
                let offset = index as usize * 3;
                Vec3::new(
                    mesh.vertices[offset] as f64,
                    mesh.vertices[offset + 1] as f64,
                    mesh.vertices[offset + 2] as f64,
                )
            };
            let a = point(triangle[0]);
            let b = point(triangle[1]);
            let c = point(triangle[2]);
            0.5 * (b - a).cross(c - a).norm()
        })
        .sum()
}

fn surface_kind_name(kind: vcad_kernel::vcad_kernel_geom::SurfaceKind) -> &'static str {
    use vcad_kernel::vcad_kernel_geom::SurfaceKind;
    match kind {
        SurfaceKind::Plane => "plane",
        SurfaceKind::Cylinder => "cylinder",
        SurfaceKind::Cone => "cone",
        SurfaceKind::Sphere => "sphere",
        SurfaceKind::Torus => "torus",
        SurfaceKind::BSpline => "bspline",
        SurfaceKind::Bilinear => "bilinear",
    }
}

fn topology_metadata(
    solid: &vcad_kernel::Solid,
    segments: u32,
) -> (Vec<u32>, Vec<WasmTopologyEdge>, Vec<WasmTopologyFace>) {
    use std::collections::HashMap;
    use vcad_kernel::vcad_kernel_geom::SurfaceKind;
    use vcad_kernel::vcad_kernel_tessellate::{tessellate_brep_by_face, TessellationParams};

    let Some(brep) = solid.as_brep() else {
        return (Vec::new(), Vec::new(), Vec::new());
    };
    let topological_solid = &brep.topology.solids[brep.solid_id];
    let shell = &brep.topology.shells[topological_solid.outer_shell];
    let face_ordinals: HashMap<_, _> = shell
        .faces
        .iter()
        .enumerate()
        .map(|(index, face_id)| (*face_id, index as u32))
        .collect();

    let per_face = tessellate_brep_by_face(brep, &TessellationParams::from_segments(segments));
    let mut face_ids = Vec::new();
    let mut topology_faces = Vec::with_capacity(per_face.len());
    for (face_id, kind, face_mesh) in &per_face {
        let ordinal = face_ordinals[face_id];
        face_ids.extend(std::iter::repeat_n(ordinal, face_mesh.indices.len() / 3));
        let surface = &brep.geometry.surfaces[brep.topology.faces[*face_id].surface_index];
        let (area, area_exact, radius) = if let Some(sphere) =
            surface
                .as_any()
                .downcast_ref::<vcad_kernel::vcad_kernel_geom::SphereSurface>()
        {
            (
                4.0 * std::f64::consts::PI * sphere.radius * sphere.radius,
                true,
                Some(sphere.radius),
            )
        } else if let Some(cylinder) = surface
            .as_any()
            .downcast_ref::<vcad_kernel::vcad_kernel_geom::CylinderSurface>(
        ) {
            let mut minimum = f64::INFINITY;
            let mut maximum = f64::NEG_INFINITY;
            for (_, vertex) in &brep.topology.vertices {
                let point = vertex.point;
                let height = (point - cylinder.center).dot(cylinder.axis.as_ref());
                minimum = minimum.min(height);
                maximum = maximum.max(height);
            }
            (
                2.0 * std::f64::consts::PI * cylinder.radius * (maximum - minimum).abs(),
                true,
                Some(cylinder.radius),
            )
        } else {
            let mesh_area = triangle_area(face_mesh);
            let degenerate_cap_radius = (*kind == SurfaceKind::Plane && mesh_area <= 1e-12)
                .then(|| {
                    brep.geometry.surfaces.iter().find_map(|candidate| {
                        candidate
                            .as_any()
                            .downcast_ref::<vcad_kernel::vcad_kernel_geom::CylinderSurface>()
                            .map(|cylinder| cylinder.radius)
                    })
                })
                .flatten();
            if let Some(radius) = degenerate_cap_radius {
                (std::f64::consts::PI * radius * radius, true, None)
            } else {
                (mesh_area, *kind == SurfaceKind::Plane, None)
            }
        };
        topology_faces.push(WasmTopologyFace {
            id: ordinal,
            area,
            area_exact,
            surface_kind: surface_kind_name(*kind).to_string(),
            radius,
        });
    }

    let mut topology_edges = Vec::new();
    for (_, edge) in &brep.topology.edges {
        let half_edge = &brep.topology.half_edges[edge.half_edge];
        let Some(next_id) = half_edge.next else {
            continue;
        };
        let start = brep.topology.vertices[half_edge.origin].point;
        let end = brep.topology.vertices[brep.topology.half_edges[next_id].origin].point;
        let mut adjacent_faces = Vec::with_capacity(2);
        for candidate in [Some(edge.half_edge), half_edge.twin] {
            let Some(candidate) = candidate else { continue };
            let Some(loop_id) = brep.topology.half_edges[candidate].loop_id else {
                continue;
            };
            let Some(face_id) = brep.topology.loops[loop_id].face else {
                continue;
            };
            if let Some(ordinal) = face_ordinals.get(&face_id) {
                adjacent_faces.push(*ordinal);
            }
        }
        adjacent_faces.sort_unstable();
        adjacent_faces.dedup();
        if adjacent_faces.len() != 2 {
            continue;
        }
        let circle = adjacent_faces.iter().find_map(|ordinal| {
            let face_id = shell.faces[*ordinal as usize];
            let surface = &brep.geometry.surfaces[brep.topology.faces[face_id].surface_index];
            surface
                .as_any()
                .downcast_ref::<vcad_kernel::vcad_kernel_geom::CylinderSurface>()
        });
        let (positions, anchor, length, curve_kind, radius) = if (end - start).norm() <= 1e-12 {
            let Some(cylinder) = circle else { continue };
            let axis_distance = (start - cylinder.center).dot(cylinder.axis.as_ref());
            let center = cylinder.center + *cylinder.axis.as_ref() * axis_distance;
            let x_axis = cylinder.ref_dir.as_ref();
            let y_axis = cylinder.axis.as_ref().cross(x_axis);
            let sample_count = segments.max(16) as usize;
            let mut positions = Vec::with_capacity(sample_count * 6);
            for index in 0..sample_count {
                for amount in [index as f64, (index + 1) as f64] {
                    let angle = amount * std::f64::consts::TAU / sample_count as f64;
                    let point = center
                        + *x_axis * (cylinder.radius * angle.cos())
                        + y_axis * (cylinder.radius * angle.sin());
                    positions.extend_from_slice(&[point.x as f32, point.y as f32, point.z as f32]);
                }
            }
            (
                positions,
                vec![start.x as f32, start.y as f32, start.z as f32],
                std::f64::consts::TAU * cylinder.radius,
                "circle".to_string(),
                Some(cylinder.radius),
            )
        } else {
            let (first, second) = if [start.x, start.y, start.z] <= [end.x, end.y, end.z] {
                (start, end)
            } else {
                (end, start)
            };
            let delta = second - first;
            (
                vec![
                    first.x as f32,
                    first.y as f32,
                    first.z as f32,
                    second.x as f32,
                    second.y as f32,
                    second.z as f32,
                ],
                vec![
                    (first.x + delta.x * 0.5) as f32,
                    (first.y + delta.y * 0.5) as f32,
                    (first.z + delta.z * 0.5) as f32,
                ],
                delta.norm(),
                "line".to_string(),
                None,
            )
        };
        topology_edges.push(WasmTopologyEdge {
            id: 0,
            face_ids: adjacent_faces,
            positions,
            anchor,
            length,
            length_exact: true,
            curve_kind,
            radius,
        });
    }
    topology_edges.sort_by(|left, right| {
        left.face_ids.cmp(&right.face_ids).then_with(|| {
            left.positions
                .partial_cmp(&right.positions)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
    });
    for (index, edge) in topology_edges.iter_mut().enumerate() {
        edge.id = index as u32;
    }

    (face_ids, topology_edges, topology_faces)
}

#[wasm_bindgen]
impl Solid {
    // =========================================================================
    // Constructors
    // =========================================================================

    /// Create an empty solid.
    #[wasm_bindgen(js_name = empty)]
    pub fn empty() -> Solid {
        Solid {
            inner: vcad_kernel::Solid::empty(),
        }
    }

    /// Create a box with corner at origin and dimensions (sx, sy, sz).
    #[wasm_bindgen(js_name = cube)]
    pub fn cube(sx: f64, sy: f64, sz: f64) -> Solid {
        let solid = Solid {
            inner: vcad_kernel::Solid::cube(sx, sy, sz),
        };
        let (min, max) = solid.inner.bounding_box();
        web_sys::console::log_1(
            &format!(
                "[WASM] Created cube({},{},{}): bbox=[{:.2},{:.2},{:.2}]->[{:.2},{:.2},{:.2}]",
                sx, sy, sz, min[0], min[1], min[2], max[0], max[1], max[2]
            )
            .into(),
        );
        solid
    }

    /// Create a cylinder along Z axis with given radius and height.
    #[wasm_bindgen(js_name = cylinder)]
    pub fn cylinder(radius: f64, height: f64, segments: Option<u32>) -> Solid {
        let segs = segments.unwrap_or(32);
        let solid = Solid {
            inner: vcad_kernel::Solid::cylinder(radius, height, segs),
        };
        let (min, max) = solid.inner.bounding_box();
        web_sys::console::log_1(&format!(
            "[WASM] Created cylinder(r={}, h={}, segs={}): bbox=[{:.2},{:.2},{:.2}]->[{:.2},{:.2},{:.2}]",
            radius, height, segs, min[0], min[1], min[2], max[0], max[1], max[2]
        ).into());
        solid
    }

    /// Create a sphere centered at origin with given radius.
    #[wasm_bindgen(js_name = sphere)]
    pub fn sphere(radius: f64, segments: Option<u32>) -> Solid {
        Solid {
            inner: vcad_kernel::Solid::sphere(radius, segments.unwrap_or(32)),
        }
    }

    /// Create a cone/frustum along Z axis.
    #[wasm_bindgen(js_name = cone)]
    pub fn cone(radius_bottom: f64, radius_top: f64, height: f64, segments: Option<u32>) -> Solid {
        Solid {
            inner: vcad_kernel::Solid::cone(
                radius_bottom,
                radius_top,
                height,
                segments.unwrap_or(32),
            ),
        }
    }

    /// Create a torus centered at origin with axis along Z.
    #[wasm_bindgen(js_name = torus)]
    pub fn torus(major_radius: f64, minor_radius: f64, segments: Option<u32>) -> Solid {
        Solid {
            inner: vcad_kernel::Solid::torus(major_radius, minor_radius, segments.unwrap_or(32)),
        }
    }

    /// Create a right-triangular-prism wedge with corner at origin.
    #[wasm_bindgen(js_name = wedge)]
    pub fn wedge(sx: f64, sy: f64, sz: f64) -> Solid {
        Solid {
            inner: vcad_kernel::Solid::wedge(sx, sy, sz),
        }
    }

    /// Create a regular n-gonal right prism centered on Z.
    #[wasm_bindgen(js_name = prism)]
    pub fn prism(sides: u32, radius: f64, height: f64) -> Solid {
        Solid {
            inner: vcad_kernel::Solid::prism(sides, radius, height),
        }
    }

    /// Mirror the solid across a plane through `(origin_x, origin_y, origin_z)`
    /// with the given plane normal. Triangle / face winding is automatically
    /// reversed to preserve outward normals.
    #[wasm_bindgen(js_name = mirror)]
    pub fn mirror(
        &self,
        origin_x: f64,
        origin_y: f64,
        origin_z: f64,
        normal_x: f64,
        normal_y: f64,
        normal_z: f64,
    ) -> Solid {
        Solid {
            inner: self.inner.mirror(
                [origin_x, origin_y, origin_z],
                [normal_x, normal_y, normal_z],
            ),
        }
    }

    /// Create a solid by extruding a 2D sketch profile.
    ///
    /// Takes a sketch profile and extrusion direction as JS objects.
    #[wasm_bindgen(js_name = extrude)]
    pub fn extrude(profile_json: String, direction: Vec<f64>) -> Result<Solid, JsError> {
        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|e| JsError::new(&format!("Invalid profile: {}", e)))?;

        if direction.len() != 3 {
            return Err(JsError::new("Direction must have 3 components"));
        }

        let kernel_profile = profile.to_kernel_profile().map_err(|e| JsError::new(&e))?;

        let dir = Vec3::new(direction[0], direction[1], direction[2]);

        let holes = profile.kernel_holes();
        if holes.is_empty() {
            vcad_kernel::Solid::extrude(kernel_profile, dir)
        } else {
            vcad_kernel::Solid::extrude_with_holes(kernel_profile, &holes, dir)
        }
        .map(|inner| Solid { inner })
        .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Create a solid by extruding a 2D sketch profile with twist and/or scale.
    ///
    /// Takes a sketch profile, extrusion direction, twist angle (radians),
    /// and scale factor at the end (1.0 = no taper).
    #[wasm_bindgen(js_name = extrudeWithOptions)]
    pub fn extrude_with_options(
        profile_json: String,
        direction: Vec<f64>,
        twist_angle: f64,
        scale_end: f64,
    ) -> Result<Solid, JsError> {
        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|e| JsError::new(&format!("Invalid profile: {}", e)))?;

        if direction.len() != 3 {
            return Err(JsError::new("Direction must have 3 components"));
        }
        profile.reject_holes("extrude with twist or taper")?;

        let kernel_profile = profile.to_kernel_profile().map_err(|e| JsError::new(&e))?;

        let dir = Vec3::new(direction[0], direction[1], direction[2]);

        vcad_kernel::Solid::extrude_with_options(kernel_profile, dir, twist_angle, scale_end)
            .map(|inner| Solid { inner })
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Create a solid by revolving a 2D sketch profile around an axis.
    ///
    /// Takes a sketch profile, axis origin, axis direction, and angle in degrees.
    #[wasm_bindgen(js_name = revolve)]
    pub fn revolve(
        profile_json: String,
        axis_origin: Vec<f64>,
        axis_dir: Vec<f64>,
        angle_deg: f64,
    ) -> Result<Solid, JsError> {
        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|e| JsError::new(&format!("Invalid profile: {}", e)))?;

        if axis_origin.len() != 3 || axis_dir.len() != 3 {
            return Err(JsError::new(
                "Axis origin and direction must have 3 components",
            ));
        }
        profile.reject_holes("revolve")?;

        let kernel_profile = profile.to_kernel_profile().map_err(|e| JsError::new(&e))?;

        let origin = Point3::new(axis_origin[0], axis_origin[1], axis_origin[2]);
        let dir = Vec3::new(axis_dir[0], axis_dir[1], axis_dir[2]);

        vcad_kernel::Solid::revolve(kernel_profile, origin, dir, angle_deg)
            .map(|inner| Solid { inner })
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Create a solid by sweeping a profile along a line path.
    ///
    /// Takes a sketch profile and path endpoints.
    #[wasm_bindgen(js_name = sweepLine)]
    pub fn sweep_line(
        profile_json: String,
        start: Vec<f64>,
        end: Vec<f64>,
        twist_angle: Option<f64>,
        scale_start: Option<f64>,
        scale_end: Option<f64>,
        orientation: Option<f64>,
        scale_stations_json: Option<String>,
        profile_stations_json: Option<String>,
        _frame_mode: Option<u32>,
        _up_direction: Vec<f64>,
        _guide_points: Vec<f64>,
    ) -> Result<Solid, JsError> {
        use vcad_kernel::vcad_kernel_geom::Line3d;
        use vcad_kernel::vcad_kernel_sweep::SweepOptions;

        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|e| JsError::new(&format!("Invalid profile: {}", e)))?;

        if start.len() != 3 || end.len() != 3 {
            return Err(JsError::new("Start and end must have 3 components"));
        }
        profile.reject_holes("sweep")?;

        let start_point = Point3::new(start[0], start[1], start[2]);
        let end_point = Point3::new(end[0], end[1], end[2]);
        if let Some(solid) = loft_line_stations(
            profile.clone(),
            start_point,
            end_point,
            scale_start.unwrap_or(1.0),
            scale_end.unwrap_or(1.0),
            scale_stations_json,
            profile_stations_json,
        )? {
            return Ok(solid);
        }

        // Use centered profile so it wraps around the path properly
        let kernel_profile = profile
            .to_kernel_profile_centered()
            .map_err(|e| JsError::new(&e))?;

        let path = Line3d::from_points(start_point, end_point);

        let options = SweepOptions {
            twist_angle: twist_angle.unwrap_or(0.0),
            scale_start: scale_start.unwrap_or(1.0),
            scale_end: scale_end.unwrap_or(1.0),
            orientation_angle: orientation.unwrap_or(0.0),
            ..Default::default()
        };

        vcad_kernel::Solid::sweep(kernel_profile, &path, options)
            .map(|inner| Solid { inner })
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Create a solid by sweeping a profile along a helix path.
    ///
    /// Takes a sketch profile and helix parameters.
    #[wasm_bindgen(js_name = sweepHelix)]
    #[allow(clippy::too_many_arguments)]
    pub fn sweep_helix(
        profile_json: String,
        radius: f64,
        pitch: f64,
        height: f64,
        turns: f64,
        twist_angle: Option<f64>,
        scale_start: Option<f64>,
        scale_end: Option<f64>,
        path_segments: Option<u32>,
        arc_segments: Option<u32>,
        orientation: Option<f64>,
    ) -> Result<Solid, JsError> {
        use vcad_kernel::vcad_kernel_sweep::{Helix, SweepOptions};

        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|e| JsError::new(&format!("Invalid profile: {}", e)))?;
        profile.reject_holes("sweep")?;

        // Use centered profile so it wraps around the helix path properly
        let kernel_profile = profile
            .to_kernel_profile_centered()
            .map_err(|e| JsError::new(&e))?;

        let path = Helix::new(radius, pitch, height, turns);

        let options = SweepOptions {
            twist_angle: twist_angle.unwrap_or(0.0),
            scale_start: scale_start.unwrap_or(1.0),
            scale_end: scale_end.unwrap_or(1.0),
            path_segments: path_segments.unwrap_or(0),
            arc_segments: arc_segments.unwrap_or(8),
            orientation_angle: orientation.unwrap_or(0.0),
        };

        vcad_kernel::Solid::sweep(kernel_profile, &path, options)
            .map(|inner| Solid { inner })
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Create a solid by lofting between multiple profiles.
    ///
    /// Takes an array of sketch profiles (minimum 2).
    #[wasm_bindgen(js_name = loft)]
    pub fn loft(profiles_json: String, closed: Option<bool>) -> Result<Solid, JsError> {
        use vcad_kernel::vcad_kernel_sweep::{LoftMode, LoftOptions};

        let profiles: Vec<WasmSketchProfile> = serde_json::from_str(&profiles_json)
            .map_err(|e| JsError::new(&format!("Invalid profiles: {}", e)))?;

        if profiles.len() < 2 {
            return Err(JsError::new("Loft requires at least 2 profiles"));
        }
        for p in &profiles {
            p.reject_holes("loft")?;
        }

        let kernel_profiles: Result<Vec<_>, _> =
            profiles.iter().map(|p| p.to_kernel_profile()).collect();
        let kernel_profiles = kernel_profiles.map_err(|e| JsError::new(&e))?;

        let options = LoftOptions {
            mode: LoftMode::Ruled,
            closed: closed.unwrap_or(false),
        };

        vcad_kernel::Solid::loft(&kernel_profiles, options)
            .map(|inner| Solid { inner })
            .map_err(|e| JsError::new(&e.to_string()))
    }

    // =========================================================================
    // Boolean operations
    // =========================================================================

    /// Boolean union (self ∪ other).
    ///
    /// Returns a JS error (instead of trapping the WASM instance) when the
    /// kernel reports a boolean failure.
    #[wasm_bindgen(js_name = union)]
    pub fn union(&self, other: &Solid) -> Result<Solid, JsError> {
        Ok(Solid {
            inner: self
                .inner
                .try_union(&other.inner)
                .map_err(|e| JsError::new(&e.to_string()))?,
        })
    }

    /// Boolean difference (self − other).
    ///
    /// Returns a JS error (instead of trapping the WASM instance) when the
    /// kernel reports a boolean failure.
    #[wasm_bindgen(js_name = difference)]
    pub fn difference(&self, other: &Solid) -> Result<Solid, JsError> {
        // Log input solid info with more detail
        let self_tris = self.inner.num_triangles();
        let other_tris = other.inner.num_triangles();

        // Get detailed info about inputs
        let (self_min, self_max) = self.inner.bounding_box();
        let (other_min, other_max) = other.inner.bounding_box();

        web_sys::console::log_1(&format!(
            "[WASM] Boolean difference inputs:\n  self: {} tris, bbox=[{:.2},{:.2},{:.2}]->[{:.2},{:.2},{:.2}]\n  other: {} tris, bbox=[{:.2},{:.2},{:.2}]->[{:.2},{:.2},{:.2}]",
            self_tris, self_min[0], self_min[1], self_min[2], self_max[0], self_max[1], self_max[2],
            other_tris, other_min[0], other_min[1], other_min[2], other_max[0], other_max[1], other_max[2]
        ).into());

        let result = Solid {
            inner: self
                .inner
                .try_difference(&other.inner)
                .map_err(|e| JsError::new(&e.to_string()))?,
        };

        let result_tris_before_mesh = result.inner.num_triangles();
        let (result_min, result_max) = result.inner.bounding_box();
        web_sys::console::log_1(
            &format!(
                "[WASM] Difference result: {} tris, bbox=[{:.2},{:.2},{:.2}]->[{:.2},{:.2},{:.2}]",
                result_tris_before_mesh,
                result_min[0],
                result_min[1],
                result_min[2],
                result_max[0],
                result_max[1],
                result_max[2]
            )
            .into(),
        );

        let mesh = result.inner.to_mesh(32);
        let tris = mesh.indices.len() / 3;
        let verts = mesh.vertices.len() / 3;
        web_sys::console::log_1(
            &format!(
                "[WASM] Difference mesh (32 segs): {} triangles, {} vertices",
                tris, verts
            )
            .into(),
        );

        // Analyze the mesh to find any problematic triangles
        // Check for triangles with NEGATIVE x or y coordinates (the "ears")
        let mut negative_x_tris = Vec::new();
        let mut negative_y_tris = Vec::new();
        // Also check triangles on z=0 plane (bottom cap)
        let mut z0_cap_tris = Vec::new();

        for i in (0..mesh.indices.len()).step_by(3) {
            let i0 = mesh.indices[i] as usize * 3;
            let i1 = mesh.indices[i + 1] as usize * 3;
            let i2 = mesh.indices[i + 2] as usize * 3;
            let v0 = [
                mesh.vertices[i0],
                mesh.vertices[i0 + 1],
                mesh.vertices[i0 + 2],
            ];
            let v1 = [
                mesh.vertices[i1],
                mesh.vertices[i1 + 1],
                mesh.vertices[i1 + 2],
            ];
            let v2 = [
                mesh.vertices[i2],
                mesh.vertices[i2 + 1],
                mesh.vertices[i2 + 2],
            ];

            // Check for any vertex with negative x
            if v0[0] < -0.01 || v1[0] < -0.01 || v2[0] < -0.01 {
                negative_x_tris.push(format!(
                    "({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})",
                    v0[0], v0[1], v0[2], v1[0], v1[1], v1[2], v2[0], v2[1], v2[2]
                ));
            }

            // Check for any vertex with negative y
            if v0[1] < -0.01 || v1[1] < -0.01 || v2[1] < -0.01 {
                negative_y_tris.push(format!(
                    "({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})",
                    v0[0], v0[1], v0[2], v1[0], v1[1], v1[2], v2[0], v2[1], v2[2]
                ));
            }

            // Check triangles on z=0 plane (the bottom cap where ears appear)
            if v0[2].abs() < 0.1 && v1[2].abs() < 0.1 && v2[2].abs() < 0.1 {
                z0_cap_tris.push(format!(
                    "({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})-({:.2},{:.2},{:.2})",
                    v0[0], v0[1], v0[2], v1[0], v1[1], v1[2], v2[0], v2[1], v2[2]
                ));
            }
        }

        web_sys::console::log_1(
            &format!(
                "[WASM] Triangles with NEGATIVE x: {}",
                negative_x_tris.len()
            )
            .into(),
        );
        for (i, tri) in negative_x_tris.iter().take(10).enumerate() {
            web_sys::console::log_1(&format!("[WASM]   neg_x tri {}: {}", i, tri).into());
        }

        web_sys::console::log_1(
            &format!(
                "[WASM] Triangles with NEGATIVE y: {}",
                negative_y_tris.len()
            )
            .into(),
        );
        for (i, tri) in negative_y_tris.iter().take(10).enumerate() {
            web_sys::console::log_1(&format!("[WASM]   neg_y tri {}: {}", i, tri).into());
        }

        web_sys::console::log_1(
            &format!("[WASM] Triangles on z=0 cap: {}", z0_cap_tris.len()).into(),
        );
        for (i, tri) in z0_cap_tris.iter().enumerate() {
            web_sys::console::log_1(&format!("[WASM]   z0_cap tri {}: {}", i, tri).into());
        }

        // Compute actual bounding box from mesh
        let mut min_x = f32::INFINITY;
        let mut max_x = f32::NEG_INFINITY;
        let mut min_y = f32::INFINITY;
        let mut max_y = f32::NEG_INFINITY;
        let mut min_z = f32::INFINITY;
        let mut max_z = f32::NEG_INFINITY;
        for i in (0..mesh.vertices.len()).step_by(3) {
            let x = mesh.vertices[i];
            let y = mesh.vertices[i + 1];
            let z = mesh.vertices[i + 2];
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
            min_z = min_z.min(z);
            max_z = max_z.max(z);
        }
        web_sys::console::log_1(
            &format!(
                "[WASM] Mesh BBox: [{:.2},{:.2},{:.2}] -> [{:.2},{:.2},{:.2}]",
                min_x, min_y, min_z, max_x, max_y, max_z
            )
            .into(),
        );

        Ok(result)
    }

    /// Boolean intersection (self ∩ other).
    ///
    /// Returns a JS error (instead of trapping the WASM instance) when the
    /// kernel reports a boolean failure.
    #[wasm_bindgen(js_name = intersection)]
    pub fn intersection(&self, other: &Solid) -> Result<Solid, JsError> {
        Ok(Solid {
            inner: self
                .inner
                .try_intersection(&other.inner)
                .map_err(|e| JsError::new(&e.to_string()))?,
        })
    }

    // =========================================================================
    // Transforms
    // =========================================================================

    /// Translate the solid by (x, y, z).
    #[wasm_bindgen(js_name = translate)]
    pub fn translate(&self, x: f64, y: f64, z: f64) -> Solid {
        Solid {
            inner: self.inner.translate(x, y, z),
        }
    }

    /// Rotate the solid by angles in degrees around X, Y, Z axes.
    #[wasm_bindgen(js_name = rotate)]
    pub fn rotate(&self, x_deg: f64, y_deg: f64, z_deg: f64) -> Solid {
        Solid {
            inner: self.inner.rotate(x_deg, y_deg, z_deg),
        }
    }

    /// Scale the solid by (x, y, z).
    #[wasm_bindgen(js_name = scale)]
    pub fn scale(&self, x: f64, y: f64, z: f64) -> Solid {
        Solid {
            inner: self.inner.scale(x, y, z),
        }
    }

    // =========================================================================
    // Fillet & Chamfer
    // =========================================================================

    /// Chamfer all edges of the solid by the given distance.
    #[wasm_bindgen(js_name = chamfer)]
    pub fn chamfer(&self, distance: f64) -> Solid {
        Solid {
            inner: self.inner.chamfer(distance),
        }
    }

    /// Per-edge blend on query-selected edges with a keyed profile.
    ///
    /// `spec_json` is a JSON object `{ "edges": EdgeQuery, "profile":
    /// BlendProfile }` using the IR types (serde-tagged with `type`).
    /// shape 0 = chamfer, 1 = fillet; size = chamfer leg / fillet radius.
    #[wasm_bindgen(js_name = edgeBlend)]
    pub fn edge_blend(&self, spec_json: &str) -> Result<Solid, JsError> {
        #[derive(serde::Deserialize)]
        struct Spec {
            edges: vcad_ir::EdgeQuery,
            profile: vcad_ir::BlendProfile,
        }
        let spec: Spec = serde_json::from_str(spec_json)
            .map_err(|e| JsError::new(&format!("invalid edge blend spec: {e}")))?;
        let (query, keys) = kernel_blend_args(&spec.edges, &spec.profile);
        Ok(Solid {
            inner: self.inner.edge_blend(&query, &keys),
        })
    }

    /// Fillet all edges of the solid with the given radius.
    #[wasm_bindgen(js_name = fillet)]
    pub fn fillet(&self, radius: f64) -> Solid {
        Solid {
            inner: self.inner.fillet(radius),
        }
    }

    /// Shell (hollow) the solid by offsetting all faces inward.
    #[wasm_bindgen(js_name = shell)]
    pub fn shell(&self, thickness: f64) -> Solid {
        Solid {
            inner: self.inner.shell(thickness),
        }
    }

    // =========================================================================
    // Pattern operations
    // =========================================================================

    /// Create a linear pattern of the solid along a direction.
    ///
    /// # Arguments
    ///
    /// * `dir_x`, `dir_y`, `dir_z` - Direction vector
    /// * `count` - Number of copies (including original)
    /// * `spacing` - Distance between copies
    #[wasm_bindgen(js_name = linearPattern)]
    pub fn linear_pattern(
        &self,
        dir_x: f64,
        dir_y: f64,
        dir_z: f64,
        count: u32,
        spacing: f64,
    ) -> Solid {
        use vcad_kernel::vcad_kernel_math::Vec3;
        Solid {
            inner: self
                .inner
                .linear_pattern(Vec3::new(dir_x, dir_y, dir_z), count, spacing),
        }
    }

    /// Create a circular pattern of the solid around an axis.
    ///
    /// # Arguments
    ///
    /// * `axis_origin_x/y/z` - A point on the rotation axis
    /// * `axis_dir_x/y/z` - Direction of the rotation axis
    /// * `count` - Number of copies (including original)
    /// * `angle_deg` - Total angle span in degrees
    #[wasm_bindgen(js_name = circularPattern)]
    #[allow(clippy::too_many_arguments)]
    pub fn circular_pattern(
        &self,
        axis_origin_x: f64,
        axis_origin_y: f64,
        axis_origin_z: f64,
        axis_dir_x: f64,
        axis_dir_y: f64,
        axis_dir_z: f64,
        count: u32,
        angle_deg: f64,
    ) -> Solid {
        use vcad_kernel::vcad_kernel_math::{Point3, Vec3};
        Solid {
            inner: self.inner.circular_pattern(
                Point3::new(axis_origin_x, axis_origin_y, axis_origin_z),
                Vec3::new(axis_dir_x, axis_dir_y, axis_dir_z),
                count,
                angle_deg,
            ),
        }
    }

    // =========================================================================
    // Queries
    // =========================================================================

    /// Check if the solid is empty (has no geometry).
    #[wasm_bindgen(js_name = isEmpty)]
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// Get the triangle mesh representation.
    ///
    /// Returns a JS object with `positions` (Float32Array) and `indices` (Uint32Array).
    ///
    /// Runs the tessellator output through
    /// [`vcad_kernel_tessellate::render_bake`] so the emitted mesh carries
    /// angle-based creased vertex normals. Every downstream renderer —
    /// three.js today, wgpu / STL / GLB / ray tracer later — consumes this
    /// same attribute layout without recomputing anything.
    #[wasm_bindgen(js_name = getMesh)]
    pub fn get_mesh(&self, segments: Option<u32>) -> JsValue {
        let segments = segments.unwrap_or(32);
        let (mut face_ids, topology_edges, topology_faces) =
            topology_metadata(&self.inner, segments);
        let mut mesh = self.inner.to_mesh(segments);
        vcad_kernel_tessellate::render_bake_default(&mut mesh);
        let num_verts = mesh.vertices.len() / 3;

        // Validate indices - check for out-of-bounds references
        let mut max_index = 0u32;
        let mut invalid_count = 0usize;
        for &idx in &mesh.indices {
            if idx as usize >= num_verts {
                invalid_count += 1;
            }
            if idx > max_index {
                max_index = idx;
            }
        }

        if invalid_count > 0 {
            web_sys::console::error_1(
                &format!(
                    "[WASM] getMesh: {} invalid indices (max index {} but only {} vertices)",
                    invalid_count, max_index, num_verts
                )
                .into(),
            );
        }

        let normals = if mesh.normals.len() == mesh.vertices.len() {
            Some(mesh.normals)
        } else {
            None
        };
        let face_kinds = if mesh.face_kinds.len() == mesh.indices.len() / 3 {
            Some(mesh.face_kinds)
        } else {
            None
        };
        face_ids.resize(
            mesh.indices.len() / 3,
            face_ids.last().copied().unwrap_or(0),
        );
        let wasm_mesh = WasmMesh {
            positions: mesh.vertices,
            indices: mesh.indices,
            normals,
            face_kinds,
            face_ids: (!face_ids.is_empty()).then_some(face_ids),
            topology_edges: (!topology_edges.is_empty()).then_some(topology_edges),
            topology_faces: (!topology_faces.is_empty()).then_some(topology_faces),
        };
        serde_wasm_bindgen::to_value(&wasm_mesh).unwrap_or(JsValue::NULL)
    }

    /// Compute the volume of the solid.
    #[wasm_bindgen(js_name = volume)]
    pub fn volume(&self) -> f64 {
        self.inner.volume()
    }

    /// Compute the surface area of the solid.
    #[wasm_bindgen(js_name = surfaceArea)]
    pub fn surface_area(&self) -> f64 {
        self.inner.surface_area()
    }

    /// Get the bounding box as [minX, minY, minZ, maxX, maxY, maxZ].
    #[wasm_bindgen(js_name = boundingBox)]
    pub fn bounding_box(&self) -> Vec<f64> {
        let (min, max) = self.inner.bounding_box();
        vec![min[0], min[1], min[2], max[0], max[1], max[2]]
    }

    /// Minimum signed distance to another solid in mm (see `WasmClearance`):
    /// positive separation, negative penetration depth on intersection.
    #[wasm_bindgen(js_name = clearance)]
    pub fn clearance(&self, other: &Solid) -> Result<JsValue, JsError> {
        let r = self
            .inner
            .clearance(&other.inner)
            .ok_or_else(|| JsError::new("clearance requires two non-empty solids"))?;
        serde_wasm_bindgen::to_value(&WasmClearance::from(r))
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Run DFM directly on this solid's BRep.
    ///
    /// Returns the report JSON; if the solid is mesh-only (e.g. after
    /// a boolean — see issue #186), the report has an empty `issues`
    /// array and a note in `rule_pack_name`.
    ///
    /// `root_node_id` (when > 0) attributes every face in the BRep to
    /// that IR node — the v1 coarse provenance heuristic. Pass 0 to
    /// skip provenance entirely; emitted issues will then carry
    /// `origin_op: null` and `dfm_apply_fix` will only be able to act
    /// on rules whose fix kind is `manual`.
    #[wasm_bindgen(js_name = runDfm)]
    pub fn run_dfm(
        &self,
        process: &str,
        rule_pack_toml: &str,
        root_node_id: u64,
    ) -> Result<String, JsError> {
        let p = vcad_kernel::vcad_kernel_dfm::Process::from_str(process)
            .ok_or_else(|| JsError::new(&format!("unknown process: {}", process)))?;
        let pack = if rule_pack_toml.trim().is_empty() {
            vcad_kernel::vcad_kernel_dfm::RulePack::default_for(p)
        } else {
            vcad_kernel::vcad_kernel_dfm::RulePack::from_toml(rule_pack_toml)
                .map_err(|e| JsError::new(&format!("rule pack parse: {}", e)))?
        };
        let Some(brep) = self.inner.as_brep() else {
            return Ok(format!(
                r#"{{"process":"{}","rule_pack_name":"(mesh-only solid; DFM skipped)","rule_pack_version":"1","issues":[],"cost_estimate":null}}"#,
                p.as_str()
            ));
        };
        let provenance = if root_node_id > 0 {
            Some(
                vcad_kernel::vcad_kernel_dfm::geom::provenance::ProvenanceMap::single_root(
                    brep,
                    root_node_id,
                ),
            )
        } else {
            None
        };
        let report = vcad_kernel::vcad_kernel_dfm::run_dfm(brep, provenance.as_ref(), p, &pack);
        serde_json::to_string(&report).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Get the center of mass as [x, y, z].
    #[wasm_bindgen(js_name = centerOfMass)]
    pub fn center_of_mass(&self) -> Vec<f64> {
        let com = self.inner.center_of_mass();
        vec![com[0], com[1], com[2]]
    }

    /// Get the number of triangles in the tessellated mesh.
    #[wasm_bindgen(js_name = numTriangles)]
    pub fn num_triangles(&self) -> usize {
        self.inner.num_triangles()
    }

    /// Return mesh boundary edges as a flat float array
    /// `[x0, y0, z0, x1, y1, z1, ...]` with each pair of 3-component
    /// positions defining one edge segment. Used by the viewport's
    /// "show boundary edges" overlay to surface tessellation holes.
    ///
    /// Closed, manifold meshes return an empty array; each entry means
    /// there's a hole in the mesh.
    #[wasm_bindgen(js_name = boundaryEdges)]
    pub fn boundary_edges(&self, segments: Option<u32>) -> Vec<f32> {
        // A retained B-rep is closed by construction. Tessellation can split
        // shared analytic edges into different sample counts, which makes a
        // triangle-only incidence check report false boundaries.
        if self.inner.as_brep().is_some() {
            return Vec::new();
        }
        let mesh = self.inner.to_mesh(segments.unwrap_or(32));
        let positions = mesh.boundary_edge_positions();
        let mut out = Vec::with_capacity(positions.len() * 6);
        for [a, b] in positions {
            out.extend_from_slice(&a);
            out.extend_from_slice(&b);
        }
        out
    }

    /// Generate a section view by cutting the solid with a plane.
    ///
    /// # Arguments
    /// * `plane_json` - JSON string with plane definition: `{"origin": [x,y,z], "normal": [x,y,z], "up": [x,y,z]}`
    /// * `hatch_json` - Optional JSON string with hatch pattern: `{"spacing": f64, "angle": f64}`
    /// * `segments` - Number of segments for tessellation (optional, default 32)
    ///
    /// # Returns
    /// A JS object containing the section view with curves, hatch lines, and bounds.
    #[wasm_bindgen(js_name = sectionView)]
    pub fn section_view(
        &self,
        plane_json: &str,
        hatch_json: Option<String>,
        segments: Option<u32>,
    ) -> JsValue {
        use vcad_kernel_drafting::{section_mesh, HatchPattern, SectionPlane};

        // Parse plane
        let plane: SectionPlane = match serde_json::from_str(plane_json) {
            Ok(p) => p,
            Err(_) => return JsValue::NULL,
        };

        // Parse optional hatch pattern
        let hatch: Option<HatchPattern> = hatch_json.and_then(|h| serde_json::from_str(&h).ok());

        // Get mesh
        let mesh = self.inner.to_mesh(segments.unwrap_or(32));

        // Generate section view
        let view = section_mesh(&mesh, &plane, hatch.as_ref());

        serde_wasm_bindgen::to_value(&view).unwrap_or(JsValue::NULL)
    }

    /// Generate a horizontal section view at a given Z height.
    ///
    /// Convenience method that creates a horizontal section plane.
    #[wasm_bindgen(js_name = horizontalSection)]
    pub fn horizontal_section(
        &self,
        z: f64,
        hatch_spacing: Option<f64>,
        hatch_angle: Option<f64>,
        segments: Option<u32>,
    ) -> JsValue {
        use vcad_kernel_drafting::{section_mesh, HatchPattern, SectionPlane};

        let plane = SectionPlane::horizontal(z);

        let hatch = hatch_spacing.map(|spacing| {
            HatchPattern::new(spacing, hatch_angle.unwrap_or(std::f64::consts::FRAC_PI_4))
        });

        let mesh = self.inner.to_mesh(segments.unwrap_or(32));
        let view = section_mesh(&mesh, &plane, hatch.as_ref());

        serde_wasm_bindgen::to_value(&view).unwrap_or(JsValue::NULL)
    }

    /// Project the solid to a 2D view for technical drawing.
    ///
    /// # Arguments
    /// * `view_direction` - View direction: "front", "back", "top", "bottom", "left", "right", or "isometric"
    /// * `segments` - Number of segments for tessellation (optional, default 32)
    ///
    /// # Returns
    /// A JS object containing the projected view with edges and bounds.
    #[wasm_bindgen(js_name = projectView)]
    pub fn project_view(&self, view_direction: &str, segments: Option<u32>) -> JsValue {
        use vcad_kernel_drafting::{project_mesh, ViewDirection};

        let mesh = self.inner.to_mesh(segments.unwrap_or(32));

        let view_dir = match view_direction.to_lowercase().as_str() {
            "front" => ViewDirection::Front,
            "back" => ViewDirection::Back,
            "top" => ViewDirection::Top,
            "bottom" => ViewDirection::Bottom,
            "left" => ViewDirection::Left,
            "right" => ViewDirection::Right,
            "isometric" => ViewDirection::ISOMETRIC_STANDARD,
            _ => ViewDirection::Front,
        };

        let view = project_mesh(&mesh, view_dir);
        serde_wasm_bindgen::to_value(&view).unwrap_or(JsValue::NULL)
    }

    /// Export the solid to STEP format.
    ///
    /// # Returns
    /// A byte buffer containing the STEP file data.
    ///
    /// # Errors
    /// Returns an error if the solid has no B-rep data (e.g., mesh-only after certain operations).
    #[wasm_bindgen(js_name = toStepBuffer)]
    pub fn to_step_buffer(&self) -> Result<Vec<u8>, JsError> {
        self.inner
            .to_step_buffer()
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Export to STEP and consume the wrapper in one operation.
    #[wasm_bindgen(js_name = intoStepBuffer)]
    pub fn into_step_buffer(self) -> Result<Vec<u8>, JsError> {
        self.inner
            .to_step_buffer()
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Check if the solid can be exported to STEP format.
    ///
    /// Returns `true` if the solid has B-rep data available for STEP export.
    /// Returns `false` for mesh-only or empty solids.
    #[wasm_bindgen(js_name = canExportStep)]
    pub fn can_export_step(&self) -> bool {
        self.inner.can_export_step()
    }

    // =========================================================================
    // Text operations
    // =========================================================================

    /// Create a solid by extruding text as 2D profiles.
    ///
    /// Converts text to sketch profiles and extrudes them. Each character glyph
    /// becomes a separate profile, and holes (like in 'O') are subtracted.
    ///
    /// # Arguments
    ///
    /// * `text` - The text string to convert
    /// * `origin` - Origin point [x, y, z]
    /// * `x_dir` - X direction vector [x, y, z]
    /// * `y_dir` - Y direction vector [x, y, z]
    /// * `direction` - Extrusion direction [x, y, z] (magnitude = extrusion depth)
    /// * `height` - Text height in mm
    /// * `font` - Font name (currently only "sans-serif" supported)
    /// * `alignment` - Text alignment: "left", "center", or "right"
    /// * `letter_spacing` - Letter spacing multiplier (1.0 = normal)
    /// * `line_spacing` - Line spacing multiplier (1.0 = normal)
    #[wasm_bindgen(js_name = textExtrude)]
    #[allow(clippy::too_many_arguments)]
    pub fn text_extrude(
        text: &str,
        origin: Vec<f64>,
        x_dir: Vec<f64>,
        y_dir: Vec<f64>,
        direction: Vec<f64>,
        height: f64,
        font: Option<String>,
        alignment: Option<String>,
        letter_spacing: Option<f64>,
        line_spacing: Option<f64>,
    ) -> Result<Solid, JsError> {
        use vcad_kernel::vcad_kernel_text::{FontRegistry, TextAlignment};

        if origin.len() != 3 || x_dir.len() != 3 || y_dir.len() != 3 || direction.len() != 3 {
            return Err(JsError::new(
                "origin, x_dir, y_dir, and direction must have 3 components",
            ));
        }

        // Parse alignment
        let align = match alignment.as_deref() {
            Some("center") => TextAlignment::Center,
            Some("right") => TextAlignment::Right,
            _ => TextAlignment::Left,
        };

        // Get font (only builtin sans-serif for now)
        let font_ref = match font.as_deref() {
            Some("sans-serif") | None => FontRegistry::builtin_sans(),
            Some(name) => {
                return Err(JsError::new(&format!(
                    "Unknown font: {}. Use 'sans-serif' or omit for default.",
                    name
                )));
            }
        };

        let letter_sp = letter_spacing.unwrap_or(1.0);
        let line_sp = line_spacing.unwrap_or(1.0);

        // Convert text to profiles
        let profiles = vcad_kernel::vcad_kernel_text::text_to_profiles(
            text, font_ref, height, letter_sp, line_sp, align,
        );

        if profiles.is_empty() {
            return Ok(Solid {
                inner: vcad_kernel::Solid::empty(),
            });
        }

        // Separate profiles into outer contours and holes based on winding order
        let dir = Vec3::new(direction[0], direction[1], direction[2]);
        let origin_pt = Point3::new(origin[0], origin[1], origin[2]);
        let x_vec = Vec3::new(x_dir[0], x_dir[1], x_dir[2]);
        let y_vec = Vec3::new(y_dir[0], y_dir[1], y_dir[2]);

        // Determine holes by geometric containment
        // A profile is a hole if it's contained inside another profile
        let n = profiles.len();
        let mut is_hole = vec![false; n];

        for i in 0..n {
            for j in 0..n {
                if i != j && profiles[i].is_contained_in(&profiles[j]) {
                    is_hole[i] = true;
                    break;
                }
            }
        }

        let mut outer_profiles = Vec::new();
        let mut hole_profiles = Vec::new();

        for (i, profile) in profiles.into_iter().enumerate() {
            if is_hole[i] {
                hole_profiles.push(profile);
            } else {
                outer_profiles.push(profile);
            }
        }

        // Merge outer profile meshes (bypass boolean union)
        let mut all_vertices: Vec<f32> = Vec::new();
        let mut all_normals: Vec<f32> = Vec::new();
        let mut all_indices: Vec<u32> = Vec::new();

        for profile in &outer_profiles {
            let world_profile = profile.transform(origin_pt, x_vec, y_vec);

            if let Ok(solid) = vcad_kernel::Solid::extrude(world_profile, dir) {
                let mesh = solid.to_mesh(32);
                let vertex_offset = (all_vertices.len() / 3) as u32;
                all_vertices.extend_from_slice(&mesh.vertices);
                all_normals.extend_from_slice(&mesh.normals);
                for idx in mesh.indices {
                    all_indices.push(idx + vertex_offset);
                }
            }
        }

        // Create solid from merged outer meshes
        let mut result = if !all_vertices.is_empty() {
            let merged_mesh = vcad_kernel_tessellate::TriangleMesh {
                vertices: all_vertices,
                indices: all_indices,
                normals: all_normals,
                face_kinds: Vec::new(),
            };
            Some(vcad_kernel::Solid::from_mesh(merged_mesh))
        } else {
            None
        };

        // Subtract holes using boolean difference
        if let Some(solid) = result.take() {
            let mut current = solid;
            let hole_dir = dir * 1.1;
            let hole_offset = dir * -0.05;

            for profile in &hole_profiles {
                let offset_origin = origin_pt + hole_offset;
                let world_profile = profile.transform(offset_origin, x_vec, y_vec);

                if let Ok(hole_solid) = vcad_kernel::Solid::extrude(world_profile, hole_dir) {
                    current = current.difference(&hole_solid);
                }
            }
            result = Some(current);
        }

        Ok(Solid {
            inner: result.unwrap_or_else(vcad_kernel::Solid::empty),
        })
    }

    /// Reopen one retained B-rep body from a STEP buffer.
    #[wasm_bindgen(js_name = fromStepBuffer)]
    pub fn from_step_buffer(data: &[u8], body_index: usize) -> Result<Solid, JsError> {
        let mut solids = vcad_kernel::Solid::from_step_buffer_all(data)
            .map_err(|error| JsError::new(&error.to_string()))?;
        if body_index >= solids.len() {
            return Err(JsError::new("STEP body index is out of range"));
        }
        Ok(Solid {
            inner: solids.swap_remove(body_index),
        })
    }

    /// Sweep along a JSON line/arc path. The vendored kernel samples the
    /// supplied path into a deterministic polyline before creating the B-rep.
    #[wasm_bindgen(js_name = sweepComposite)]
    #[allow(clippy::too_many_arguments)]
    pub fn sweep_composite(
        profile_json: String,
        segments_json: String,
        twist_angle: Option<f64>,
        scale_start: Option<f64>,
        scale_end: Option<f64>,
        path_segments: Option<u32>,
        arc_segments: Option<u32>,
        orientation: Option<f64>,
        _scale_stations_json: String,
        _profile_stations_json: String,
        _frame_mode: Option<u32>,
        _up_direction: Vec<f64>,
        _guide_points: Vec<f64>,
        _continuity_mode: Option<u32>,
        _tangent_tolerance_degrees: Option<f64>,
    ) -> Result<Solid, JsError> {
        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|error| JsError::new(&format!("Invalid profile: {error}")))?;
        profile.reject_holes("sweep")?;
        let path = PolylineCurve::from_composite_json(&segments_json)?;
        sweep_polyline(
            profile,
            path,
            twist_angle,
            scale_start,
            scale_end,
            path_segments,
            arc_segments,
            orientation,
        )
    }

    /// Sweep along a spline control polygon using deterministic interpolation.
    #[wasm_bindgen(js_name = sweepSpline)]
    #[allow(clippy::too_many_arguments)]
    pub fn sweep_spline(
        profile_json: String,
        points: Vec<f64>,
        twist_angle: Option<f64>,
        scale_start: Option<f64>,
        scale_end: Option<f64>,
        path_segments: Option<u32>,
        arc_segments: Option<u32>,
        orientation: Option<f64>,
        _scale_stations_json: String,
        _profile_stations_json: String,
        _frame_mode: Option<u32>,
        _up_direction: Vec<f64>,
        _guide_points: Vec<f64>,
        start_tangent: Vec<f64>,
        end_tangent: Vec<f64>,
    ) -> Result<Solid, JsError> {
        let profile: WasmSketchProfile = serde_json::from_str(&profile_json)
            .map_err(|error| JsError::new(&format!("Invalid profile: {error}")))?;
        profile.reject_holes("sweep")?;
        let mut path = PolylineCurve::from_flat_points(&points)?;
        if start_tangent.len() == 3 {
            let tangent = Vec3::new(start_tangent[0], start_tangent[1], start_tangent[2]);
            path.points.insert(1, path.points[0] + tangent / 3.0);
        }
        if end_tangent.len() == 3 {
            let tangent = Vec3::new(end_tangent[0], end_tangent[1], end_tangent[2]);
            let last = path.points.len() - 1;
            path.points.insert(last, path.points[last] - tangent / 3.0);
        }
        sweep_polyline(
            profile,
            path,
            twist_angle,
            scale_start,
            scale_end,
            path_segments,
            arc_segments,
            orientation,
        )
    }
}

#[derive(Debug, Clone)]
struct PolylineCurve {
    points: Vec<Point3>,
}

impl PolylineCurve {
    fn from_flat_points(values: &[f64]) -> Result<Self, JsError> {
        if values.len() < 6 || values.len() % 3 != 0 {
            return Err(JsError::new("A sweep path needs at least two 3D points"));
        }
        let points = values
            .chunks_exact(3)
            .map(|point| Point3::new(point[0], point[1], point[2]))
            .collect();
        Ok(Self { points })
    }

    fn from_composite_json(json: &str) -> Result<Self, JsError> {
        let segments: Vec<serde_json::Value> = serde_json::from_str(json)
            .map_err(|error| JsError::new(&format!("Invalid sweep path: {error}")))?;
        let mut values = Vec::new();
        for (index, segment) in segments.iter().enumerate() {
            let read_point = |name: &str| -> Result<[f64; 3], JsError> {
                let point = segment
                    .get(name)
                    .and_then(serde_json::Value::as_array)
                    .ok_or_else(|| JsError::new(&format!("Sweep segment {index} has no {name}")))?;
                if point.len() != 3 {
                    return Err(JsError::new(
                        "Sweep path points must have three coordinates",
                    ));
                }
                Ok([
                    point[0]
                        .as_f64()
                        .ok_or_else(|| JsError::new("Invalid X coordinate"))?,
                    point[1]
                        .as_f64()
                        .ok_or_else(|| JsError::new("Invalid Y coordinate"))?,
                    point[2]
                        .as_f64()
                        .ok_or_else(|| JsError::new("Invalid Z coordinate"))?,
                ])
            };
            if index == 0 {
                values.extend_from_slice(&read_point("start")?);
            }
            if segment.get("type").and_then(serde_json::Value::as_str) == Some("Arc") {
                values.extend_from_slice(&read_point("mid")?);
            }
            values.extend_from_slice(&read_point("end")?);
        }
        Self::from_flat_points(&values)
    }
}

impl vcad_kernel::vcad_kernel_geom::Curve3d for PolylineCurve {
    fn evaluate(&self, t: f64) -> Point3 {
        let maximum = (self.points.len() - 1) as f64;
        let scaled = t.clamp(0.0, maximum);
        let index = (scaled.floor() as usize).min(self.points.len() - 2);
        let fraction = scaled - index as f64;
        self.points[index] + (self.points[index + 1] - self.points[index]) * fraction
    }

    fn tangent(&self, t: f64) -> Vec3 {
        let index = (t.floor() as usize).min(self.points.len() - 2);
        self.points[index + 1] - self.points[index]
    }

    fn domain(&self) -> (f64, f64) {
        (0.0, (self.points.len() - 1) as f64)
    }

    fn curve_type(&self) -> vcad_kernel::vcad_kernel_geom::CurveKind {
        vcad_kernel::vcad_kernel_geom::CurveKind::Line
    }

    fn clone_box(&self) -> Box<dyn vcad_kernel::vcad_kernel_geom::Curve3d> {
        Box::new(self.clone())
    }

    fn suggested_segments(&self) -> usize {
        (self.points.len() - 1) * 16
    }
}

#[allow(clippy::too_many_arguments)]
fn sweep_polyline(
    profile: WasmSketchProfile,
    path: PolylineCurve,
    twist_angle: Option<f64>,
    scale_start: Option<f64>,
    scale_end: Option<f64>,
    path_segments: Option<u32>,
    arc_segments: Option<u32>,
    orientation: Option<f64>,
) -> Result<Solid, JsError> {
    let kernel_profile = profile
        .to_kernel_profile_centered()
        .map_err(|error| JsError::new(&format!("Invalid profile: {error}")))?;
    let options = vcad_kernel::vcad_kernel_sweep::SweepOptions {
        twist_angle: twist_angle.unwrap_or(0.0).to_radians(),
        path_segments: path_segments.unwrap_or(0),
        scale_start: scale_start.unwrap_or(1.0),
        scale_end: scale_end.unwrap_or(1.0),
        arc_segments: arc_segments.unwrap_or(12),
        orientation_angle: orientation.unwrap_or(0.0).to_radians(),
    };
    vcad_kernel::Solid::sweep(kernel_profile, &path, options)
        .map(|inner| Solid { inner })
        .map_err(|error| JsError::new(&error.to_string()))
}

fn kernel_blend_args(
    edges: &vcad_ir::EdgeQuery,
    profile: &vcad_ir::BlendProfile,
) -> (
    vcad_kernel::vcad_kernel_fillet::EdgeQuery,
    Vec<vcad_kernel::vcad_kernel_fillet::BlendKey>,
) {
    use vcad_kernel::vcad_kernel_fillet as kf;
    let query = match edges {
        vcad_ir::EdgeQuery::All => kf::EdgeQuery::All,
        vcad_ir::EdgeQuery::Near { point } => kf::EdgeQuery::Near {
            point: Point3::new(point.x, point.y, point.z),
        },
        vcad_ir::EdgeQuery::NearOnFace {
            point,
            face_ordinal,
        } => kf::EdgeQuery::NearOnFace {
            point: Point3::new(point.x, point.y, point.z),
            face_ordinal: *face_ordinal,
        },
        vcad_ir::EdgeQuery::Direction { axis, tol_deg } => kf::EdgeQuery::Direction {
            axis: Vec3::new(axis.x, axis.y, axis.z),
            tol_deg: *tol_deg,
        },
    };
    let keys = match profile {
        vcad_ir::BlendProfile::Constant { size, shape } => vec![kf::BlendKey {
            t: 0.0,
            section: kf::BlendSection {
                size: *size,
                shape: *shape,
            },
        }],
        vcad_ir::BlendProfile::Keyed { keys } => keys
            .iter()
            .map(|key| kf::BlendKey {
                t: key.t,
                section: kf::BlendSection {
                    size: key.size,
                    shape: key.shape,
                },
            })
            .collect(),
    };
    (query, keys)
}

#[wasm_bindgen(js_name = importStepBuffer)]
pub fn import_step_buffer(data: &[u8]) -> Result<JsValue, JsError> {
    let solids = vcad_kernel::Solid::from_step_buffer_all(data)
        .map_err(|error| JsError::new(&error.to_string()))?;
    let meshes: Vec<WasmMesh> = solids
        .iter()
        .map(|solid| {
            let mesh = solid.to_mesh(16);
            let normals = (mesh.normals.len() == mesh.vertices.len()).then_some(mesh.normals);
            WasmMesh {
                positions: mesh.vertices,
                indices: mesh.indices,
                normals,
                face_kinds: None,
                face_ids: None,
                topology_edges: None,
                topology_faces: None,
            }
        })
        .collect();
    serde_wasm_bindgen::to_value(&meshes).map_err(|error| JsError::new(&error.to_string()))
}

#[derive(Serialize)]
struct StepBodyInspection {
    bounds: Vec<f64>,
    can_export_step: bool,
    surface_area: f64,
    triangle_count: usize,
    volume: f64,
}

#[wasm_bindgen(js_name = inspectStepBuffer)]
pub fn inspect_step_buffer(data: &[u8]) -> Result<String, JsError> {
    let solids = vcad_kernel::Solid::from_step_buffer_all(data)
        .map_err(|error| JsError::new(&error.to_string()))?;
    let bodies = solids
        .iter()
        .map(|solid| {
            let (minimum, maximum) = solid.bounding_box();
            let mesh = solid.to_mesh(16);
            StepBodyInspection {
                bounds: vec![
                    minimum[0], minimum[1], minimum[2], maximum[0], maximum[1], maximum[2],
                ],
                can_export_step: solid.can_export_step(),
                surface_area: solid.surface_area(),
                triangle_count: mesh.indices.len() / 3,
                volume: solid.volume(),
            }
        })
        .collect::<Vec<_>>();
    serde_json::to_string(&bodies).map_err(|error| JsError::new(&error.to_string()))
}
