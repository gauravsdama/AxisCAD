//! Text to geometry conversion for the vcad kernel.
//!
//! This crate converts text strings into sketch profiles that can be extruded
//! to create 3D text geometry for embossing and engraving.
//!
//! # Example
//!
//! ```ignore
//! use vcad_kernel_text::{FontRegistry, text_to_profiles, TextAlignment};
//!
//! // Get the built-in font
//! let font = FontRegistry::builtin_sans();
//!
//! // Convert text to profiles
//! let profiles = text_to_profiles(
//!     "Hello",
//!     &font,
//!     10.0,  // height in mm
//!     1.0,   // letter spacing
//!     1.2,   // line spacing
//!     TextAlignment::Left,
//! );
//!
//! // Profiles can then be used with extrude() to create 3D geometry
//! ```

mod builtin;
mod font;
mod glyph;
mod profile;

pub use font::{Font, FontError, FontRegistry};
pub use profile::{text_bounds, text_to_profiles};

use thiserror::Error;

/// Text alignment options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TextAlignment {
    /// Align text to the left (default).
    #[default]
    Left,
    /// Align text to the center.
    Center,
    /// Align text to the right.
    Right,
}

/// Errors from text operations.
#[derive(Debug, Clone, Error)]
pub enum TextError {
    /// Font not found in registry.
    #[error("font not found: {0}")]
    FontNotFound(String),

    /// Invalid font data.
    #[error("invalid font data: {0}")]
    InvalidFont(String),

    /// Glyph not found for character.
    #[error("glyph not found for character: {0}")]
    GlyphNotFound(char),
}
