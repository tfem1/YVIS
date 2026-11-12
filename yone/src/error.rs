use std::fmt;

#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[macro_export]
macro_rules! bail {
    ($($t:tt)*) => { return Err($crate::error::Error(format!($($t)*))) };
}

#[macro_export]
macro_rules! err {
    ($($t:tt)*) => { $crate::error::Error(format!($($t)*)) };
}

/// Attach context to any displayable error.
pub trait Context<T> {
    fn ctx<S: Into<String>>(self, f: impl FnOnce() -> S) -> Result<T>;
}

impl<T, E: fmt::Display> Context<T> for std::result::Result<T, E> {
    fn ctx<S: Into<String>>(self, f: impl FnOnce() -> S) -> Result<T> {
        self.map_err(|e| Error(format!("{}: {}", f().into(), e)))
    }
}
