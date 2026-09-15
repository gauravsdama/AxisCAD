//! Error types for STEP file parsing.

use thiserror::Error;

/// Errors that can occur during STEP file parsing.
#[derive(Error, Debug)]
pub enum StepError {
    /// I/O error reading a file.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// Lexer error: unexpected character or malformed token.
    #[error("Lexer error at line {line}, column {col}: {message}")]
    Lexer {
        /// Line number (1-indexed).
        line: usize,
        /// Column number (1-indexed).
        col: usize,
        /// Error message.
        message: String,
    },

    /// Parser error: unexpected token or malformed structure.
    #[error("Parser error{}: {message}", entity_id.map(|id| format!(" at entity #{}", id)).unwrap_or_default())]
    Parser {
        /// Entity ID where the error occurred, if known.
        entity_id: Option<u64>,
        /// Error message.
        message: String,
    },
}

impl StepError {
    /// Create a lexer error.
    pub fn lexer(line: usize, col: usize, message: impl Into<String>) -> Self {
        Self::Lexer {
            line,
            col,
            message: message.into(),
        }
    }

    /// Create a parser error.
    pub fn parser(entity_id: Option<u64>, message: impl Into<String>) -> Self {
        Self::Parser {
            entity_id,
            message: message.into(),
        }
    }
}
