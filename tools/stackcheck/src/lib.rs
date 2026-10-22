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
            ..Self::ok(code, title, detail)
        }
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

/// 跑全部检查。顺序固定（输出可 diff、可回归）。
pub fn run(stack: &Stack) -> Vec<Finding> {
    let mut out = Vec::new();
    out.extend(checks::package_dir_consistency(stack));
    out.extend(checks::render_freshness(stack));
    out.extend(checks::render_placeholders(stack));
    out.extend(checks::secret_perms(stack));
    out.extend(checks::package_pairing(stack));
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
