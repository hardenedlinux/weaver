//! Duplicate rejection precedes typed deserialization, including embedded wire JSON.
use crate::{Error, MAX_BODY_BYTES, Result};
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Value};
use std::fmt;

struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> std::result::Result<Self, D::Error> {
        struct Strict;
        impl<'de> Visitor<'de> for Strict {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("unique-key JSON")
            }
            fn visit_bool<E: de::Error>(self, x: bool) -> std::result::Result<Unique, E> {
                Ok(Unique(x.into()))
            }
            fn visit_i64<E: de::Error>(self, x: i64) -> std::result::Result<Unique, E> {
                Ok(Unique(x.into()))
            }
            fn visit_u64<E: de::Error>(self, x: u64) -> std::result::Result<Unique, E> {
                Ok(Unique(x.into()))
            }
            fn visit_f64<E: de::Error>(self, x: f64) -> std::result::Result<Unique, E> {
                serde_json::Number::from_f64(x)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("nonfinite number"))
            }
            fn visit_str<E: de::Error>(self, x: &str) -> std::result::Result<Unique, E> {
                Ok(Unique(x.into()))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(v)) = a.next_element()? {
                    values.push(v);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Map::new();
                while let Some(key) = a.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(de::Error::custom("duplicate JSON key"));
                    }
                    let Unique(value) = a.next_value()?;
                    values.insert(key, value);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        decoder.deserialize_any(Strict)
    }
}
/// Decode bounded JSON after rejecting duplicate keys at every depth.
pub fn decode<T: de::DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    if bytes.len() > MAX_BODY_BYTES * 2 {
        return Err(Error::Invalid("JSON input size"));
    }
    let Unique(value) = serde_json::from_slice(bytes)?;
    Ok(serde_json::from_value(value)?)
}
