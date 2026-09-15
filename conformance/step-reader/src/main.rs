use cadrum::{Solid, Tessellation};
use serde::{Deserialize, Serialize};
use std::{
    env,
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    process::ExitCode,
};

#[derive(Deserialize)]
struct Manifest {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    file: String,
    units: String,
    body_count: usize,
    volume: f64,
    bounds: Bounds,
}

#[derive(Clone, Deserialize, Serialize)]
struct Bounds {
    minimum: Point,
    maximum: Point,
}

#[derive(Clone, Deserialize, Serialize)]
struct Point {
    x: f64,
    y: f64,
    z: f64,
}

#[derive(Serialize)]
struct Report {
    reader: &'static str,
    reader_version: &'static str,
    passed: bool,
    cases: Vec<CaseReport>,
}

#[derive(Serialize)]
struct CaseReport {
    name: String,
    passed: bool,
    body_count: usize,
    body_volumes: Vec<f64>,
    declared_units: String,
    volume: f64,
    volume_relative_error: f64,
    bounds: Bounds,
    bounds_max_deviation: f64,
    errors: Vec<String>,
}

fn declared_units(text: &str) -> String {
    let compact: String = text
        .chars()
        .filter(|character| !character.is_whitespace())
        .flat_map(char::to_uppercase)
        .collect();
    if compact.contains("SI_UNIT(.MILLI.,.METRE.)") {
        "mm".into()
    } else if compact.contains("SI_UNIT($,.METRE.)") || compact.contains("SI_UNIT(.NONE.,.METRE.)")
    {
        "m".into()
    } else if compact.contains("CONVERSION_BASED_UNIT('INCH'") {
        "in".into()
    } else {
        "unknown".into()
    }
}

fn inspect(case: Case, root: &Path) -> CaseReport {
    let path = root.join(&case.file);
    let mut errors = Vec::new();
    let mut text = String::new();
    if let Err(error) = File::open(&path).and_then(|mut file| file.read_to_string(&mut text)) {
        errors.push(format!("cannot read STEP text: {error}"));
    }
    let units = declared_units(&text);
    if units != case.units {
        errors.push(format!(
            "declared units are '{units}', expected '{}'",
            case.units
        ));
    }

    let solids = match File::open(&path)
        .map_err(|error| error.to_string())
        .and_then(|mut file| Solid::read_step(&mut file).map_err(|error| error.to_string()))
    {
        Ok(solids) => solids,
        Err(error) => {
            errors.push(format!("OpenCASCADE STEP import failed: {error}"));
            return CaseReport {
                name: case.name,
                passed: false,
                body_count: 0,
                body_volumes: Vec::new(),
                declared_units: units,
                volume: 0.0,
                volume_relative_error: f64::INFINITY,
                bounds: Bounds {
                    minimum: Point {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    maximum: Point {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                },
                bounds_max_deviation: f64::INFINITY,
                errors,
            };
        }
    };

    if solids.len() != case.body_count {
        errors.push(format!(
            "OpenCASCADE found {} bodies, expected {}",
            solids.len(),
            case.body_count
        ));
    }
    let body_volumes: Vec<f64> = solids.iter().map(Solid::volume).collect();
    let volume: f64 = body_volumes.iter().sum();
    let volume_relative_error = if case.volume.abs() > f64::EPSILON {
        (volume - case.volume).abs() / case.volume.abs()
    } else {
        f64::INFINITY
    };
    if volume_relative_error > 0.01 {
        errors.push(format!(
            "volume relative error {volume_relative_error:.6} exceeds 0.01"
        ));
    }

    // BRepBndLib::Add intentionally returns a conservative analytic box and
    // over-expands periodic surfaces (a 12/3 torus is enlarged by ~1.236 mm).
    // A fine OCCT tessellation gives a transfer-sensitive geometric box while
    // the independent analytic volume check above guards against lost mass.
    let mesh = match Solid::mesh(
        solids.iter(),
        Tessellation {
            deflection_linear: 0.005,
            deflection_angular: 0.05,
            relative_linear: false,
        },
    ) {
        Ok(mesh) if !mesh.vertices.is_empty() => mesh,
        Ok(_) => {
            errors.push("OpenCASCADE tessellation returned no vertices".into());
            return failed_bounds_report(
                case.name,
                solids.len(),
                body_volumes,
                units,
                volume,
                volume_relative_error,
                errors,
            );
        }
        Err(error) => {
            errors.push(format!("OpenCASCADE tessellation failed: {error}"));
            return failed_bounds_report(
                case.name,
                solids.len(),
                body_volumes,
                units,
                volume,
                volume_relative_error,
                errors,
            );
        }
    };
    let mut minimum = [f64::INFINITY; 3];
    let mut maximum = [f64::NEG_INFINITY; 3];
    for vertex in &mesh.vertices {
        for (axis, coordinate) in [vertex.x, vertex.y, vertex.z].into_iter().enumerate() {
            minimum[axis] = minimum[axis].min(coordinate);
            maximum[axis] = maximum[axis].max(coordinate);
        }
    }
    let bounds = Bounds {
        minimum: Point {
            x: minimum[0],
            y: minimum[1],
            z: minimum[2],
        },
        maximum: Point {
            x: maximum[0],
            y: maximum[1],
            z: maximum[2],
        },
    };
    let expected = [
        case.bounds.minimum.x,
        case.bounds.minimum.y,
        case.bounds.minimum.z,
        case.bounds.maximum.x,
        case.bounds.maximum.y,
        case.bounds.maximum.z,
    ];
    let actual = [
        bounds.minimum.x,
        bounds.minimum.y,
        bounds.minimum.z,
        bounds.maximum.x,
        bounds.maximum.y,
        bounds.maximum.z,
    ];
    let bounds_max_deviation = actual
        .iter()
        .zip(expected)
        .map(|(actual, expected)| (*actual - expected).abs())
        .fold(0.0, f64::max);
    if bounds_max_deviation > 0.05 {
        errors.push(format!(
            "bounds deviation {bounds_max_deviation:.6} mm exceeds 0.05 mm"
        ));
    }

    CaseReport {
        name: case.name,
        passed: errors.is_empty(),
        body_count: solids.len(),
        body_volumes,
        declared_units: units,
        volume,
        volume_relative_error,
        bounds,
        bounds_max_deviation,
        errors,
    }
}

fn failed_bounds_report(
    name: String,
    body_count: usize,
    body_volumes: Vec<f64>,
    declared_units: String,
    volume: f64,
    volume_relative_error: f64,
    errors: Vec<String>,
) -> CaseReport {
    CaseReport {
        name,
        passed: false,
        body_count,
        body_volumes,
        declared_units,
        volume,
        volume_relative_error,
        bounds: Bounds {
            minimum: Point {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            maximum: Point {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
        },
        bounds_max_deviation: f64::INFINITY,
        errors,
    }
}

fn main() -> ExitCode {
    let Some(manifest_path) = env::args_os().nth(1).map(PathBuf::from) else {
        eprintln!("usage: axis-cad-step-conformance <manifest.json>");
        return ExitCode::from(2);
    };
    let manifest: Manifest = match File::open(&manifest_path)
        .map_err(|error| error.to_string())
        .and_then(|file| serde_json::from_reader(file).map_err(|error| error.to_string()))
    {
        Ok(manifest) => manifest,
        Err(error) => {
            eprintln!("cannot read manifest: {error}");
            return ExitCode::from(2);
        }
    };
    let root = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    let cases: Vec<_> = manifest
        .cases
        .into_iter()
        .map(|case| inspect(case, root))
        .collect();
    let report = Report {
        reader: "OpenCASCADE via cadrum",
        reader_version: "OCCT 8.0.0 / cadrum 0.8.15",
        passed: cases.iter().all(|case| case.passed),
        cases,
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&report).expect("serialize report")
    );
    if report.passed {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
