//! 栈级配置检查（`wist-stackcheck`，gateway-stack profile）。
//!
//! 通用引擎（Flow Result / CLI / 渲染/密钥/端口/镜像判据 / compose / x509）在
//! `wist-stackcheck-core`；本 crate 只提供：
//! - [`profile::GATEWAY`]：渲染对、占位值文件、密钥根；
//! - gateway 专属判据：package / knowledge / identity / prereq / TLS 策略；
//! - [`run_with`] 的判据编排。
//!
//! 输出对齐 `gops run diagnose` 的 Flow Result v1（`schema_version` + `checks[]`）。

pub mod checks;
pub mod profile;

pub use wist_stackcheck_core::{Finding, Options, Stack, Status, has_blocking_failure, worst};

/// 跑本栈的全部检查。顺序固定（输出可 diff、可回归）。
pub fn run_with(stack: &Stack, options: &Options) -> Vec<Finding> {
    let profile = &profile::GATEWAY;
    let vars = checks::Vars::load(stack);

    let mut out = Vec::new();
    // 前置条件放最前：它是「后面这些能不能成立」的前提。
    if options.wants("prereq") {
        out.extend(checks::prereq_toolchain());
        out.extend(checks::prereq_container_gid(stack));
        out.extend(checks::prereq_tls_san(stack));
    }
    if options.wants("package") {
        out.extend(checks::package_dir_consistency(stack));
    }
    if options.wants("render") {
        out.extend(checks::render_freshness(stack, profile));
        out.extend(checks::render_placeholders(stack, profile));
    }
    if options.wants("secret") {
        out.extend(checks::secret_perms(stack, profile));
        out.extend(checks::private_key_mode(stack, profile));
    }
    if options.wants("package") {
        out.extend(checks::package_pairing(stack));
    }
    if options.wants("identity") {
        out.extend(checks::identity_paths(stack));
    }
    if options.wants("knowledge") {
        out.extend(checks::initial_knowledge_layout(stack));
    }
    if options.wants("tls") {
        out.extend(checks::tls_certificate(stack));
    }
    if options.wants("port") {
        out.extend(checks::ports_available(stack, &vars, profile));
    }
    if options.wants("image") {
        out.extend(checks::image_reachable(
            stack,
            &vars,
            profile,
            options.offline,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_prefix_runs_one_group_only() {
        let root =
            std::env::temp_dir().join(format!("wist-stackcheck-only-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let stack = Stack::new(&root);

        let findings = run_with(
            &stack,
            &Options {
                offline: true,
                only: Some("render".to_string()),
            },
        );
        assert!(
            findings
                .iter()
                .all(|finding| finding.code.starts_with("render.")),
            "{findings:#?}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
