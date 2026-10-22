//! gateway-stack 的判据参数（`StackProfile`）。
//!
//! 通用判据从 `wist-stackcheck-core` 取；这里只声明本栈的渲染对、占位值文件与密钥根。
//! package / knowledge / identity / prereq 等专属判据仍在 `checks.rs`。

use wist_stackcheck_core::profile::{IdentityFile, Missing, MountSpec, Profile, RenderPair, SecretFile};

pub const GATEWAY: Profile = Profile {
    project_fallback: "wist-gateway-stack",

    render_pairs: &[
        RenderPair {
            code: "render.freshness.gwlinkd",
            rendered: "configs/gwlinkd/gwlinkd.toml",
            source: "configs/gwlinkd/gwlinkd.value.json",
        },
        RenderPair {
            code: "render.freshness.gateway",
            rendered: "configs/gateway/wist-gateway.toml",
            source: "configs/gateway/wist-gateway.value.json",
        },
        RenderPair {
            code: "render.freshness.web",
            rendered: "configs/web/nginx.conf",
            source: "configs/web/nginx.value.json",
        },
    ],

    placeholder_files: &[
        "configs/gwlinkd/gwlinkd.toml",
        "configs/gwlinkd/gwlinkd.value.json",
        "configs/gateway/wist-gateway.toml",
        "configs/gateway/wist-gateway.value.json",
        "configs/web/nginx.conf",
        // 接口层（现场态）：对外基址 / 客户归属 —— 现场没填过就是模板占位值。
        "identity/gateway/public/wist-gateway-pub.toml",
    ],
    placeholder_patterns: wist_stackcheck_core::profile::PLACEHOLDER_PATTERNS,

    // 网关栈没有 `domain.configured` 判据；域名由 placeholder 扫描覆盖。
    domains: &[],

    secret_files: &[SecretFile {
        path: ".wist/sec-value.yml",
        label: "栈根密钥（含 admin token）",
        missing: Missing::Fail,
        blocking: true,
    }],

    private_key_roots: &["identity"],

    // gateway 的身份材料由 `identity_paths` 单独判（签名公钥 / gwlinkd 路径）。
    identity_files: &[] as &[IdentityFile],

    // 投放目录的 compose 挂载由 `package_dir_consistency` 判（target 是变量派生值）。
    mounts: &[] as &[MountSpec],

    schema_file: None,
    public_url: None,
    server_cert: None,
};
