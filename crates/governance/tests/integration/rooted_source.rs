//! Deliberately malformed native values; ordinary construction uses production API.
use gerbil_scheme::{GerbilRuntime, IdentifierKind, RootedSchemeObject as Object, TableEquality};
use weaver_governance::{OwnedSource, SourceData, root_source};
fn text<'r>(vm: &'r GerbilRuntime, value: &str) -> Object<'r> {
    vm.string_from_utf8(value)
        .expect("fixture string")
        .into_object()
}
pub fn source<'r>(vm: &'r GerbilRuntime, data: &SourceData) -> Object<'r> {
    let source = OwnedSource::from_source(data.clone()).expect("valid original fixture");
    root_source(vm, &source).expect("production input construction")
}
/// Rebuild a real native table with one deliberate field corruption.
pub fn corrupt<'r>(vm: &'r GerbilRuntime, root: &Object<'r>, fault: u8) -> Object<'r> {
    use gerbil_scheme::{IdentifierBuffer, RootedObjectBatch, SchemeScalar};
    let mut batch = RootedObjectBatch::default();
    root.copy_table_entries(&mut batch).expect("snapshot");
    let mut entries = Vec::new();
    for index in (0..batch.len()).step_by(2) {
        let mut key = batch.root_element(index).expect("key");
        let mut value = batch.root_element(index + 1).expect("value");
        let mut name = IdentifierBuffer::default();
        key.as_ref()
            .copy_identifier_names(&mut name)
            .expect("symbol");
        let name = name.get(0).expect("name").1;
        if name == "fence" {
            value = match fault {
                0 => vm
                    .scalar_object(SchemeScalar::Boolean(false))
                    .expect("false"),
                1 => vm.nil_object().expect("nil"),
                2 => vm.scalar_object(SchemeScalar::Flonum(1.0)).expect("float"),
                5 => vm
                    .big_integer(
                        &gerbil_scheme::BinaryInteger::new(true, vec![1]).expect("negative"),
                    )
                    .expect("negative integer"),
                6 => vm
                    .big_integer(
                        &gerbil_scheme::BinaryInteger::new(false, vec![255; 8])
                            .expect("unsigned maximum"),
                    )
                    .expect("integer exceeds signed contract"),
                7 => vm
                    .big_integer(
                        &gerbil_scheme::BinaryInteger::new(false, vec![1; 9])
                            .expect("wide magnitude"),
                    )
                    .expect("integer exceeds carrier width"),
                _ => value,
            };
        }
        if fault == 3 {
            key = text(vm, name);
        }
        entries.push((key, value));
    }
    if fault == 4 {
        entries.push((
            vm.intern_identifier(IdentifierKind::Symbol, "approved")
                .expect("extra"),
            vm.scalar_object(SchemeScalar::Boolean(true)).expect("true"),
        ));
    }
    vm.hash_table(
        TableEquality::Structural,
        &entries.iter().map(|(k, v)| (k, v)).collect::<Vec<_>>(),
    )
    .expect("corrupt table")
}
pub fn publication<'r>(vm: &'r GerbilRuntime, data: &SourceData, fault: u8) -> Object<'r> {
    let root = source(vm, data);
    let mut batch = gerbil_scheme::RootedObjectBatch::default();
    root.copy_table_entries(&mut batch)
        .expect("source snapshot");
    let mut entries = Vec::new();
    for index in (0..batch.len()).step_by(2) {
        let key = batch.root_element(index).expect("field");
        let mut value = batch.root_element(index + 1).expect("value");
        let mut name = gerbil_scheme::IdentifierBuffer::default();
        key.as_ref()
            .copy_identifier_names(&mut name)
            .expect("field name");
        if name.get(0).expect("field").1 == "publication" {
            value = corrupt(vm, &value, fault);
        }
        entries.push((key, value));
    }
    vm.hash_table(
        TableEquality::Structural,
        &entries.iter().map(|(k, v)| (k, v)).collect::<Vec<_>>(),
    )
    .expect("source fault")
}
