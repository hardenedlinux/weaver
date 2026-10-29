//! Source publication checks against an explicit Cedar context/action schema.
use cedar_policy::{Schema, ValidationMode, Validator};
use weaver_contracts::{Error, Result};

/// Reject a policy bundle that fails strict validation against its declared schema.
pub fn validate_typed(source: &str, schema: &str) -> Result<()> {
    if schema.len() > 1_048_576 {
        return Err(Error::Invalid("Policy schema bound"));
    }
    let schema = Schema::from_json_value(weaver_contracts::decode(schema.as_bytes())?)
        .map_err(|_| Error::Policy("invalid Cedar schema".into()))?;
    let valid = crate::compiled::with_policy(source, |policies| {
        Validator::new(schema)
            .validate(policies, ValidationMode::Strict)
            .validation_errors()
            .next()
            .is_none()
    })?;
    if !valid {
        return Err(Error::Policy("Policy/schema contract mismatch".into()));
    }
    Ok(())
}
