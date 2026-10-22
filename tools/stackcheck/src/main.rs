//! `wist-stackcheck` CLI。
//!
//! 两种消费方式：
//! - **`gops run diagnose`**：由 `GOPS_DIAGNOSE_RESULT`（或 `--result`）指定结果文件，
//!   写 Flow Result v1 后**始终退出 0**——判定结论在 `checks[]` 里，不该让流程中断；
//! - **CI / 手工**：不写结果文件时，退出码就是判定（0 ok / 1 warn / 2 fail）。

use std::path::PathBuf;
use std::process::ExitCode;

use wist_stackcheck::{Finding, Stack, Status, run, worst};

const USAGE: &str = "\
wist-stackcheck — 栈级配置检查

检查栈自己生成的东西：目录/挂载自洽、渲染新鲜度、占位符、密钥权限、知识库包签名配对。
组件配置键的语义不在这里（由组件启动时的严格解析与 `diagnose` 负责）。

用法：
  wist-stackcheck [--root <栈根>] [--format text|json] [--result <文件>]

选项：
  --root <dir>     栈根（含 sys/ configs/ packages/ identity/），缺省 = 当前目录
  --format <fmt>   text（缺省，人读）| json（Flow Result v1）
  --result <file>  另写一份 JSON 结果；也认环境变量 GOPS_DIAGNOSE_RESULT
                   （**追加**到已有 `checks[]`：同一份体检里可以多个流程段各自报）
  -h, --help       本帮助

退出码：
  写了结果文件（diagnose 模式）→ 始终 0，结论看 checks[]；
  否则 → 0 全好 / 1 有 WARN / 2 有 FAIL。
";

fn main() -> ExitCode {
    let args = match Args::parse(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(message) => {
            eprintln!("{message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };

    let findings = run(&Stack::new(&args.root));
    let verdict = worst(&findings);

    if args.json {
        println!("{}", to_json(&findings));
    } else {
        print_text(&findings, verdict);
    }

    let Some(path) = &args.result else {
        return ExitCode::from(verdict.exit_code());
    };
    if let Err(err) = write_result(path, &to_json(&findings)) {
        eprintln!("写结果文件失败 {}：{err}", path.display());
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}

/// 写 Flow Result v1；文件已存在时**追加** `checks[]`。
///
/// `gops run diagnose` 只读**一个**结果文件，而一个 flow 里可以有多个诊断动作
/// （wparse 漂移、栈级配置…）。谁都不该默默覆盖前面那份，所以这里做追加：
/// 先读旧 `checks`，再接上自己的。旧文件不是合法 JSON 时告警后重写（不静默丢数据）。
fn write_result(path: &std::path::Path, mine: &serde_json::Value) -> std::io::Result<()> {
    let mut checks: Vec<serde_json::Value> = Vec::new();
    if let Ok(text) = std::fs::read_to_string(path)
        && !text.trim().is_empty()
    {
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(existing) => {
                if let Some(items) = existing.get("checks").and_then(|value| value.as_array()) {
                    checks.extend(items.iter().cloned());
                }
            }
            Err(err) => eprintln!(
                "提示：{} 不是合法的 Flow Result（{err}），将覆盖",
                path.display()
            ),
        }
    }
    if let Some(items) = mine.get("checks").and_then(|value| value.as_array()) {
        checks.extend(items.iter().cloned());
    }
    let merged = serde_json::json!({
        "schema_version": "1",
        "source": "diagnose",
        "checks": checks,
    });
    std::fs::write(path, format!("{merged}\n"))
}

struct Args {
    root: PathBuf,
    json: bool,
    result: Option<PathBuf>,
}

impl Args {
    fn parse(mut args: impl Iterator<Item = String>) -> Result<Option<Self>, String> {
        let mut root: Option<PathBuf> = None;
        let mut format = String::from("text");
        let mut result: Option<PathBuf> = None;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => return Ok(None),
                "--root" => {
                    let value = args.next().ok_or("--root 需要一个路径")?;
                    root = Some(PathBuf::from(value));
                }
                "--format" => {
                    format = args.next().ok_or("--format 需要 text 或 json")?;
                }
                "--result" => {
                    let value = args.next().ok_or("--result 需要一个路径")?;
                    result = Some(PathBuf::from(value));
                }
                other => return Err(format!("未知参数：{other}")),
            }
        }

        let json = match format.as_str() {
            "text" => false,
            "json" => true,
            other => return Err(format!("--format 只支持 text / json，收到 {other}")),
        };

        // gops 的体检契约：结果写进这个文件，流程本身不该失败。
        if result.is_none()
            && let Ok(path) = std::env::var("GOPS_DIAGNOSE_RESULT")
            && !path.trim().is_empty()
        {
            result = Some(PathBuf::from(path));
        }

        Ok(Some(Self {
            root: root.unwrap_or_else(|| PathBuf::from(".")),
            json,
            result,
        }))
    }
}

fn to_json(findings: &[Finding]) -> serde_json::Value {
    let checks: Vec<serde_json::Value> = findings
        .iter()
        .map(|finding| {
            serde_json::json!({
                "code": finding.code,
                "status": finding.status.as_str(),
                "title": finding.title,
                "detail": finding.detail,
                "hint": finding.hint,
            })
        })
        .collect();
    serde_json::json!({
        "schema_version": "1",
        "source": "diagnose",
        "checks": checks,
    })
}

fn print_text(findings: &[Finding], verdict: Status) {
    for finding in findings {
        println!(
            "[{:<4}] {} — {}",
            finding.status.as_str().to_uppercase(),
            finding.code,
            finding.title
        );
        if !finding.detail.trim().is_empty() {
            println!("       {}", finding.detail);
        }
        if !finding.hint.trim().is_empty() {
            println!("       → {}", finding.hint);
        }
    }

    let total = findings.len();
    let fails = findings.iter().filter(|f| f.status == Status::Fail).count();
    let warns = findings.iter().filter(|f| f.status == Status::Warn).count();
    let oks = total - fails - warns;
    println!();
    println!(
        "{total} 项检查：{oks} ok / {warns} warn / {fails} fail（结论：{}）",
        verdict.as_str()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Option<Args>, String> {
        Args::parse(args.iter().map(|value| value.to_string()))
    }

    #[test]
    fn defaults_to_text_and_current_directory() {
        let args = parse(&[]).unwrap().unwrap();
        assert!(!args.json);
        assert_eq!(args.root, PathBuf::from("."));
    }

    #[test]
    fn accepts_root_and_json() {
        let args = parse(&["--root", "/tmp/stack", "--format", "json"])
            .unwrap()
            .unwrap();
        assert!(args.json);
        assert_eq!(args.root, PathBuf::from("/tmp/stack"));
    }

    #[test]
    fn rejects_unknown_format() {
        assert!(parse(&["--format", "yaml"]).is_err());
    }

    #[test]
    fn rejects_unknown_flag() {
        assert!(parse(&["--nope"]).is_err());
    }

    #[test]
    fn appends_findings_to_an_existing_result_file() {
        let dir = std::env::temp_dir().join(format!(
            "wist-stackcheck-merge-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("result.json");
        std::fs::write(
            &path,
            r#"{"schema_version":"1","source":"diagnose","checks":[{"code":"wparse.work_drift","status":"ok","title":"t","detail":"","hint":""}]}"#,
        )
        .unwrap();

        let mine = serde_json::json!({
            "checks": [{"code": "package.drop_dir", "status": "fail", "title": "t", "detail": "", "hint": ""}]
        });
        write_result(&path, &mine).unwrap();

        let merged: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let codes: Vec<&str> = merged["checks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|check| check["code"].as_str().unwrap())
            .collect();
        assert_eq!(codes, vec!["wparse.work_drift", "package.drop_dir"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
