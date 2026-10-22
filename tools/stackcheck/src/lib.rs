//! 栈级配置检查（`wist-stackcheck`）。
//!
//! **只校验「栈自己生成的东西」**：渲染产物及其新鲜度、目录/挂载约定、投放包与签名配对、
//! 密钥文件权限。组件配置键的语义（某个值是否合法、某个键属于哪个结构体）由**组件自己**负责
//! —— 那里有 `deny_unknown_fields` 与 `diagnose`，只有它知道键的含义。
//!
//! 这样切分的理由：本检查器与**栈**同版本发布（它随栈的约定一起变），所以它不需要知道
//! 组件的版本；组件则相反。
//!
//! 输出对齐 `gops run diagnose` 的 Flow Result v1（`schema_version` + `checks[]`），
//! 便于聚合到同一次体检里。

use std::path::PathBuf;

pub mod checks;

/// 单条检查的结论等级。`Ord` 用于取「最差」（`Fail > Warn > Ok`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Ok,
    Warn,
    Fail,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Warn => "warn",
            Status::Fail => "fail",
        }
    }

    /// 进程退出码：0 = 全好，1 = 有 WARN，2 = 有 FAIL。
    pub fn exit_code(self) -> u8 {
        match self {
            Status::Ok => 0,
            Status::Warn => 1,
            Status::Fail => 2,
        }
    }
}

/// 一条检查结果。字段名与 Flow Result v1 的 `checks[]` 一致。
#[derive(Debug, Clone)]
pub struct Finding {
    pub code: String,
    pub status: Status,
    /// 它「修不好就别升级 / 别启动」吗？
    ///
    /// `Fail` 但**不阻断**的典型例子：知识库包缺 `.sig` —— 它会让「以后导入」失败，
    /// 但当前跑着的栈是好的，不能因此拦下一个升级。
    pub blocking: bool,
    pub title: String,
    pub detail: String,
    pub hint: String,
}

impl Finding {
    pub fn ok(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            status: Status::Ok,
            blocking: false,
            title: title.into(),
            detail: detail.into(),
            hint: String::new(),
        }
    }

    pub fn warn(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            status: Status::Warn,
            ..Self::ok(code, title, detail)
        }
    }

    pub fn fail(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            status: Status::Fail,
            blocking: true,
            ..Self::ok(code, title, detail)
        }
    }

    /// 标记「失败但不阻断升级/启动」（见 [`Finding::blocking`]）。
    pub fn non_blocking(mut self) -> Self {
        self.blocking = false;
        self
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = hint.into();
        self
    }
}

/// 被检查的栈根（应含 `sys/`、`configs/`、`packages/`、`identity/`）。
#[derive(Debug, Clone)]
pub struct Stack {
    pub root: PathBuf,
}

impl Stack {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// 栈内相对路径的绝对化。**不做** `canonicalize` —— 被检查的目标可能还不存在，
    /// 而且宿主要求的是「配置里写的那个路径」，不是它解析后的真身。
    pub fn at(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }
}

/// 运行选项（由 CLI 传入）。
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// 跳过需要联网的检查（镜像可达）。离线站点应该打开。
    pub offline: bool,
    /// 只跑某一组（按 code 前缀过滤，`--only prereq`）。
    ///
    /// 为什么需要：`flow localize` **开头**要跑一次前置条件检查，而那一刻
    /// `apply` 刚把新包的文件换过来、还没重渲 —— `render.freshness.*` 这类判据
    /// 会**合理地**判 FAIL（模板新于渲染产物）。全量闸门放在那里会误拦一切升级。
    pub only: Option<String>,
}

/// 跑全部检查（默认选项）。顺序固定（输出可 diff、可回归）。
pub fn run(stack: &Stack) -> Vec<Finding> {
    run_with(stack, &Options::default())
}

pub fn run_with(stack: &Stack, options: &Options) -> Vec<Finding> {
    // `--only <前缀>`：按组懒惰过滤（不跑的检查既不 spawn 进程，也不会产生
    // 「这一刻本来就不该判」的 FAIL）。
    let wanted = |group: &str| {
        options
            .only
            .as_deref()
            .is_none_or(|only| group.starts_with(only))
    };

    let mut out = Vec::new();
    // 前置条件放最前：它是「后面这些能不能成立」的前提。
    if wanted("prereq") {
        out.extend(checks::prereq_toolchain());
        out.extend(checks::prereq_tls_san(stack));
    }
    if wanted("package") {
        out.extend(checks::package_dir_consistency(stack));
    }
    if wanted("render") {
        out.extend(checks::render_freshness(stack));
        out.extend(checks::render_placeholders(stack));
    }
    if wanted("secret") {
        out.extend(checks::secret_perms(stack));
    }
    if wanted("package") {
        out.extend(checks::package_pairing(stack));
    }
    if wanted("identity") {
        out.extend(checks::identity_paths(stack));
    }
    if wanted("knowledge") {
        out.extend(checks::initial_knowledge_layout(stack));
    }
    if wanted("tls") {
        out.extend(checks::tls_certificate(stack));
    }
    if wanted("port") {
        out.extend(checks::ports_available(stack));
    }
    if wanted("image") {
        out.extend(checks::image_reachable(stack, options.offline));
    }
    out
}

/// 最差等级（没有检查项 = `Ok`）。
pub fn worst(findings: &[Finding]) -> Status {
    findings
        .iter()
        .map(|finding| finding.status)
        .max()
        .unwrap_or(Status::Ok)
}

/// 是否存在**阻断类**失败（`--gate` 的判据）。
pub fn has_blocking_failure(findings: &[Finding]) -> bool {
    findings
        .iter()
        .any(|finding| finding.status == Status::Fail && finding.blocking)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_prefix_runs_one_group_only() {
        let root = std::env::temp_dir().join(format!(
            "wist-stackcheck-only-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let stack = Stack::new(&root);

        let findings = run_with(
            &stack,
            &Options {
                offline: true,
                only: Some("prereq".to_string()),
            },
        );
        // 空目录里 prereq 只产生两条（命令齐备 / 还没证书），且都在 prereq.* 下。
        assert!(!findings.is_empty());
        assert!(
            findings.iter().all(|finding| finding.code.starts_with("prereq.")),
            "--only prereq 不该带出别的组：{:?}",
            findings.iter().map(|f| &f.code).collect::<Vec<_>>()
        );

        // 别的组同样不会捞到 prereq（否则开头那次前置检查就成了全量跑的伪装）
        let package = run_with(
            &stack,
            &Options {
                offline: true,
                only: Some("package".to_string()),
            },
        );
        assert!(
            package.iter().all(|finding| !finding.code.starts_with("prereq.")),
            "--only package 不应包含 prereq：{:?}",
            package.iter().map(|f| &f.code).collect::<Vec<_>>()
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn blocking_flag_separates_gate_failures_from_soft_ones() {
        let soft = Finding::fail("package.knowledge_signature", "t", "").non_blocking();
        let warn = Finding::warn("package.knowledge_signature.history", "t", "");
        assert!(!has_blocking_failure(&[soft.clone(), warn.clone()]));
        // 对体检（diagnose）而言它仍然是 FAIL：该修。
        assert_eq!(worst(&[soft, warn]), Status::Fail);

        let hard = Finding::fail("package.drop_dir", "t", "");
        assert!(has_blocking_failure(&[hard]));
    }
}
