//! Portable backend foundation and controlled fake-worker lifecycle service.
//!
//! Request admission, framing and cancellation belong to the service,
//! not the launcher. The supervisor owns child lifetime; its caller owns the
//! returned private pipes. No client sockets, model paths or content enter the
//! launch contract.

#![deny(unsafe_code)]

pub mod audio;
pub mod config;
pub mod launcher;
pub mod model;
pub mod service;
pub mod supervisor;
pub mod worker_protocol;
