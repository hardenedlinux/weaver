// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Gerbil constructors with cumulative traversal bounds; every intermediate is rooted.
use crate::{MAX_SOURCE_BYTES, SourceError};
use gerbil_scheme::{
    BinaryInteger, CollectionKind, GerbilRuntime, IdentifierKind, RootedSchemeObject, TableEquality,
};
use std::{cell::Cell, collections::BTreeMap};
pub(crate) type Object<'r> = RootedSchemeObject<'r>;
pub(crate) type Result<T> = std::result::Result<T, SourceError>;
pub(crate) struct Input<'r> {
    vm: &'r GerbilRuntime,
    bytes: Cell<usize>,
    nodes: Cell<usize>,
}
fn scheme_result<T>(value: std::result::Result<T, gerbil_scheme::NativeError>) -> Result<T> {
    value.map_err(|_| SourceError::Scheme)
}
impl<'r> Input<'r> {
    pub(crate) fn new(vm: &'r GerbilRuntime) -> Self {
        Self {
            vm,
            bytes: Cell::new(MAX_SOURCE_BYTES),
            nodes: Cell::new(16384),
        }
    }
    fn node(&self) -> Result<()> {
        self.nodes
            .set(self.nodes.get().checked_sub(1).ok_or(SourceError::Bound)?);
        Ok(())
    }
    fn bytes(&self, count: usize) -> Result<()> {
        self.bytes.set(
            self.bytes
                .get()
                .checked_sub(count)
                .ok_or(SourceError::Bound)?,
        );
        Ok(())
    }
    pub(crate) fn text(&self, value: &str) -> Result<Object<'r>> {
        self.node()?;
        self.bytes(value.len())?;
        Ok(scheme_result(self.vm.string_from_utf8(value))?.into_object())
    }
    pub(crate) fn bytes_vector(&self, value: &[u8]) -> Result<Object<'r>> {
        self.node()?;
        self.bytes(value.len())?;
        Ok(scheme_result(self.vm.bytevector_from_bytes(value))?.into_object())
    }
    pub(crate) fn number(&self, value: u64) -> Result<Object<'r>> {
        self.node()?;
        let mut bytes = value.to_le_bytes().to_vec();
        while bytes.last() == Some(&0) {
            bytes.pop();
        }
        let integer = BinaryInteger::new(false, bytes).map_err(|_| SourceError::Contract)?;
        scheme_result(self.vm.big_integer(&integer))
    }
    pub(crate) fn record(&self, fields: Vec<(&'static str, Object<'r>)>) -> Result<Object<'r>> {
        self.node()?;
        if fields.len() > 64 {
            return Err(SourceError::Bound);
        }
        let keys = fields
            .iter()
            .map(|(name, _)| {
                self.bytes(name.len())?;
                scheme_result(self.vm.intern_identifier(IdentifierKind::Symbol, name))
            })
            .collect::<Result<Vec<_>>>()?;
        let entries: Vec<_> = keys
            .iter()
            .zip(fields.iter().map(|(_, value)| value))
            .collect();
        scheme_result(self.vm.hash_table(TableEquality::Structural, &entries))
    }
    pub(crate) fn vector(&self, values: Vec<Object<'r>>) -> Result<Object<'r>> {
        self.node()?;
        if values.len() > 64 {
            return Err(SourceError::Bound);
        }
        Ok(scheme_result(
            self.vm.collection_from_objects(
                CollectionKind::Vector,
                &values.iter().collect::<Vec<_>>(),
            ),
        )?
        .into_object())
    }
    pub(crate) fn edges(&self, edges: &[(String, String)]) -> Result<Object<'r>> {
        self.vector(
            edges
                .iter()
                .map(|(child, parent)| self.vector(vec![self.text(child)?, self.text(parent)?]))
                .collect::<Result<Vec<_>>>()?,
        )
    }
    pub(crate) fn strings(&self, values: &[String]) -> Result<Object<'r>> {
        if values.len() > 64 {
            return Err(SourceError::Bound);
        }
        self.vector(
            values
                .iter()
                .map(|value| self.text(value))
                .collect::<Result<Vec<_>>>()?,
        )
    }
    pub(crate) fn texts(&self, values: &BTreeMap<String, String>) -> Result<Object<'r>> {
        self.mapping(values, |value| self.text(value))
    }
    pub(crate) fn numbers(&self, values: &BTreeMap<String, u64>) -> Result<Object<'r>> {
        self.mapping(values, |value| self.number(*value))
    }
    fn mapping<T>(
        &self,
        values: &BTreeMap<String, T>,
        convert: impl Fn(&T) -> Result<Object<'r>>,
    ) -> Result<Object<'r>> {
        self.node()?;
        if values.len() > 64 {
            return Err(SourceError::Bound);
        }
        let entries = values
            .iter()
            .map(|(key, value)| Ok((self.text(key)?, convert(value)?)))
            .collect::<Result<Vec<_>>>()?;
        scheme_result(
            self.vm.hash_table(
                TableEquality::Structural,
                &entries
                    .iter()
                    .map(|(key, value)| (key, value))
                    .collect::<Vec<_>>(),
            ),
        )
    }
}
