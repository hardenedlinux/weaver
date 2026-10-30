//! Development-only dynamic image packaging using the pinned SDK.
//! The inventory comes from Gerbil's actual module registry, never a tree scan.
use gerbil_scheme_aot_build::{
    NativeArchiveLinkReceipt, build_native_module_bundles, default_gambit_gsc_program_for_gxi,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
};

fn exports(path: &Path) -> Result<BTreeSet<String>, String> {
    let result = Command::new("/usr/bin/nm")
        .arg("-gU")
        .arg(path)
        .output()
        .map_err(|e| e.to_string())?;
    if !result.status.success() {
        return Err(format!("cannot inspect {}", path.display()));
    }
    Ok(String::from_utf8(result.stdout)
        .map_err(|e| e.to_string())?
        .lines()
        .filter_map(|line| line.split_whitespace().last().map(str::to_owned))
        .collect())
}

// Diagnostic controls only. Both layouts use the very same pinned-SDK C objects.
// Their fresh linker UUIDs/inodes distinguish first mapping from repeat mapping.
fn controls(input: &Path, out: &Path) -> Result<(), String> {
    let manifest = fs::read_to_string(input.join("bundles.tsv")).map_err(|e| e.to_string())?;
    let compiler = gerbil_scheme_aot_build::discover_native_c_compiler()?;
    let mut groups = BTreeMap::<PathBuf, Vec<PathBuf>>::new();
    let mut tasks = Vec::<(PathBuf, Vec<PathBuf>, BTreeSet<String>)>::new();
    let mut receipt = String::new();
    for (index, line) in manifest.lines().enumerate() {
        let (original, image) = line.split_once('\t').ok_or("invalid bundle row")?;
        let original = PathBuf::from(original);
        let image = PathBuf::from(image);
        let group = image
            .file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.strip_prefix("group-"))
            .ok_or("unsupported pinned SDK image layout")?;
        let filename = original
            .file_name()
            .ok_or("missing object name")?
            .to_str()
            .ok_or("UTF8 object name")?;
        let object = input
            .join("objects")
            .join(group)
            .join(format!("{filename}.o"));
        if !object.is_file() {
            return Err(format!("missing pinned SDK object {}", object.display()));
        }
        let single = out.join("separate").join(format!("module-{index}.o1"));
        let combined = out
            .join("coalesced")
            .join(image.file_name().ok_or("missing image name")?);
        tasks.push((single.clone(), vec![object.clone()], exports(&original)?));
        groups.entry(image).or_default().push(object);
        receipt.push_str(&format!(
            "{}\t{}\t{}\t{}\n",
            original.display(),
            single.display(),
            combined.display(),
            tasks.last().ok_or("missing task")?.1[0].display()
        ));
    }
    for (image, objects) in groups {
        tasks.push((
            out.join("coalesced")
                .join(image.file_name().ok_or("missing image name")?),
            objects,
            exports(&image)?,
        ));
    }
    fs::create_dir_all(out.join("separate")).map_err(|e| e.to_string())?;
    fs::create_dir_all(out.join("coalesced")).map_err(|e| e.to_string())?;
    let next = AtomicUsize::new(0);
    let failures = Mutex::new(Vec::new());
    let cores = thread::available_parallelism()
        .map_err(|e| e.to_string())?
        .get();
    thread::scope(|scope| {
        for _ in 0..cores {
            let next = &next;
            let failures = &failures;
            let tasks = &tasks;
            let compiler = &compiler;
            scope.spawn(move || {
                while let Some((image, objects, expected)) =
                    tasks.get(next.fetch_add(1, Ordering::Relaxed))
                {
                    let result = Command::new(&compiler.program)
                        .args(["-bundle", "-Wl,-random_uuid", "-o"])
                        .arg(image)
                        .args(objects)
                        .output()
                        .map_err(|e| e.to_string())
                        .and_then(|output| {
                            if !output.status.success() {
                                return Err(String::from_utf8_lossy(&output.stderr).into_owned());
                            }
                            if exports(image)? != *expected {
                                return Err("control changed native linker exports".into());
                            }
                            Ok(())
                        });
                    if let Err(error) = result
                        && let Ok(mut errors) = failures.lock()
                    {
                        errors.push(error);
                    }
                }
            });
        }
    });
    let failures = failures.into_inner().map_err(|e| e.to_string())?;
    if !failures.is_empty() {
        return Err(failures.join("\n"));
    }
    fs::write(out.join("controls.tsv"), receipt).map_err(|e| e.to_string())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.len() != 3 {
        return Err("expected compiler inventory output-directory".into());
    }
    if args[0] == "controls" {
        return controls(Path::new(&args[1]), Path::new(&args[2])).map_err(Into::into);
    }
    eprintln!(
        "dynamic image build available-process-cpus={}",
        thread::available_parallelism()?
    );
    let files = fs::read_to_string(&args[1])?
        .lines()
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    let receipt = NativeArchiveLinkReceipt {
        archive_name: "weaver_dynamic_images".into(),
        archive_file: PathBuf::new(),
        cargo_directives: vec![],
    };
    let out = PathBuf::from(&args[2]);
    let gsc = default_gambit_gsc_program_for_gxi(&args[0]);
    let compiler = gerbil_scheme_aot_build::discover_native_c_compiler()?;
    fs::write(
        out.join("tools.txt"),
        format!(
            "{}\n{}\n{}\n",
            gsc.display(),
            compiler.program.display(),
            env::current_exe()?.display()
        ),
    )?;
    let bundles = build_native_module_bundles(&gsc, &files, &out, &receipt)?;
    let mut manifest = String::new();
    for bundle in bundles {
        for module in bundle.modules {
            manifest.push_str(&format!(
                "{}\t{}\n",
                module.display(),
                bundle.image.display()
            ));
        }
    }
    fs::write(out.join("bundles.tsv"), manifest)?;
    Ok(())
}
