//! Portable backend foundation, not a server or an inference implementation.
//!
//! Request admission, framing and cancellation belong to future request logic,
//! not the launcher. The supervisor owns child lifetime; its caller owns the
//! returned private pipes. No client sockets, model paths or content enter the
//! launch contract.

#![deny(unsafe_code)]

pub mod launcher;
pub mod supervisor;
