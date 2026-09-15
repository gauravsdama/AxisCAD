#![warn(missing_docs)]
#![doc = include_str!("../README.md")]

//! # Quick Start
//!
//! ```
//! use stepperoni::parse;
//!
//! let step_data = br#"ISO-10303-21;
//! HEADER;
//! FILE_DESCRIPTION(('Example'), '2;1');
//! ENDSEC;
//! DATA;
//! #1 = CARTESIAN_POINT('origin', (0.0, 0.0, 0.0));
//! #2 = DIRECTION('z', (0.0, 0.0, 1.0));
//! ENDSEC;
//! END-ISO-10303-21;
//! "#;
//!
//! let file = parse(step_data).unwrap();
//!
//! // Access entities by ID
//! let point = file.get(1).unwrap();
//! assert_eq!(point.type_name, "CARTESIAN_POINT");
//!
//! // Extract coordinates
//! let coords = point.args[1].as_list().unwrap();
//! let x = coords[0].as_real().unwrap();
//! assert_eq!(x, 0.0);
//!
//! // Find all entities of a type
//! let directions = file.entities_of_type("DIRECTION");
//! assert_eq!(directions.len(), 1);
//! ```

mod error;
mod lexer;
mod parser;

pub use error::StepError;
pub use lexer::{Lexer, Position, SpannedToken, Token};
pub use parser::{Parser, StepEntity, StepFile, StepValue};

/// Parse a STEP file from bytes.
///
/// This is the main entry point for parsing STEP files. It tokenizes the input
/// and builds a graph of entities that can be queried by ID or type.
///
/// # Arguments
///
/// * `input` - Raw STEP file contents as bytes
///
/// # Returns
///
/// A [`StepFile`] containing all parsed entities, or a [`StepError`] if parsing fails.
///
/// # Example
///
/// ```
/// use stepperoni::parse;
///
/// let data = br#"ISO-10303-21;
/// HEADER;
/// ENDSEC;
/// DATA;
/// #1 = POINT('', (1.0, 2.0, 3.0));
/// ENDSEC;
/// END-ISO-10303-21;
/// "#;
///
/// let file = parse(data).unwrap();
/// assert_eq!(file.entities.len(), 1);
/// ```
pub fn parse(input: &[u8]) -> Result<StepFile, StepError> {
    Parser::parse(input)
}

/// Tokenize a STEP file without parsing.
///
/// Useful for low-level access to the token stream, syntax highlighting,
/// or building custom parsers.
///
/// # Arguments
///
/// * `input` - Raw STEP file contents as bytes
///
/// # Returns
///
/// A vector of [`SpannedToken`]s, or a [`StepError`] if tokenization fails.
///
/// # Example
///
/// ```
/// use stepperoni::{tokenize, Token};
///
/// let data = b"#1 = POINT('name', (0.0));";
/// let tokens = tokenize(data).unwrap();
///
/// assert!(matches!(tokens[0].token, Token::EntityRef(1)));
/// assert!(matches!(tokens[1].token, Token::Equals));
/// assert!(matches!(tokens[2].token, Token::Keyword(_)));
/// ```
pub fn tokenize(input: &[u8]) -> Result<Vec<SpannedToken>, StepError> {
    let mut lexer = Lexer::new(input);
    lexer.tokenize()
}
