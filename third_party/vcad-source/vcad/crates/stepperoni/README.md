# stepperoni

Fast STEP (ISO 10303-21) file parser for Rust.

[![Crates.io](https://img.shields.io/crates/v/stepperoni.svg)](https://crates.io/crates/stepperoni)
[![Documentation](https://docs.rs/stepperoni/badge.svg)](https://docs.rs/stepperoni)
[![License](https://img.shields.io/crates/l/stepperoni.svg)](LICENSE-MIT)

## Features

- Zero-copy lexer for Part 21 physical file format
- Full parser building entity graphs with ID lookup
- Handles complex/compound entities
- Minimal dependencies (just `thiserror`)
- No unsafe code

## Installation

```toml
[dependencies]
stepperoni = "0.1"
```

## Quick Start

```rust,ignore
use stepperoni::parse;

let step_data = br#"ISO-10303-21;
HEADER;
FILE_DESCRIPTION(('Example'), '2;1');
ENDSEC;
DATA;
#1 = CARTESIAN_POINT('origin', (0.0, 0.0, 0.0));
#2 = DIRECTION('z', (0.0, 0.0, 1.0));
#3 = AXIS2_PLACEMENT_3D('', #1, #2, $);
ENDSEC;
END-ISO-10303-21;
"#;

let file = parse(step_data).unwrap();

// Access entities by ID
let point = file.get(1).unwrap();
assert_eq!(point.type_name, "CARTESIAN_POINT");

// Extract values
let name = point.args[0].as_string().unwrap();
let coords = point.args[1].as_list().unwrap();
let x = coords[0].as_real().unwrap();

// Find all entities of a type
let directions = file.entities_of_type("DIRECTION");
```

## API Overview

### Top-level functions

- `parse(input: &[u8])` - Parse a complete STEP file
- `tokenize(input: &[u8])` - Tokenize without parsing

### Core types

- `StepFile` - Parsed file with header and entity map
- `StepEntity` - Single entity with ID, type name, and arguments
- `StepValue` - Argument value (reference, string, number, list, etc.)
- `Token` - Lexer token types
- `StepError` - Error type for lexer and parser errors

### StepValue variants

| Variant | Description | Accessor |
|---------|-------------|----------|
| `EntityRef(u64)` | Reference like `#123` | `.as_entity_ref()` |
| `String(String)` | String like `'hello'` | `.as_string()` |
| `Real(f64)` | Real number | `.as_real()` |
| `Integer(i64)` | Integer | `.as_integer()` |
| `Enum(String)` | Enum like `.TRUE.` | `.as_enum()` |
| `List(Vec)` | Nested list `(...)` | `.as_list()` |
| `Derived` | Derived value `*` | `.is_derived()` |
| `Null` | Null value `$` | `.is_null()` |
| `Typed` | Complex value | pattern match |

## What This Crate Does NOT Do

This is a **parser**, not a STEP interpreter. It gives you the raw entity graph without semantic interpretation. You'll need additional code to:

- Resolve entity references into actual objects
- Interpret specific entity types (CARTESIAN_POINT, B_SPLINE_SURFACE, etc.)
- Build geometric/topological structures from the parsed data
- Handle specific application protocols (AP203, AP214, AP242)

For a full STEP-to-geometry solution, see [vcad](https://github.com/vcad-io/vcad) which uses this crate internally.

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.
