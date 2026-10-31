//! Native object conversion using the pinned SDK's GC-rooted APIs.
//! No JSON text, unrooted object word, or VM borrow enters OwnedSource.
use crate::{MAX_SOURCE_BYTES, OwnedSource, SourceData, SourceError};
use gerbil_scheme::{
    BigIntegerBuffer, CollectionKind, IdentifierBuffer, IdentifierKind, ObjectKind,
    RootedObjectBatch, RootedSchemeObject, SchemeScalar,
};
use serde::de::{self, Deserialize, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::collections::BTreeSet;
impl de::Error for SourceError {
    fn custom<T: std::fmt::Display>(_: T) -> Self {
        Self::Contract
    }
}
fn sdk<T>(value: Result<T, gerbil_scheme::NativeError>) -> Result<T, SourceError> {
    value.map_err(|_| SourceError::Scheme)
}
struct Limits {
    bytes: usize,
    nodes: usize,
}
struct Native<'r, 'a> {
    value: RootedSchemeObject<'r>,
    limits: &'a mut Limits,
    depth: usize,
}
impl Native<'_, '_> {
    fn charge(&mut self) -> Result<(), SourceError> {
        self.limits.nodes = self.limits.nodes.checked_sub(1).ok_or(SourceError::Bound)?;
        if self.depth > 64 {
            return Err(SourceError::Bound);
        }
        Ok(())
    }
}
/// Approved producer supplies a stable typed snapshot. SDK table copies are
/// shallow; limits bound traversal, not arbitrary hostile VM allocation.
pub fn materialize_source(source: RootedSchemeObject<'_>) -> Result<OwnedSource, SourceError> {
    let mut limits = Limits {
        bytes: MAX_SOURCE_BYTES,
        nodes: 16384,
    };
    let data = SourceData::deserialize(Native {
        value: source,
        limits: &mut limits,
        depth: 0,
    })?;
    OwnedSource::from_source(data)
}
struct Sequence<'r, 'a> {
    entries: RootedObjectBatch<'r>,
    index: usize,
    limits: &'a mut Limits,
    depth: usize,
}
impl<'de> SeqAccess<'de> for Sequence<'_, '_> {
    type Error = SourceError;
    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Self::Error> {
        if self.index == self.entries.len() {
            return Ok(None);
        }
        let value = sdk(self.entries.root_element(self.index))?;
        self.index += 1;
        seed.deserialize(Native {
            value,
            limits: self.limits,
            depth: self.depth,
        })
        .map(Some)
    }
    fn size_hint(&self) -> Option<usize> {
        Some(self.entries.len() - self.index)
    }
}
struct Mapping<'r, 'a> {
    entries: RootedObjectBatch<'r>,
    index: usize,
    pending: bool,
    limits: &'a mut Limits,
    depth: usize,
    fields: bool,
    keys: BTreeSet<String>,
}
impl<'de> MapAccess<'de> for Mapping<'_, '_> {
    type Error = SourceError;
    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, Self::Error> {
        if self.pending {
            return Err(SourceError::Contract);
        }
        if self.index == self.entries.len() {
            return Ok(None);
        }
        let value = sdk(self.entries.root_element(self.index))?;
        let kind = sdk(value.as_ref().kind())?;
        let name = if self.fields && kind == ObjectKind::Symbol {
            let mut names = IdentifierBuffer::default();
            sdk(value.as_ref().copy_identifier_names(&mut names))?;
            match names.get(0) {
                Some((IdentifierKind::Symbol, name)) => name.to_owned(),
                _ => return Err(SourceError::Contract),
            }
        } else if !self.fields && kind == ObjectKind::String {
            let key = sdk(value.into_string())?;
            if sdk(key.len().into_result())? > self.limits.bytes {
                return Err(SourceError::Bound);
            }
            sdk(key.to_string().into_result())?
        } else {
            return Err(SourceError::Contract);
        };
        self.limits.bytes = self
            .limits
            .bytes
            .checked_sub(name.len())
            .ok_or(SourceError::Bound)?;
        if !self.keys.insert(name.clone()) {
            return Err(SourceError::Contract);
        }
        self.pending = true;
        seed.deserialize(de::value::StringDeserializer::<SourceError>::new(name))
            .map(Some)
    }
    fn next_value_seed<V: DeserializeSeed<'de>>(
        &mut self,
        seed: V,
    ) -> Result<V::Value, Self::Error> {
        if !self.pending {
            return Err(SourceError::Contract);
        }
        let value = sdk(self.entries.root_element(self.index + 1))?;
        self.index += 2;
        self.pending = false;
        seed.deserialize(Native {
            value,
            limits: self.limits,
            depth: self.depth,
        })
    }
    fn size_hint(&self) -> Option<usize> {
        Some((self.entries.len() - self.index) / 2)
    }
}
impl<'de> de::Deserializer<'de> for Native<'_, '_> {
    type Error = SourceError;
    fn deserialize_any<V: Visitor<'de>>(mut self, visitor: V) -> Result<V::Value, Self::Error> {
        self.charge()?;
        match sdk(self.value.as_ref().kind())? {
            ObjectKind::Boolean => match sdk(self.value.as_ref().scalar())? {
                SchemeScalar::Boolean(value) => visitor.visit_bool(value),
                _ => Err(SourceError::Contract),
            },
            ObjectKind::ExactInteger => {
                let mut integer = BigIntegerBuffer::default();
                sdk(self.value.as_ref().copy_big_integer(&mut integer))?;
                let value = integer.value();
                let bytes = value.magnitude();
                if value.is_negative() || bytes.len() > 8 {
                    return Err(SourceError::Contract);
                }
                let mut raw = [0u8; 8];
                raw[..bytes.len()].copy_from_slice(bytes);
                visitor.visit_u64(u64::from_le_bytes(raw))
            }
            ObjectKind::String => {
                let text = sdk(self.value.into_string())?;
                if sdk(text.len().into_result())? > self.limits.bytes {
                    return Err(SourceError::Bound);
                }
                let bytes = sdk(text.to_utf8_bytes().into_result())?;
                let length = sdk(bytes.len().into_result())?;
                self.limits.bytes = self
                    .limits
                    .bytes
                    .checked_sub(length)
                    .ok_or(SourceError::Bound)?;
                let text = String::from_utf8(sdk(bytes.to_vec().into_result())?)
                    .map_err(|_| SourceError::Contract)?;
                visitor.visit_string(text)
            }
            ObjectKind::Nil => visitor.visit_unit(),
            ObjectKind::Vector => {
                let sequence = sdk(self.value.into_collection(CollectionKind::Vector))?;
                let length = sequence.len();
                if length > 64 {
                    return Err(SourceError::Bound);
                }
                let mut entries = RootedObjectBatch::default();
                sdk(sequence.copy_into(&mut entries))?;
                visitor.visit_seq(Sequence {
                    entries,
                    index: 0,
                    limits: self.limits,
                    depth: self.depth + 1,
                })
            }
            _ => Err(SourceError::Contract),
        }
    }
    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        if sdk(self.value.as_ref().kind())? == ObjectKind::Nil {
            visitor.visit_none()
        } else {
            visitor.visit_some(self)
        }
    }
    fn deserialize_map<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        self.mapping(visitor, false)
    }
    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _: &'static str,
        _: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Self::Error> {
        self.mapping(visitor, true)
    }
    serde::forward_to_deserialize_any! { bool i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 char str string bytes byte_buf unit unit_struct newtype_struct seq tuple tuple_struct enum identifier ignored_any }
}
impl Native<'_, '_> {
    fn mapping<'de, V: Visitor<'de>>(
        mut self,
        visitor: V,
        fields: bool,
    ) -> Result<V::Value, SourceError> {
        self.charge()?;
        if sdk(self.value.as_ref().kind())? != ObjectKind::GambitTable {
            return Err(SourceError::Contract);
        }
        let mut entries = RootedObjectBatch::default();
        sdk(self.value.copy_table_entries(&mut entries))?;
        if entries.len() > 128 || entries.len() % 2 != 0 {
            return Err(SourceError::Bound);
        }
        visitor.visit_map(Mapping {
            entries,
            index: 0,
            pending: false,
            limits: self.limits,
            depth: self.depth + 1,
            fields,
            keys: BTreeSet::new(),
        })
    }
}
