use std::fs;
use std::path::PathBuf;
use std::process::Command;

use anyhow::bail;

use crate::commands::idl::build_idl_for_current_project;
use crate::constants::FRAMEWORK_KIND_LEZ_FRAMEWORK;
use crate::model::Project;
use crate::process::run_checked;
use crate::project::{load_project, run_in_project_dir};
use crate::DynResult;

pub(crate) fn cmd_client(project_path: Option<PathBuf>) -> DynResult<()> {
    run_in_project_dir(project_path.as_deref(), build_clients_for_current_project)
}

pub(crate) fn build_clients_for_current_project() -> DynResult<()> {
    let Some(project) = load_lez_framework_project_for_client_build()? else {
        return Ok(());
    };

    // Always regenerate IDL in direct `build client` flows to prevent stale IDL drift.
    println!("[client] Regenerating IDL to ensure it is fresh...");
    build_idl_for_current_project()?;

    generate_clients_from_project_idl(&project)
}

pub(crate) fn generate_clients_from_current_idl() -> DynResult<()> {
    let Some(project) = load_lez_framework_project_for_client_build()? else {
        return Ok(());
    };

    generate_clients_from_project_idl(&project)
}

fn load_lez_framework_project_for_client_build() -> DynResult<Option<Project>> {
    let project = load_project()?;
    if project.config.framework.kind == FRAMEWORK_KIND_LEZ_FRAMEWORK {
        return Ok(Some(project));
    }

    println!(
        "Skipping client build for framework kind `{}`",
        project.config.framework.kind
    );
    Ok(None)
}

fn generate_clients_from_project_idl(project: &Project) -> DynResult<()> {
    let idl_dir = project.root.join(&project.config.framework.idl.path);
    let out_dir = project.root.join("src/generated");
    fs::create_dir_all(&out_dir)?;

    let generator_manifest = project.root.join("crates/lez-client-gen/Cargo.toml");
    if !generator_manifest.exists() {
        bail!(
            "missing client generator crate at {}",
            generator_manifest.display()
        );
    }

    run_checked(
        Command::new("cargo")
            .current_dir(&project.root)
            .arg("run")
            .arg("--manifest-path")
            .arg(&generator_manifest)
            .arg("--")
            .arg("--idl-dir")
            .arg(&idl_dir)
            .arg("--out-dir")
            .arg(&out_dir),
        "run lez client generator",
    )?;

    Ok(())
}
