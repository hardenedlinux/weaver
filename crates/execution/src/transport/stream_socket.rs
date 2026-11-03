// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Native unbuffered socket with one absolute deadline across TLS internal calls.
use std::{
    io::{self, Read, Write},
    net::{Shutdown, SocketAddr, TcpStream},
    time::{Duration, Instant},
};
pub(crate) struct DeadlineSocket {
    pub(crate) stream: TcpStream,
    pub(crate) deadline: Instant,
}
impl DeadlineSocket {
    pub(crate) fn connect(address: SocketAddr) -> io::Result<Self> {
        let stream = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
        stream.set_nodelay(true)?;
        Ok(Self {
            stream,
            deadline: Instant::now() + Duration::from_secs(2),
        })
    }
    pub(crate) fn close(&self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
    fn remaining(&self) -> io::Result<Duration> {
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or(io::ErrorKind::TimedOut.into())
    }
}
impl Read for DeadlineSocket {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.stream.set_read_timeout(Some(self.remaining()?))?;
        self.stream.read(bytes)
    }
}
impl Write for DeadlineSocket {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.stream.set_write_timeout(Some(self.remaining()?))?;
        self.stream.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
