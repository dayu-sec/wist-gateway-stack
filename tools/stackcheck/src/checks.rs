//! 五组栈级检查。每组只回答一个问题，输出 `Finding`（Flow Result v1 的 `checks[]`）。
//!
//! 判据全部来自**栈自己生成的东西**：`sys/merged_vars.yml`（变量）、`configs/*`（渲染产物）、
//! `sys/docker-compose.yml`（挂载）、`packages/`（投放区）、`identity/`（密钥）。

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

use crate::{Finding, Stack};

// ── 通用工具 ────────────────────────────────────────────────────────────────

/// 读 `sys/merged_vars.yml` 的 `- name: / value:` 对。
///
/// 用行扫描而不是引入 YAML 依赖：该文件由 gops 生成、形状固定（`- name: X` 紧接
/// `  value: Y`）。读不到时返回 `Err` —— 让检查报 FAIL，而不是静默当成「没配」。
fn merged_vars(stack: &Stack) -> Result<BTreeMap<String, String>, String> {
    let path = stack.at("sys/merged_vars.yml");
    let text = fs::read_to_string(&path)
        .map_err(|err| format!("读不到 {}：{err}", path.display()))?;
    let mut out = BTreeMap::new();
    let mut name: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("- name:") {
            name = Some(unquote(rest.trim()).to_string());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("value:")
            && let Some(current) = name.take()
        {
            out.insert(current, unquote(rest.trim()).to_string());
        }
    }
    // 文件在但一条也没解出来 = 形状变了（改名 / 截断 / 换成别的 YAML 风格）。
    // 不能静默返回空表：下面的检查会回落到缺省值，于是「什么都没配」看起来像「配对了」。
    if out.is_empty() {
        return Err(format!(
            "{} 里没有任何 `- name:` / `value:` 条目（格式不认识）",
            path.display()
        ));
    }
    Ok(out)
}

/// 读**生效值**。
///
/// `gops sys localize` 把合并后的生效值写在栈根 `.env`；`sys/merged_vars.yml` 存的是
/// **默认值**（`gops sys` 输出里叫 INITIAL，不是 EFFECTIVE）。拿默认值去判会错：
/// 站点一旦覆盖 `PACKAGE_DIR`（完全合法的现场选择），路径自洽就永远对不上，
/// 而这条一旦误判就变成「升级被闸门拦住」。
fn effective_vars(stack: &Stack) -> Result<(BTreeMap<String, String>, &'static str), String> {
    let env = stack.at(".env");
    if let Ok(text) = fs::read_to_string(&env) {
        let mut out = BTreeMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                out.insert(key.trim().to_string(), unquote(value.trim()).to_string());
            }
        }
        if !out.is_empty() {
            return Ok((out, ".env"));
        }
    }
    // 还没 localize 过（首次部署）：只能拿默认值，并在 detail 里写明来源。
    Ok((merged_vars(stack)?, "sys/merged_vars.yml（默认值）"))
}

fn unquote(value: &str) -> &str {
    let bytes = value.as_bytes();
    if bytes.len() >= 2
        && ((bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\'')
            || (bytes[0] == b'"' && bytes[bytes.len() - 1] == b'"'))
    {
        &value[1..value.len() - 1]
    } else {
        value
    }
}

/// 在 TOML 文档里定位某个键，返回它**所在段的路径**（文档根 = 空串）。
///
/// 这是「键被渲染进错误的段」这类故障的判据：TOML 里段头（`[table]` / `[[array]]`）之后
/// 的键归属该段，写在 `[[upgrade.component]]` 之后就会变成最后一个元素的字段，
/// 组件在文档根读到的是 `None`。
fn locate_key(value: &toml::Value, key: &str, prefix: &str) -> Option<String> {
    match value {
        toml::Value::Table(table) => {
            if table.contains_key(key) {
                return Some(prefix.to_string());
            }
            for (name, child) in table {
                let child_prefix = if prefix.is_empty() {
                    name.clone()
                } else {
                    format!("{prefix}.{name}")
                };
                if let Some(hit) = locate_key(child, key, &child_prefix) {
                    return Some(hit);
                }
            }
            None
        }
        toml::Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                if let Some(hit) = locate_key(child, key, &format!("{prefix}[{index}]")) {
                    return Some(hit);
                }
            }
            None
        }
        _ => None,
    }
}

fn root_str(doc: &toml::Value, key: &str) -> Option<String> {
    doc.as_table()?.get(key)?.as_str().map(str::to_string)
}

/// 文档根上的原始值（用于判「是不是字符串」）。
fn root_value<'a>(doc: &'a toml::Value, key: &str) -> Option<&'a toml::Value> {
    doc.as_table()?.get(key)
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok().and_then(|meta| meta.modified().ok())
}

/// 渲染产物早于它的值文件 = 改了值没重渲。
fn render_is_stale(rendered: SystemTime, source: SystemTime) -> bool {
    rendered < source
}

fn trim_slash(value: &str) -> &str {
    value.trim_end_matches('/')
}

/// 词法归一：去掉 `.` 分量并折叠 `..`。
///
/// 不能用 `canonicalize`：被检查的路径可能还不存在（现场首次部署），而且它会把符号链接
/// 解析成真身 —— 而这里要比的是「配置里写的那个路径」。
fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;

    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

// ── 0. 环境前置条件（prereq）─────────────────────────────────────────────
//
// 这一组回答的不是「栈生成的东西对不对」，而是 **「这台机器能不能跑这个栈的 localize」**。
//
// 加它的直接原因（2026-10-23 升级事故）：`init-gateway.sh` 在 `openssl x509 -ext` 上静默退 1
// —— 交互式 shell 的 PATH 里有 Homebrew 的 OpenSSL（支持 `-ext`），而升级流程由 gwlinkd 派生，
// 解析到的是 macOS 自带的 LibreSSL（**不支持**）。同一份脚本、同一个栈，换个人跑就成/不成。
//
// 判据看两份 PATH（都要看，结论不同）：
//   1. **当前进程的 PATH**（= 这次 flow 实际会用的那份）：不满足就**阻断** —— 后面必然失败；
//   2. **守护进程的最低 PATH**（`/usr/bin:/bin:/usr/sbin:/sbin`）：交互式能过、这里过不了，
//      说明「本机能跑，但交给 gwlinkd 定时跑就炸」——报 WARN，不阻断（避免误拦开发机）。
//
// ⚠ 这里**不重新实现** SAN 解析：直接执行随包的 `scripts/lib/tls-san.sh`。
//    判据必须与真正跑的代码是**同一份实现**，否则又会变成「检查器说行、脚本说不行」的死锁。

/// 守护进程（launchd / systemd / gwlinkd 派生）能保证的最低 PATH。
const DAEMON_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

/// localize 流程里真正会用到、且**不保证**在最小 PATH 里的命令。
/// 不列 sed / awk / grep / tar：那些缺了整台机器都不正常，不用栈来报。
const REQUIRED_COMMANDS: &[&str] = &["bash", "openssl", "python3"];

/// 在给定 `PATH` 里找可执行文件（不 spawn 子进程，便于单测）。
fn which(command: &str, path: Option<&OsStr>) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;

    let path = path?;
    for dir in std::env::split_paths(path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        let candidate = dir.join(command);
        let Ok(meta) = fs::metadata(&candidate) else {
            continue;
        };
        if meta.is_file() && meta.permissions().mode() & 0o111 != 0 {
            return Some(candidate);
        }
    }
    None
}

/// 当前 `PATH` 下缺哪些必需命令（`sha256sum` 与 `shasum` 至少有一样即可）。
fn missing_commands(path: Option<&OsStr>) -> Vec<String> {
    let mut missing: Vec<String> = REQUIRED_COMMANDS
        .iter()
        .filter(|command| which(command, path).is_none())
        .map(|command| (*command).to_string())
        .collect();
    if which("sha256sum", path).is_none() && which("shasum", path).is_none() {
        missing.push("sha256sum|shasum".to_string());
    }
    missing
}

/// `prereq.toolchain`：localize 要用的命令是否两套 PATH 都找得到。
pub fn prereq_toolchain() -> Vec<Finding> {
    const CODE: &str = "prereq.toolchain";

    let inherited = std::env::var_os("PATH");
    let missing_current = missing_commands(inherited.as_deref());
    let missing_daemon = missing_commands(Some(OsStr::new(DAEMON_PATH)));
    vec![toolchain_finding(CODE, &missing_current, &missing_daemon)]
}

/// 把两组「缺什么」折成一条 `Finding`（纯函数，单测直接喂结果）。
fn toolchain_finding(code: &str, missing_current: &[String], missing_daemon: &[String]) -> Finding {
    // 当前 PATH 就缺 = 这次 flow 必然失败（不是「可能」）。
    if !missing_current.is_empty() {
        return Finding::fail(
            code,
            "localize 需要的命令在这台机器上不可用",
            format!(
                "当前 PATH 缺：{}（会依次跑 init-gateway / init-gwlinkd / install-initial-knowledge 等脚本）",
                missing_current.join("、")
            ),
        )
        .with_hint(
            "装好这些命令并放进 PATH；升级流程由 gwlinkd 派生，**不会**读你的交互式 shell 配置",
        );
    }
    // 交互式能过、守护进程的 PATH 过不了 = 现在能跑，哪天交给 gwlinkd 就炸。
    if !missing_daemon.is_empty() {
        return Finding::warn(
            code,
            "交互式能跑，但守护进程的 PATH 下缺命令",
            format!(
                "当前 PATH 齐全；缺的是守护进程的 PATH（{}）：{}",
                DAEMON_PATH,
                missing_daemon.join("、")
            ),
        )
        .with_hint(
            "把这些命令放到 /usr/bin，或固定进 gwlinkd 的 PATH（dev/gwlinkd.sh 的 plist/unit）",
        );
    }
    Finding::ok(
        code,
        "localize 需要的命令齐备",
        format!(
            "{}（当前 PATH 与守护进程的 PATH 都验过）",
            REQUIRED_COMMANDS.join("、") + "、sha256sum|shasum"
        ),
    )
}

/// 用某个 `PATH` 读网关叶证书 SAN 的结果。
enum SanProbe {
    /// 还没有叶证书（首次部署，localize 会签）。
    NoCert,
    /// 读出来了（可能是空串：证书里没有 DNS 型 SAN）。
    Read(String),
    /// 读失败（openssl 能力不足 / 输出被吞）。
    Failed(String),
    /// 随包 helper 不在（包不完整 / 有人手工拷过 `scripts/`）。
    /// 与 `Failed` 分开：**修法不同**（重解包 vs 换 openssl），提示不能写错。
    MissingHelper(String),
}

/// 执行**随包**的 `scripts/lib/tls-san.sh` 读 SAN。
///
/// `path` 为 `None` 时用当前进程的 PATH；给值时换成那份（用来探「守护进程能不能跑」）。
fn probe_san(stack: &Stack, cert: Option<&Path>, path: Option<&OsStr>) -> SanProbe {
    let Some(cert) = cert else {
        return SanProbe::NoCert;
    };
    let helper = stack.at("scripts/lib/tls-san.sh");
    if !helper.is_file() {
        return SanProbe::MissingHelper(format!("缺少 {}（安装包不完整）", helper.display()));
    }

    let mut command = Command::new("bash");
    command
        .arg("-c")
        .arg(". \"$1\" && wist_san_dns \"$2\"")
        .arg("wist-stackcheck-probe") // $0
        .arg(&helper) // $1
        .arg(cert); // $2
    if let Some(path) = path {
        // 探「守护进程能不能跑」时**清掉**交互式环境：`OPENSSL_CONF` / `OPENSSL_MODULES`
        // 这类变量会影响结果，留着就会把「本机能跑」误当成「守护进程也能跑」。
        command.env_clear().env("PATH", path);
    }
    if let Some(home) = std::env::var_os("HOME") {
        command.env("HOME", home);
    }

    let output = match command.output() {
        Ok(output) => output,
        Err(err) => return SanProbe::Failed(format!("无法执行 bash：{err}")),
    };
    if !output.status.success() {
        let code = output
            .status
            .code()
            .map(|code| code.to_string())
            .unwrap_or_else(|| "被信号终止".to_string());
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stderr = stderr.trim();
        return SanProbe::Failed(if stderr.is_empty() {
            format!("helper 退出码 {code}（stderr 为空）")
        } else {
            format!("helper 退出码 {code}：{stderr}")
        });
    }
    SanProbe::Read(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// `prereq.tls_san_reader`：证书脚本在这台机器上读得出 SAN 吗。
pub fn prereq_tls_san(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "prereq.tls_san_reader";

    let cert = leaf_cert_spec(stack)
        .and_then(|(_, candidates)| candidates.into_iter().find(|path| path.is_file()));
    let inherited = probe_san(stack, cert.as_deref(), None);
    let daemon = probe_san(stack, cert.as_deref(), Some(OsStr::new(DAEMON_PATH)));
    vec![san_finding(CODE, cert.as_deref(), &inherited, &daemon)]
}

/// 把两次探测结果折成一条 `Finding`（纯函数，单测直接喂结果）。
fn san_finding(
    code: &str,
    cert: Option<&Path>,
    inherited: &SanProbe,
    daemon: &SanProbe,
) -> Finding {
    let Some(cert) = cert else {
        if let SanProbe::Failed(reason) | SanProbe::MissingHelper(reason) = inherited {
            // 没有证书时也可能说读不出（缺随包 helper）：那也是包不完整，要拦。
            return Finding::fail(code, "证书脚本缺失", reason.clone())
                .with_hint("重新解包部署包（scripts/lib/tls-san.sh 随包发布）");
        }
        return Finding::ok(
            code,
            "还没有网关叶证书，跳过 SAN 读取",
            "首次部署由 init-gateway.sh 签发；签发后再跑一次就能验",
        );
    };

    // 0) 随包 helper 不在：不是 openssl 的问题，修法是重新解包。
    if let SanProbe::MissingHelper(reason) = inherited {
        return Finding::fail(code, "证书脚本缺失", reason.clone()).with_hint(
            "重新解包部署包（`scripts/lib/tls-san.sh` 自 0.2.6-alpha 起随包发布）；\
             手工拷过 scripts/ 的站点最容易缺它",
        );
    }

    // 1) **当前 PATH 读不出**：这次 flow 后面必然失败，直接拦。
    if let SanProbe::Failed(reason) = inherited {
        return Finding::fail(
            code,
            "证书脚本读不出叶证书 SAN",
            format!(
                "{}；openssl: {}；{reason}",
                cert.display(),
                describe_openssl()
            ),
        )
        .with_hint(
            "脚本已改用 `openssl x509 -text`（LibreSSL 也支持）；还读不出就是 openssl 本身有问题：\
             把它换掉，或给流程的 PATH 加一份支持 `-text` 的 openssl",
        );
    }

    // 2) 交互式能读，换成守护进程的 PATH 就不行。
    //
    // ⚠ 这里必须把「读不出（退出码非 0）」和「**静默读空**」一起算进来：
    //   老实现 `x509 -ext | tr | sed` 在 LibreSSL 下 openssl 失败但管道退出码来自 sed ——
    //   于是 helper **退出 0、输出为空**。只看退出码就会把事故判成 OK。
    let daemon_problem = match daemon {
        SanProbe::Failed(reason) | SanProbe::MissingHelper(reason) => {
            Some(format!("读不出：{reason}"))
        }
        SanProbe::Read(names) if names.is_empty() => {
            Some("静默读空（一个 DNS 名都没有）".to_string())
        }
        _ => None,
    };
    let names = match inherited {
        SanProbe::Read(names) => names,
        _ => {
            return Finding::ok(
                code,
                "还没有网关叶证书，跳过 SAN 读取",
                cert.display().to_string(),
            );
        }
    };

    if names.is_empty() {
        // 两套 PATH 都读空：要么证书真的没有 DNS 型 SAN，要么环境两边都不行。
        // 不阻断（localize 下一轮会重签），只提醒。
        return Finding::warn(
            code,
            "叶证书里读不出 DNS 型 SAN",
            format!(
                "{}：{} 与守护进程的 PATH 下都是空的",
                cert.display(),
                describe_openssl()
            ),
        )
        .with_hint("localize 下一轮会按 WEB_DOMAIN 重签（幂等），无需手工处理");
    }
    if let Some(problem) = daemon_problem {
        return Finding::warn(
            code,
            "交互式能读证书，但守护进程的 PATH 下读不了 SAN",
            format!(
                "{}：PATH={} 下{problem}；当前用的是 {}",
                cert.display(),
                DAEMON_PATH,
                describe_openssl()
            ),
        )
        .with_hint("把能用的 openssl 放进 /usr/bin，或固定进 gwlinkd 的 PATH（dev/gwlinkd.sh）");
    }
    Finding::ok(
        code,
        "证书脚本能读出叶证书 SAN",
        format!("{}：[{}]", cert.display(), names.replace('\n', ", ")),
    )
}

/// 报错时点明「用的是哪份 openssl」——PATH 差异正是事故里最难反查的部分。
///
/// 不打整条 PATH：几百个字符里没人看得出关键的那一个目录。
fn describe_openssl() -> String {
    let inherited = std::env::var_os("PATH");
    let Some(bin) = which("openssl", inherited.as_deref()) else {
        return "当前 PATH 里找不到 openssl".to_string();
    };
    let version = Command::new(&bin)
        .arg("version")
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        // `openssl version` 会带一长串 `(Library: …)`：只留前半句，告警里够用。
        .map(|version| match version.split(" (Library:").next() {
            Some(head) => head.trim().to_string(),
            None => version,
        })
        .filter(|version| !version.is_empty())
        .unwrap_or_else(|| "版本未知".to_string());
    format!("{}（{version}）", bin.display())
}

// ── 1. 投放目录 / 挂载自洽 ─────────────────────────────────────────────────

/// `PACKAGE_DIR` ↔ compose 挂载 ↔ `agent_package_container_dir` ↔ `agent_package_drop_dir`
/// 四者必须指向同一份目录，且交付区是它的 `agents` 子目录（独占：gwlinkd 交付后按 mtime
/// 只留最新 N 份且不区分类型，与知识库包混放会把后者清掉）。
pub fn package_dir_consistency(stack: &Stack) -> Vec<Finding> {
    let mut out = Vec::new();

    let (vars, vars_source) = match effective_vars(stack) {
        Ok(pair) => pair,
        Err(err) => {
            out.push(
                Finding::fail("package.vars", "读不到合并后的系统变量", err)
                    .with_hint("先跑一次 `gops sys localize`（生成 .env / sys/merged_vars.yml）再检查"),
            );
            return out;
        }
    };

    let package_dir = vars
        .get("PACKAGE_DIR")
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("./packages");
    let container_base = vars
        .get("GWLINKD_AGENT_PACKAGE_CONTAINER_DIR")
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("/packages");

    let host_base = if Path::new(package_dir).is_absolute() {
        PathBuf::from(package_dir)
    } else {
        stack.root.join(package_dir)
    };
    let expected_drop = normalize(&host_base.join("agents"));
    let expected_drop = expected_drop.display().to_string();
    let expected_container = format!("{}/agents", trim_slash(container_base));

    let toml_path = stack.at("configs/gwlinkd/gwlinkd.toml");
    let doc: toml::Value = match fs::read_to_string(&toml_path) {
        Ok(text) => match toml::from_str(&text) {
            Ok(doc) => doc,
            Err(err) => {
                out.push(Finding::fail(
                    "package.config",
                    "gwlinkd 主配置无法解析",
                    format!("{}：{err}", toml_path.display()),
                ));
                return out;
            }
        },
        Err(err) => {
            out.push(Finding::fail(
                "package.config",
                "读不到 gwlinkd 主配置",
                format!("{}：{err}", toml_path.display()),
            ));
            return out;
        }
    };

    for (code, key, expected, what) in [
        (
            "package.drop_dir",
            "agent_package_drop_dir",
            expected_drop.clone(),
            "宿主投放目录",
        ),
        (
            "package.container_dir",
            "agent_package_container_dir",
            expected_container.clone(),
            "容器内投放路径",
        ),
    ] {
        match locate_key(&doc, key, "") {
            None => out.push(
                Finding::fail(
                    code,
                    format!("{what}未配置"),
                    format!("{} 里找不到 `{key}`", toml_path.display()),
                )
                .with_hint("模板必须渲染该项：② Agent 包交付缺它就会 fail-closed"),
            ),
            Some(section) if section.is_empty() => {
                let Some(raw) = root_value(&doc, key) else {
                    out.push(Finding::fail(
                        code,
                        format!("{what}读不到值"),
                        format!("`{key}` 在表结构里但取不到"),
                    ));
                    continue;
                };
                let Some(actual) = raw.as_str() else {
                    out.push(Finding::fail(
                        code,
                        format!("{what}不是字符串"),
                        format!("`{key}` 渲染成了非字符串：{raw} —— 模板里少了引号？"),
                    ));
                    continue;
                };

                // gwlinkd 的 cwd 不定：宿主路径必须是绝对的，否则会落到启动目录下。
                if key == "agent_package_drop_dir" && !Path::new(actual.trim()).is_absolute() {
                    out.push(
                        Finding::fail(
                            code,
                            format!("{what}不是绝对路径"),
                            format!("实际 `{actual}`"),
                        )
                        .with_hint("init-gwlinkd.sh 会把相对 PACKAGE_DIR 绝对化；别手工改回相对路径"),
                    );
                    continue;
                }

                let actual_path = normalize(Path::new(actual.trim()));
                let expected_path = normalize(Path::new(&expected));
                let same = if key == "agent_package_drop_dir" {
                    actual_path == expected_path
                } else {
                    trim_slash(actual.trim()) == trim_slash(&expected)
                };
                if same {
                    out.push(Finding::ok(
                        code,
                        format!("{what}与 PACKAGE_DIR 派生值一致"),
                        format!("{actual}（变量来源 {vars_source}）"),
                    ));
                } else {
                    out.push(
                        Finding::fail(
                            code,
                            format!("{what}与 PACKAGE_DIR 派生值不一致"),
                            format!("实际 `{actual}`，期望 `{expected}`"),
                        )
                        .with_hint(
                            "两项由 scripts/init-gwlinkd.sh 从 PACKAGE_DIR / \
                             GWLINKD_AGENT_PACKAGE_CONTAINER_DIR 派生，别手工错位",
                        ),
                    );
                }
            }
            Some(section) => out.push(
                Finding::fail(
                    code,
                    format!("{what}落在了错误的 TOML 段"),
                    format!(
                        "`{key}` 在 `{section}` 里，不在文档根 —— gwlinkd 在根读到的是 None"
                    ),
                )
                .with_hint("把它渲染到任何段头（[table] / [[array]]）之前"),
            ),
        }
    }

    // compose 挂载：容器路径必须与 GWLINKD_AGENT_PACKAGE_CONTAINER_DIR 同源。
    //
    // 文件名候选与 gops 自己的 compose 发现**同一套**（`sys/docker-compose.yml` 优先，
    // 也认 `compose.yml` / `.yaml` 与仓根的旧布局）—— 写死一个名字等于把部署形态钉死。
    let compose_path = compose_file(stack);
    let compose_path = match compose_path {
        Some(path) => path,
        None => {
            out.push(
                Finding::fail(
                    "package.compose_mount",
                    "找不到 compose 文件",
                    "按 gops 的候选顺序（sys/docker-compose.yml 等）都没找到",
                )
                .with_hint("确认栈目录完整（`sys/docker-compose.yml` 随制品发布）"),
            );
            return out;
        }
    };
    match fs::read_to_string(&compose_path) {
        Ok(compose) => match package_mount_target(&compose) {
            Some(target) if trim_slash(&target) == trim_slash(container_base) => out.push(
                Finding::ok(
                    "package.compose_mount",
                    "compose 已把投放目录挂到容器",
                    format!("${{PACKAGE_DIR}}:{target}"),
                ),
            ),
            Some(target) => out.push(
                Finding::fail(
                    "package.compose_mount",
                    "compose 挂载点与配置不一致",
                    format!(
                        "compose 挂 `{target}`，配置用 `{}`",
                        trim_slash(container_base)
                    ),
                )
                .with_hint("两侧都由 GWLINKD_AGENT_PACKAGE_CONTAINER_DIR 派生"),
            ),
            None => out.push(
                Finding::fail(
                    "package.compose_mount",
                    "compose 里找不到投放目录挂载",
                    format!(
                        "{} 里没有 `${{PACKAGE_DIR}}:…` 的 volume",
                        compose_path.display()
                    ),
                )
                .with_hint("网关容器读不到宿主路径，本地包必须先落到被挂进来的目录"),
            ),
        },
        Err(err) => out.push(Finding::warn(
            "package.compose_mount",
            "读不到 compose 文件，跳过挂载检查",
            format!("{}：{err}", compose_path.display()),
        )),
    }

    out
}

/// compose 文件的发现顺序（与 gops 的 `compose_invocation` 同口径）。
fn compose_file(stack: &Stack) -> Option<PathBuf> {
    const CANDIDATES: &[&str] = &[
        "sys/docker-compose.yml",
        "sys/docker-compose.yaml",
        "sys/compose.yml",
        "sys/compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ];
    CANDIDATES
        .iter()
        .map(|name| stack.at(name))
        .find(|path| path.is_file())
}

/// 从 compose 文本里取 `${PACKAGE_DIR}:<target>[:ro]` 的 target（短语法），
/// 兼容长语法（`source: ${PACKAGE_DIR}` 附近的 `target:`）。
fn package_mount_target(compose: &str) -> Option<String> {
    let lines: Vec<&str> = compose.lines().collect();

    // 短语法：`- ${PACKAGE_DIR}:/packages:ro`
    for line in &lines {
        let Some(rest) = line.trim().strip_prefix("- ") else {
            continue;
        };
        let Some((src, dst)) = rest.split_once(':') else {
            continue;
        };
        if !src.contains("PACKAGE_DIR") {
            continue;
        }
        return Some(dst.split(':').next().unwrap_or(dst).trim().to_string());
    }

    // 长语法：
    //   - type: bind
    //     source: ${PACKAGE_DIR}
    //     target: /packages
    // 在源行前后各看两行（`target` 可能在 `source` 之前）。
    for (index, line) in lines.iter().enumerate() {
        if !line.contains("PACKAGE_DIR") || !line.contains("source") {
            continue;
        }
        let start = index.saturating_sub(2);
        let end = (index + 3).min(lines.len());
        for candidate in &lines[start..end] {
            if let Some((_, target)) = candidate.split_once("target:") {
                return Some(target.trim().trim_matches('"').to_string());
            }
        }
    }
    None
}

// ── 2. 渲染产物新鲜度 ──────────────────────────────────────────────────────

/// 渲染产物（`gx.tpl` 的输出）必须不早于它的值文件 —— 否则就是「改了值没重渲」。
pub fn render_freshness(stack: &Stack) -> Vec<Finding> {
    const PAIRS: &[(&str, &str, &str)] = &[
        (
            "render.freshness.gwlinkd",
            "configs/gwlinkd/gwlinkd.toml",
            "configs/gwlinkd/gwlinkd.value.json",
        ),
        (
            "render.freshness.gateway",
            "configs/gateway/wist-gateway.toml",
            "configs/gateway/wist-gateway.value.json",
        ),
        (
            "render.freshness.web",
            "configs/web/nginx.conf",
            "configs/web/nginx.value.json",
        ),
    ];

    let mut out = Vec::new();
    for &(code, rendered_rel, source_rel) in PAIRS {
        let rendered = stack.at(rendered_rel);
        let source = stack.at(source_rel);
        let (rendered_at, source_at) = (modified(&rendered), modified(&source));
        match (rendered_at, source_at) {
            // 两侧都在：正常判。
            (Some(rendered_at), Some(source_at)) => {
                if render_is_stale(rendered_at, source_at) {
                    out.push(
                        Finding::fail(
                            code,
                            "渲染产物比它的值文件旧",
                            format!("{rendered_rel} 早于 {source_rel}"),
                        )
                        .with_hint("跑一次 `gops sys localize`（改了值必须重渲才生效）"),
                    );
                } else {
                    out.push(Finding::ok(
                        code,
                        "渲染产物不早于值文件",
                        rendered_rel.to_string(),
                    ));
                }
            }
            // 只有值文件：渲染没生成 → 该跑 localize（不能当成「这个组未部署」而静默跳过）。
            (None, Some(_)) => out.push(Finding::warn(
                code,
                "值文件在，但渲染产物缺失",
                rendered_rel.to_string(),
            )
            .with_hint("跑一次 `gops sys localize`")),
            // 只有渲染产物：判不了新旧（但说明目录对得上，不必报）。
            (Some(_), None) => out.push(Finding::ok(
                code,
                "无值文件，跳过新鲜度比较",
                rendered_rel.to_string(),
            )),
            // 两侧都没有：这个组未部署，静默跳过。
            (None, None) => {}
        }
    }
    out
}

// ── 3. 占位符 ──────────────────────────────────────────────────────────────

/// 渲染产物里不该留占位值（`example.com` 之类）—— 否则脚本会拿它当真值去连。
pub fn render_placeholders(stack: &Stack) -> Vec<Finding> {
    const FILES: &[&str] = &[
        "configs/gwlinkd/gwlinkd.toml",
        "configs/gwlinkd/gwlinkd.value.json",
        "configs/gateway/wist-gateway.toml",
        "configs/gateway/wist-gateway.value.json",
        "configs/web/nginx.conf",
        // 接口层（现场态）：对外基址 / 客户归属 —— 现场没填过就是模板占位值。
        "identity/gateway/public/wist-gateway-pub.toml",
    ];
    const PATTERNS: &[&str] = &["example.com", "CHANGEME", "changeme"];

    let mut hits = Vec::new();
    let mut scanned = 0usize;
    for rel in FILES {
        let Ok(text) = fs::read_to_string(stack.at(rel)) else {
            continue;
        };
        scanned += 1;
        for (index, line) in text.lines().enumerate() {
            for pattern in PATTERNS {
                if line.contains(pattern) {
                    hits.push(format!("{rel}:{}: {pattern}", index + 1));
                }
            }
        }
    }

    if hits.is_empty() {
        // 一个文件都没扫到 = `--root` 指错了，或配置根本还没渲染。不能报绿：
        // 那会让「什么都没查」看起来像「都没问题」。
        if scanned == 0 {
            return vec![Finding::warn(
                "render.placeholder",
                "找不到任何渲染产物，跳过占位值检查",
                "configs/ 下没有可读的配置文件（--root 指对了吗？跑过 localize 吗？）",
            )];
        }
        return vec![Finding::ok(
            "render.placeholder",
            "渲染产物里没有占位值",
            format!("扫描 {scanned} 个文件"),
        )];
    }
    let shown = hits.iter().take(10).cloned().collect::<Vec<_>>().join("；");
    vec![
        Finding::fail(
            "render.placeholder",
            "渲染产物里还有占位值",
            format!("{} 处：{shown}", hits.len()),
        )
        .with_hint("把 WEB_DOMAIN 等站点值写进 values/ 后重渲；占位值会让脚本连到不存在的域名"),
    ]
}

// ── 4. 密钥文件权限 ────────────────────────────────────────────────────────

/// 栈根密钥与私钥不能被「其他用户」读到。权限位语义各家不同，这里只看 world 位。
pub fn secret_perms(stack: &Stack) -> Vec<Finding> {
    #[cfg(not(unix))]
    {
        let _ = stack;
        return vec![Finding::ok(
            "secret.file_mode",
            "非 unix 平台，跳过权限检查",
            "",
        )];
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mut out = Vec::new();

        // 栈根密钥文件（含 admin token）。
        let secret = stack.at(".wist/sec-value.yml");
        match fs::metadata(&secret) {
            Ok(meta) => {
                let mode = meta.permissions().mode() & 0o777;
                if mode & 0o007 != 0 {
                    out.push(
                        Finding::fail(
                            "secret.file_mode",
                            "栈根密钥对其他用户可读",
                            format!(".wist/sec-value.yml 权限 {:o}（含 admin token）", mode),
                        )
                        .with_hint("改成 640（容器靠属组读，不需要放开 world 位）"),
                    );
                } else if mode & 0o020 != 0 {
                    // 属组可写 = 同组任何人都能改写 admin token。不能阻断（有些现场靠 660
                    // 让容器属组写入），但必须提示。
                    out.push(
                        Finding::warn(
                            "secret.file_mode",
                            "栈根密钥对属组可写",
                            format!(".wist/sec-value.yml 权限 {:o}", mode),
                        )
                        .with_hint("若不需要属组写入，收到 640"),
                    );
                } else {
                    out.push(Finding::ok(
                        "secret.file_mode",
                        "栈根密钥权限正常",
                        format!("{:o}", mode),
                    ));
                }
            }
            // 缺这个文件 = 网关装载密钥失败（fail-closed），这是真问题，不是提示。
            Err(_) => out.push(
                Finding::fail(
                    "secret.file_mode",
                    "找不到栈根密钥文件",
                    format!("{}（网关装载密钥会 fail-closed）", secret.display()),
                )
                .with_hint("跑一次 `gops sys localize`（init-gateway.sh 会生成它）"),
            ),
        }

        // 私钥：扫 identity/，按内容识别（不靠文件名猜）。
        let mut files = Vec::new();
        walk_files(&stack.at("identity"), 5, &mut files);
        let mut leaked = Vec::new();
        let mut checked = 0usize;
        for path in files {
            let Ok(meta) = fs::metadata(&path) else {
                continue;
            };
            if meta.len() > 512 * 1024 {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            if !text.contains("PRIVATE KEY") {
                continue;
            }
            checked += 1;
            let mode = meta.permissions().mode() & 0o777;
            if mode & 0o007 != 0 {
                leaked.push(format!(
                    "{}（{:o}）",
                    path.strip_prefix(&stack.root).unwrap_or(&path).display(),
                    mode
                ));
            }
        }

        if leaked.is_empty() {
            out.push(Finding::ok(
                "secret.private_key_mode",
                "私钥文件不对其他用户开放",
                format!("检查 {checked} 个私钥文件"),
            ));
        } else {
            out.push(
                Finding::fail(
                    "secret.private_key_mode",
                    "私钥对其他用户可读",
                    leaked.join("；"),
                )
                .with_hint("私钥应为 600/640；world 位一律收回"),
            );
        }

        out
    }
}

fn walk_files(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_files(&path, depth - 1, out);
        } else if path.is_file() {
            out.push(path);
        }
    }
}

// ── 5. 知识库包与签名配对 ──────────────────────────────────────────────────

/// 配了验签公钥时，**最新**那个知识库包必须有同名 `.sig` —— 否则导入会在用到时才 422。
/// 历史包的缺失只计数（不报），因为它们本来就不再被重放。
pub fn package_pairing(stack: &Stack) -> Vec<Finding> {
    let dir = stack.at("packages");
    let Ok(entries) = fs::read_dir(&dir) else {
        return vec![Finding::ok(
            "package.knowledge_signature",
            "没有投放目录，跳过包配对检查",
            dir.display().to_string(),
        )];
    };

    let mut tarballs: Vec<(SystemTime, PathBuf)> = Vec::new();
    let mut sigs: Vec<PathBuf> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.starts_with("wist-knowledge-") && name.ends_with(".tar.gz") && path.is_file() {
            tarballs.push((
                modified(&path).unwrap_or(SystemTime::UNIX_EPOCH),
                path.clone(),
            ));
        } else if name.ends_with(".sig") {
            sigs.push(path);
        }
    }

    if tarballs.is_empty() {
        return vec![Finding::ok(
            "package.knowledge_signature",
            "投放目录里没有知识库包",
            dir.display().to_string(),
        )];
    }

    tarballs.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    let signing = knowledge_signing_configured(stack);
    let mut out = Vec::new();

    let (_, newest) = &tarballs[0];
    let newest_name = newest
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let newest_sig = newest.with_file_name(format!("{newest_name}.sig"));

    if !signing {
        out.push(Finding::ok(
            "package.knowledge_signature",
            "未配置知识库验签公钥，签名非必需",
            newest_name.to_string(),
        ));
    } else if newest_sig.is_file() {
        out.push(Finding::ok(
            "package.knowledge_signature",
            "最新知识库包有签名",
            format!("{newest_name}.sig"),
        ));
    } else {
        out.push(
            Finding::fail(
                "package.knowledge_signature",
                "最新知识库包缺签名",
                format!("{} 旁边没有 .sig（导入会 422 package_signature_invalid）", newest_name),
            )
            .with_hint("把发布侧的 *.tar.gz.sig 一起放进 packages/；签名是 base64 文本")
            // 不阻断：它会让「以后导入」失败，但当前跑着的栈是好的 —— 不该因此拦下升级。
            .non_blocking(),
        );
    }

    let missing_old = tarballs
        .iter()
        .skip(1)
        .filter(|(_, path)| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| !path.with_file_name(format!("{name}.sig")).is_file())
                .unwrap_or(false)
        })
        .count();
    if signing && missing_old > 0 {
        out.push(Finding::warn(
            "package.knowledge_signature.history",
            "历史知识库包缺签名",
            format!("{missing_old} 个旧包没有 .sig（不影响已生效内容）"),
        ));
    }

    let orphans: Vec<String> = sigs
        .iter()
        .filter(|sig| {
            sig.file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".sig"))
                .map(|base| !dir.join(base).is_file())
                .unwrap_or(false)
        })
        .map(|sig| {
            sig.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .to_string()
        })
        .collect();
    if !orphans.is_empty() {
        out.push(Finding::warn(
            "package.knowledge_signature.orphan",
            "有 .sig 找不到对应的包",
            orphans.join("、"),
        ));
    }

    out
}

fn knowledge_signing_configured(stack: &Stack) -> bool {
    if stack
        .at("identity/gateway/public/knowledge-signing.pub.pem")
        .is_file()
    {
        return true;
    }
    let path = stack.at("configs/gateway/wist-gateway.toml");
    let Ok(text) = fs::read_to_string(&path) else {
        return false;
    };
    let Ok(doc) = toml::from_str::<toml::Value>(&text) else {
        return false;
    };
    root_str(&doc, "knowledge_signing_pubkey").is_some_and(|value| !value.trim().is_empty())
}

// ── 6. 身份材料路径 ──────────────────────────────────────────────────────

/// 知识库验签公钥（`knowledge_signing_pubkey`）与 gwlinkd 的路径类现场值。
///
/// 两处原来只在生成脚本里「闪一下」：`init-knowledge-signing.sh` 找不到源文件就退，
/// `init-gwlinkd-pub.sh` 打一行 WARN 就过去了。搬成检查项后 `diagnose` 与升级闸门都会覆盖。
pub fn identity_paths(stack: &Stack) -> Vec<Finding> {
    let mut out = Vec::new();

    // (a) 知识库验签公钥：配了就必须找得到，否则导入会在用到时才 500/422。
    let signing = fs::read_to_string(stack.at("configs/gateway/wist-gateway.value.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|doc| {
            doc.get("knowledge_signing_pubkey")
                .and_then(|value| value.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();

    if signing.trim().is_empty() {
        out.push(Finding::ok(
            "identity.signing_pubkey",
            "未配置知识库验签公钥",
            "验签关闭（知识库包无需 .sig）",
        ));
    } else {
        let raw = signing.trim();
        // 同一个相对路径可能落在栈根 / configs/gateway / identity/gateway 三处之一。
        let candidates = relative_candidates(stack, raw);
        match candidates.iter().find(|path| path.is_file()) {
            Some(found) => out.push(Finding::ok(
                "identity.signing_pubkey",
                "知识库验签公钥就位",
                found
                    .strip_prefix(&stack.root)
                    .unwrap_or(found)
                    .display()
                    .to_string(),
            )),
            None => out.push(
                Finding::fail(
                    "identity.signing_pubkey",
                    "知识库验签公钥指向的文件不存在",
                    format!("`{raw}` 在 {} 个候选位置都没找到", candidates.len()),
                )
                // 不阻断：跑着的栈是好的，只是以后导入知识库会失败。
                .non_blocking()
                .with_hint("把公钥放回 identity/gateway/public/，或清空该项关闭验签"),
            ),
        }
    }

    // (b) gwlinkd 的路径类现场值。
    let toml_path = stack.at("configs/gwlinkd/gwlinkd.toml");
    let mut missing = Vec::new();
    let mut checked = 0usize;

    for (label, dir) in [
        (
            "state_dir",
            root_str_of(&toml_path, "state_dir"),
        ),
        (
            "identity_dir",
            root_str_of(&toml_path, "identity_dir"),
        ),
    ] {
        let Some(dir) = dir.filter(|value| !value.trim().is_empty()) else {
            continue;
        };
        checked += 1;
        if !resolve(stack, dir.trim()).is_dir() {
            // 首次启动前两者本来就不存在（gwlinkd 自己会建）—— 只提示，不阻断。
            missing.push(format!("{label}={dir}（未创建，运行后会生成）"));
        }
    }

    if let Ok(text) = fs::read_to_string(stack.at("identity/gwlinkd/.env")) {
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            if key.trim() != "GWLINKD_TRUST_BUNDLE" {
                continue;
            }
            let value = value.trim();
            if value.is_empty() {
                continue; // 空 = 回落系统根，正常。
            }
            let value = unquote(value);
            checked += 1;
            if !Path::new(value).is_file() {
                missing.push(format!(
                    "GWLINKD_TRUST_BUNDLE={value}（gwlinkd 会报 UnknownIssuer）"
                ));
            }
        }
    }

    if missing.is_empty() {
        out.push(Finding::ok(
            "identity.gwlinkd_paths",
            "gwlinkd 的路径类现场值都在",
            format!("检查 {checked} 项"),
        ));
    } else {
        out.push(
            Finding::warn(
                "identity.gwlinkd_paths",
                "gwlinkd 的路径类现场值有悬空项",
                missing.join("；"),
            )
            .with_hint("跑一次 `gops sys localize`：能自愈的会改回期望位置"),
        );
    }

    out
}

fn root_str_of(path: &Path, key: &str) -> Option<String> {
    config_str(path, None, key)
}

/// 读 `[section].key`（`section = None` 时读文档根）。两边都试一次，兼容配置搬家。
fn config_str(path: &Path, section: Option<&str>, key: &str) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    let doc = toml::from_str::<toml::Value>(&text).ok()?;
    let table = match section {
        Some(name) => doc.get(name)?,
        None => &doc,
    };
    table.get(key)?.as_str().map(str::to_string)
}

fn resolve(stack: &Stack, raw: &str) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        stack.at(raw)
    }
}

/// 网关配置里的**相对路径**（相对 `/config`）在宿主上的落点。
///
/// 容器里 `/config/identity/...` 挂的就是宿主 `identity/gateway/...`，所以同一串
/// `identity/public/x.pem` 可能在三个地方之一；都认，避免把正常部署误判为悬空。
fn relative_candidates(stack: &Stack, raw: &str) -> Vec<PathBuf> {
    if Path::new(raw).is_absolute() {
        let mut out = vec![PathBuf::from(raw)];
        // 容器内**绝对**路径（`/config/...`）：同一挂载映射回宿主。
        // 模板现在写的是相对路径，但站点手改成 `/config/identity/...` 也一样能用。
        if let Some(rest) = raw.strip_prefix("/config/") {
            out.push(stack.at(rest));
            out.push(stack.at("configs/gateway").join(rest));
            let under_identity = match rest.strip_prefix("identity/") {
                Some(tail) => stack.at("identity/gateway").join(tail),
                None => stack.at("identity/gateway").join(rest),
            };
            out.push(under_identity);
        }
        return out;
    }
    let mut candidates = vec![stack.at(raw), stack.at("configs/gateway").join(raw)];
    let under_identity = match raw.strip_prefix("identity/") {
        Some(rest) => stack.at("identity/gateway").join(rest),
        None => stack.at("identity/gateway").join(raw),
    };
    candidates.push(under_identity);
    candidates
}

// ── 8. TLS 证书 ──────────────────────────────────────────────────────────

/// 网关叶证书必须在有效期内、且 SAN 覆盖 `WEB_DOMAIN`。
///
/// 这条原来在 `init-gateway.sh` 里是
/// `openssl x509 -ext subjectAltName | grep -q "DNS:${domain}"`：
/// 正则里的 `.` 是**通配符**，且是**子串**匹配 —— 证书 SAN 为
/// `gw.example.com.evil.net` 时也会判过。这里做真解析 + 精确匹配。
/// 网关叶证书的「配置里写的值 + 它可能所在的绝对路径」。
///
/// 两个调用方：`tls_certificate`（真解析 SAN / 有效期）与 `prereq_tls_san`
/// （拿**随包脚本**去读 SAN，验「这台机器跑不跑得动 localize」）。
fn leaf_cert_spec(stack: &Stack) -> Option<(String, Vec<PathBuf>)> {
    let toml_path = stack.at("configs/gateway/wist-gateway.toml");
    // 真实形状是 `[server] tls_cert_file = …`；也认文档根（以后搬家不会静默失效）。
    let raw = config_str(&toml_path, Some("server"), "tls_cert_file")
        .or_else(|| config_str(&toml_path, None, "tls_cert_file"))?;
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    Some((raw.to_string(), relative_candidates(stack, raw)))
}

pub fn tls_certificate(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "tls.san_covers_domain";

    let toml_path = stack.at("configs/gateway/wist-gateway.toml");
    let Some((raw, candidates)) = leaf_cert_spec(stack) else {
        return vec![Finding::warn(
            CODE,
            "网关配置里没有 tls_cert_file",
            toml_path.display().to_string(),
        )];
    };

    let Some(found) = candidates.iter().find(|path| path.is_file()) else {
        return vec![Finding::fail(
            CODE,
            "网关叶证书不存在",
            format!("`{raw}` 在 {} 个候选位置都没找到", candidates.len()),
        )
        .with_hint("跑一次 `gops sys localize`（init-gateway.sh 会签发）")];
    };

    let Ok(bytes) = fs::read(found) else {
        return vec![Finding::fail(
            CODE,
            "网关叶证书读不了",
            found.display().to_string(),
        )];
    };
    let Ok((_, pem)) = x509_parser::pem::parse_x509_pem(&bytes) else {
        return vec![Finding::fail(
            CODE,
            "网关叶证书不是合法 PEM",
            found.display().to_string(),
        )];
    };
    let Ok((_, cert)) = x509_parser::parse_x509_certificate(&pem.contents) else {
        return vec![Finding::fail(
            CODE,
            "网关叶证书无法解析",
            found.display().to_string(),
        )];
    };

    let validity = cert.validity();
    if !validity.is_valid() {
        return vec![Finding::fail(
            CODE,
            "网关叶证书不在有效期内",
            format!(
                "notBefore={} notAfter={}",
                validity.not_before, validity.not_after
            ),
        )
        .with_hint("重新签发：删掉 identity/gateway/{public,private}/admin-tls.* 后跑 localize")];
    }

    let Some(domain) = effective_vars(stack)
        .ok()
        .and_then(|(vars, _)| vars.get("WEB_DOMAIN").cloned())
        .map(|value| value.trim().trim_end_matches('.').to_ascii_lowercase())
        .filter(|value| !value.is_empty())
    else {
        return vec![Finding::warn(
            CODE,
            "WEB_DOMAIN 为空，跳过 SAN 判定",
            "证书本身在有效期内（这一项只能判 expire）",
        )];
    };

    let sans = certificate_dns_names(&cert);
    if sans.iter().any(|san| san_covers(san, &domain)) {
        return vec![Finding::ok(
            CODE,
            "叶证书 SAN 覆盖 WEB_DOMAIN",
            format!("{domain} ∈ [{}]", sans.join(", ")),
        )];
    }
    vec![
        Finding::fail(
            CODE,
            "叶证书 SAN 不覆盖 WEB_DOMAIN",
            format!("WEB_DOMAIN={domain}，证书 SAN=[{}]", sans.join(", ")),
        )
        .with_hint("跑一次 `gops sys localize`：init-gateway.sh 发现 SAN 缺域名会重签"),
    ]
}

fn certificate_dns_names(cert: &x509_parser::prelude::X509Certificate<'_>) -> Vec<String> {
    cert.subject_alternative_name()
        .ok()
        .flatten()
        .map(|extension| {
            extension
                .value
                .general_names
                .iter()
                .filter_map(|name| match name {
                    x509_parser::extensions::GeneralName::DNSName(dns) => Some((*dns).to_string()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 证书 SAN 是否覆盖某个域名：**精确相等**，或通配符只覆盖**一层**。
fn san_covers(san: &str, domain: &str) -> bool {
    let san = san.trim().trim_end_matches('.').to_ascii_lowercase();
    let domain = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    if san == domain {
        return true;
    }
    let Some(suffix) = san.strip_prefix("*.") else {
        return false;
    };
    domain
        .strip_suffix(suffix)
        .and_then(|head| head.strip_suffix('.'))
        .is_some_and(|label| !label.is_empty() && !label.contains('.'))
}

/// `configs/gateway/knowledge/initial/` 的五份数据文件。
///
/// `install-initial-knowledge.sh` 解包后会校验一次，但**只在那一刻**；之后手工动过目录、
/// 或从备份搬进来半套，就没人再管。这里把它变成常驻判据。
pub fn initial_knowledge_layout(stack: &Stack) -> Vec<Finding> {
    const FILES: &[&str] = &[
        "catalog.toml",
        "packs.toml",
        "templates.toml",
        "purpose-rules.toml",
        "aspect-policies.toml",
    ];

    let dir = stack.at("configs/gateway/knowledge/initial");
    if !dir.is_dir() {
        return vec![Finding::warn(
            "knowledge.initial_layout",
            "没有初始知识库目录",
            dir.display().to_string(),
        )
        .with_hint("ARTIFACT_HOME / KNOWLEDGE_PATH 为空时这是正常的；否则跑一次 localize")];
    }

    let missing: Vec<&str> = FILES
        .iter()
        .copied()
        .filter(|name| !dir.join(name).is_file())
        .collect();

    if !missing.is_empty() {
        return vec![
            Finding::fail(
                "knowledge.initial_layout",
                "初始知识库缺文件",
                format!("{} 缺：{}", dir.display(), missing.join("、")),
            )
            .with_hint("包布局与预期不符（解包只解了一层？）；重跑 install-initial-knowledge.sh"),
        ];
    }

    let version = fs::read_to_string(dir.join("manifest.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|doc| {
            doc.get("version")
                .and_then(|value| value.as_str())
                .map(str::to_string)
        })
        .unwrap_or_else(|| "未知".to_string());

    vec![Finding::ok(
        "knowledge.initial_layout",
        "初始知识库布局完整",
        format!("5 份文件齐全，版本 {version}"),
    )]
}

// ── 9. 宿主端口 ──────────────────────────────────────────────────────────

/// 一个发布到宿主的端口。
#[derive(Debug, Clone, PartialEq, Eq)]
struct PublishedPort {
    host_port: u16,
    protocol: String,
}

/// 展开 compose 里的 `${VAR}` / `${VAR:-default}`（只认这两种）。
fn expand(raw: &str, vars: &BTreeMap<String, String>) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let expr = &after[..end];
        let (name, default) = match expr.split_once(":-") {
            Some((name, default)) => (name, Some(default)),
            None => (expr, None),
        };
        match vars.get(name.trim()) {
            Some(value) if !value.trim().is_empty() => out.push_str(value),
            _ => out.push_str(default.unwrap_or("")),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

/// 取 compose 里**所有**同名块键（`ports:`）下缩进更深的行。
///
/// 必须扫全部块：`ports:` 每个 service 各有一份，只取第一个的话，
/// 端口检查实际只看了一个服务（实测：第 1 个是 VM，于是其余 4 个端口全没查）。
fn compose_blocks<'a>(compose: &'a str, key: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut block_indent: Option<usize> = None;
    let header = format!("{key}:");
    for line in compose.lines() {
        let trimmed = line.trim();
        let indent = line.len() - line.trim_start().len();
        let is_header = trimmed == header || trimmed.starts_with(&header);
        match block_indent {
            Some(base) if indent > base => {
                if !trimmed.is_empty() && !trimmed.starts_with('#') {
                    out.push(line);
                }
            }
            Some(_) | None => {
                // 块结束（或还没开始）：这一行本身可能是下一个块头。
                block_indent = is_header.then_some(indent);
            }
        }
    }
    out
}

fn compose_ports(compose: &str, vars: &BTreeMap<String, String>) -> Vec<PublishedPort> {
    let mut out = Vec::new();
    let lines = compose_blocks(compose, "ports");
    let mut index = 0usize;
    while index < lines.len() {
        let line = lines[index].trim();
        index += 1;
        let Some(item) = line.strip_prefix("- ") else {
            continue; // 长语法的后续键，已在上一个条目里处理
        };
        // 长语法：`- target: 3000` 加后续 `published: 443` / `protocol: udp`
        if item.contains("target:") || item.contains("published:") {
            let mut published = None;
            let mut protocol = "tcp".to_string();
            let mut scan = |text: &str| {
                if let Some((_, value)) = text.split_once("published:")
                    && let Ok(port) = value.trim().trim_matches('"').parse::<u16>()
                {
                    published = Some(port);
                }
                if let Some((_, value)) = text.split_once("protocol:") {
                    protocol = value.trim().trim_matches('"').to_string();
                }
            };
            scan(item);
            while index < lines.len() && !lines[index].trim().starts_with("- ") {
                scan(lines[index]);
                index += 1;
            }
            if let Some(host_port) = published {
                out.push(PublishedPort {
                    host_port,
                    protocol,
                });
            }
            continue;
        }
        // 短语法：`"[ip:]host:container[/proto]"`
        let expanded = expand(item.trim().trim_matches('"'), vars);
        let owned = expanded.replace(['\'', '"'], "");
        let (spec, protocol) = match owned.split_once('/') {
            Some((spec, protocol)) => (spec.to_string(), protocol.to_string()),
            None => (owned.clone(), "tcp".to_string()),
        };
        let parts: Vec<&str> = spec.split(':').collect();
        // 短语法：`HOST:CONTAINER` 或 `IP:HOST:CONTAINER`（前者 2 段、后者 3 段）。
        // 且：2 段时**第一段**才是宿主端口 —— 取错就会拿容器端口去查宿主，永远查不出冲突。
        let host = match parts.as_slice() {
            [host, _container] => *host,
            [_ip, host, _container] => *host,
            _ => continue, // 只写了容器端口 = 不发布到宿主
        };
        if let Ok(host_port) = host.trim().parse::<u16>() {
            out.push(PublishedPort {
                host_port,
                protocol,
            });
        }
    }
    out
}

fn compose_images(compose: &str, vars: &BTreeMap<String, String>) -> Vec<String> {
    let mut out = Vec::new();
    for line in compose.lines() {
        let trimmed = line.trim();
        let Some(value) = trimmed.strip_prefix("image:") else {
            continue;
        };
        let image = expand(value.trim().trim_matches('"').trim_matches('\''), vars);
        if !image.is_empty() {
            out.push(image);
        }
    }
    out
}

/// 解析 `docker ps --format '{{.Ports}}'` 的发布端口（`0.0.0.0:443->3000/tcp, …`）。
fn published_ports_from_ps(output: &str) -> std::collections::HashSet<u16> {
    let mut ours = std::collections::HashSet::new();
    for chunk in output.split(',') {
        let Some((host_side, _)) = chunk.split_once("->") else {
            continue;
        };
        let Some((_, port)) = host_side.trim().rsplit_once(':') else {
            continue;
        };
        if let Ok(port) = port.parse::<u16>() {
            ours.insert(port);
        }
    }
    ours
}

fn tcp_port_is_free(port: u16) -> bool {
    std::net::TcpListener::bind(("0.0.0.0", port)).is_ok()
}

/// compose 的**项目名**（容器标签 `com.docker.compose.project` 的值）。
///
/// 为什么不用 `project.working_dir`：栈目录改过位置/换过名字后，仍在跑的容器会带着**旧路径**
/// 标签，按路径过滤会漏掉自己（典型症状：VM 容器属于同一项目却认不出来，18429 被当成
/// 「别的进程占用」）。项目名跨路径稳定。
fn compose_project_name(stack: &Stack, compose: &str) -> String {
    if let Ok(value) = std::env::var("COMPOSE_PROJECT_NAME")
        && !value.trim().is_empty()
    {
        return value.trim().to_string();
    }
    for line in compose.lines() {
        // 只认**顶格**的 `name:`（项目名）。缩进的是 volumes/networks 里的名字，
        // 例如 `volumes:\n  wparse-run:\n    name: wist-gateway-stack-wparse-run` ——
        // 认错会让项目名变成那个卷名，端口归属就全查不到了。
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some(value) = line.strip_prefix("name:") else {
            continue;
        };
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if !value.is_empty() {
            return value.to_string();
        }
        break;
    }
    stack
        .root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("wist-gateway-stack")
        .to_string()
}

fn our_published_ports(stack: &Stack, compose: &str) -> Option<std::collections::HashSet<u16>> {
    let filter = format!(
        "label=com.docker.compose.project={}",
        compose_project_name(stack, compose)
    );
    let (ok, stdout, _) = run_with_timeout(
        "docker",
        &["ps", "--filter", &filter, "--format", "{{.Ports}}"],
        10,
    )?;
    ok.then(|| published_ports_from_ps(&stdout))
}

/// 发布到宿主的端口是否真的空着。
///
/// 必须排除**本栈自己**占着的端口：升级的 `localize` 阶段容器正在跑，
/// 不排除就会每次误报。
fn ports_available_with(
    stack: &Stack,
    ours: Option<&std::collections::HashSet<u16>>,
) -> Vec<Finding> {
    const CODE: &str = "port.available";
    let Ok((vars, _)) = effective_vars(stack) else {
        return vec![Finding::warn(CODE, "读不到变量，跳过端口检查", "")];
    };
    let Some(compose_path) = compose_file(stack) else {
        return Vec::new(); // 缺 compose 已由 package.compose_mount 报
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return vec![Finding::warn(CODE, "读不到 compose，跳过端口检查", "")];
    };
    let ports = compose_ports(&compose, &vars);
    if ports.is_empty() {
        return vec![Finding::ok(CODE, "没有发布到宿主的端口", "")];
    }
    let Some(ours) = ours else {
        return vec![Finding::warn(
            CODE,
            "无法确认端口归属，跳过占用检查",
            "docker 不可用（没装或守护进程没起）",
        )
        .with_hint("栈跑着时端口本就被自己占着；手工确认用 `docker ps` / `lsof -i`")];
    };

    let mut conflicts = Vec::new();
    let mut skipped = 0usize;
    for port in &ports {
        if port.protocol != "tcp" || ours.contains(&port.host_port) {
            skipped += 1;
            continue;
        }
        if !tcp_port_is_free(port.host_port) {
            conflicts.push(port.host_port);
        }
    }
    conflicts.sort_unstable();
    conflicts.dedup();

    if conflicts.is_empty() {
        let checked = ports.len() - skipped;
        if checked == 0 {
            return vec![Finding::ok(
                CODE,
                "端口都由本栈自己占着，跳过占用检查",
                format!("{} 个发布端口（栈在运行）", ports.len()),
            )];
        }
        vec![Finding::ok(
            CODE,
            "宿主端口都空着",
            format!("已检查 {checked}/{}（{} 个由本栈占着 / udp）", ports.len(), skipped),
        )]
    } else {
        vec![
            Finding::fail(
                CODE,
                "宿主端口已被别的进程占用",
                format!(
                    "占用中：{}",
                    conflicts
                        .iter()
                        .map(u16::to_string)
                        .collect::<Vec<_>>()
                        .join("、")
                ),
            )
            .with_hint("`compose up` 会失败（port is already allocated）；腾端口或改 *_PORT"),
        ]
    }
}

/// 本栈**自己**已经发布的端口（用 compose 的 workdir 标签认出本栈容器）。
/// `None` = 无法判定 —— 那时不能拿「端口被占」去吓人。
fn run_with_timeout(program: &str, args: &[&str], secs: u64) -> Option<(bool, String, String)> {
    use std::process::{Command, Stdio};

    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = child.wait_with_output().ok()?;
                return Some((
                    status.success(),
                    String::from_utf8_lossy(&output.stdout).to_string(),
                    String::from_utf8_lossy(&output.stderr).to_string(),
                ));
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Some((false, String::new(), format!("超时（{secs}s）")));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(err) => return Some((false, String::new(), err.to_string())),
        }
    }
}

pub fn ports_available(stack: &Stack) -> Vec<Finding> {
    let compose = compose_file(stack).and_then(|path| fs::read_to_string(path).ok());
    let ours = compose
        .as_deref()
        .and_then(|text| our_published_ports(stack, text));
    ports_available_with(stack, ours.as_ref())
}

// ── 10. 镜像可达 ──────────────────────────────────────────────────────────

/// 网络类错误（整个站点离线时会全部命中）—— 收敛成一条提示，不按镜像刷屏。
fn looks_like_network_error(message: &str) -> bool {
    let lowered = message.to_ascii_lowercase();
    [
        "no such host",
        "timeout",
        "超时",
        "connection refused",
        "temporary failure in name resolution",
        "network is unreachable",
        "i/o timeout",
        "tls handshake timeout",
        "context deadline exceeded",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
}

fn image_reachable_with(
    stack: &Stack,
    probe: &(dyn Fn(&str) -> Result<(), String> + Sync),
) -> Vec<Finding> {
    const CODE: &str = "image.reachable";
    let Ok((vars, _)) = effective_vars(stack) else {
        return vec![Finding::warn(CODE, "读不到变量，跳过镜像检查", "")];
    };
    let Some(compose_path) = compose_file(stack) else {
        return Vec::new();
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return Vec::new();
    };
    let images = compose_images(&compose, &vars);
    if images.is_empty() {
        return vec![Finding::ok(CODE, "compose 里没有镜像", "")];
    }

    let mut broken = Vec::new();
    let mut offline = 0usize;
    // 并行探测：串行时一个慢 registry 会把体检拖成几十秒（实测 ghcr 单个 34s）。
    let results: Vec<Result<(), String>> = std::thread::scope(|scope| {
        let handles: Vec<_> = images
            .iter()
            .map(|image| scope.spawn(move || probe(image)))
            .collect();
        handles
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .unwrap_or_else(|_| Err("探测线程崩溃".to_string()))
            })
            .collect()
    });
    for (image, result) in images.iter().zip(results) {
        match result {
            Ok(()) => {}
            Err(err) if looks_like_network_error(&err) => offline += 1,
            Err(err) => broken.push(format!("{image}（{err}）")),
        }
    }

    if !broken.is_empty() {
        let shown = broken.iter().take(5).cloned().collect::<Vec<_>>().join("；");
        return vec![
            Finding::warn(
                CODE,
                "镜像在源上取不到",
                format!("{} 个：{shown}", broken.len()),
            )
            .non_blocking()
            .with_hint("确认 tag 与镜像源前缀（*_SPC / *_TAG）；`compose pull` 会失败在这里"),
        ];
    }
    if offline == images.len() {
        return vec![Finding::warn(
            CODE,
            "镜像源不可达（离线？）",
            format!("{offline} 个镜像全部拿不到 manifest"),
        )
        .with_hint("离线站点用 `--offline` 跳过本项，免得每次体检都报")];
    }
    vec![Finding::ok(
        CODE,
        "镜像在源上都能取到",
        format!("{} 个", images.len()),
    )]
}

pub fn image_reachable(stack: &Stack, offline: bool) -> Vec<Finding> {
    if offline {
        return vec![Finding::ok(
            "image.reachable",
            "跳过镜像可达检查（--offline）",
            "",
        )];
    }
    image_reachable_with(stack, &|image| {
        // 本地已有 → 不需要网络（`pull` 也会直接跳过）；这一步 55ms，远端 manifest 可能 34s。
        if let Some((true, _, _)) = run_with_timeout("docker", &["image", "inspect", image], 5) {
            return Ok(());
        }
        let Some((ok, _, stderr)) = run_with_timeout("docker", &["manifest", "inspect", image], 6)
        else {
            return Err("docker 不可用".to_string());
        };
        if ok {
            Ok(())
        } else {
            Err(stderr.trim().lines().next().unwrap_or("未知错误").to_string())
        }
    })
}

// ── 测试 ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;
    use crate::Status;

    /// 临时栈根；`Drop` 时清理。
    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new(tag: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "wist-stackcheck-{}-{tag}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(&root).unwrap();
            Self { root }
        }

        fn write(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.root.join(rel);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&path, body).unwrap();
            path
        }

        fn stack(&self) -> Stack {
            Stack::new(&self.root)
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    const VARS: &str = "\
- name: PACKAGE_DIR
  value: ./packages
- name: GWLINKD_AGENT_PACKAGE_CONTAINER_DIR
  value: /packages
";

    const COMPOSE: &str = "\
services:
  gateway:
    volumes:
      - ${PACKAGE_DIR}:/packages:ro
";

    #[test]
    fn flags_a_key_that_landed_in_another_toml_section() {
        let tree = Tree::new("wrong-section");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "\
state_dir = \"/tmp/state\"

[[upgrade.component]]
name = \"galaxy-flow\"
install = \"tool-copy\"
binary = \"gx\"
agent_package_drop_dir = \"/tmp/packages/agents\"
agent_package_container_dir = \"/packages/agents\"
",
        );

        let findings = package_dir_consistency(&tree.stack());
        let drop = findings
            .iter()
            .find(|finding| finding.code == "package.drop_dir")
            .expect("应有 package.drop_dir");
        assert_eq!(drop.status, Status::Fail);
        assert!(
            drop.detail.contains("upgrade.component[0]"),
            "detail 应指出真实位置：{}",
            drop.detail
        );
    }

    #[test]
    fn accepts_the_expected_layout() {
        let tree = Tree::new("good-layout");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", COMPOSE);
        let drop = tree.root.join("packages/agents");
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            &format!(
                "\
agent_package_drop_dir = \"{}\"
agent_package_container_dir = \"/packages/agents\"

[[upgrade.component]]
name = \"galaxy-flow\"
",
                drop.display()
            ),
        );

        let findings = package_dir_consistency(&tree.stack());
        assert!(
            findings.iter().all(|finding| finding.status == Status::Ok),
            "{findings:#?}"
        );
    }

    #[test]
    fn flags_a_render_older_than_its_value_file() {
        let tree = Tree::new("stale-render");
        let rendered = tree.write("configs/gwlinkd/gwlinkd.toml", "state_dir = \"/tmp\"\n");
        tree.write("configs/gwlinkd/gwlinkd.value.json", "{\"state_dir\":\"/tmp\"}\n");

        // 把渲染产物拨回一分钟前（值文件保持「现在」）。
        let file = File::options().write(true).open(&rendered).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();

        let findings = render_freshness(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.gwlinkd")
            .expect("应有 gwlinkd 的新鲜度检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
    }

    #[test]
    fn flags_placeholder_values_in_rendered_config() {
        let tree = Tree::new("placeholder");
        tree.write(
            "configs/gateway/wist-gateway.value.json",
            "{\"public_base_url\":\"https://gw.example.com\"}\n",
        );

        let findings = render_placeholders(&tree.stack());
        let finding = &findings[0];
        assert_eq!(finding.status, Status::Fail);
        assert!(finding.detail.contains("example.com"), "{}", finding.detail);
    }

    #[test]
    fn flags_the_newest_knowledge_package_without_a_signature() {
        let tree = Tree::new("pairing");
        tree.write("packages/wist-knowledge-0.4.0.tar.gz", "dummy");
        tree.write(
            "identity/gateway/public/knowledge-signing.pub.pem",
            "-----BEGIN PUBLIC KEY-----\n",
        );

        let findings = package_pairing(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.knowledge_signature")
            .expect("应有配对检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        // 缺签名是「不阻断」的：它不该拦下升级。
        assert!(!finding.blocking, "缺签名不应阻断升级");
        tree.write("packages/wist-knowledge-0.4.0.tar.gz.sig", "c2ln");
        let findings = package_pairing(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.knowledge_signature")
            .expect("应有配对检查");
        assert_eq!(finding.status, Status::Ok, "{finding:#?}");
    }

    // ── 第一轮审阅补的边界 ──────────────────────────────────────────────

    #[test]
    fn merged_vars_with_an_unknown_shape_fails_loudly() {
        let tree = Tree::new("vars-shape");
        // 文件在，但不是 gops 的 `- name:/value:` 形状（改名 / 截断 / 换了 YAML 风格）。
        tree.write("sys/merged_vars.yml", "variables:\n  PACKAGE_DIR: ./packages\n");
        tree.write("configs/gwlinkd/gwlinkd.toml", "agent_package_drop_dir = \"/tmp/a\"\n");

        let findings = package_dir_consistency(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.vars")
            .expect("形状不认识时必须有 package.vars");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.detail.contains("格式不认识"), "{}", finding.detail);
    }

    #[test]
    fn flags_a_drop_dir_that_is_not_a_string() {
        let tree = Tree::new("non-string");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", COMPOSE);
        // 模板里少了引号 —— 渲染出来就是布尔/整数，gwlinkd 反序列化直接失败。
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "agent_package_drop_dir = true\nagent_package_container_dir = \"/packages/agents\"\n",
        );

        let findings = package_dir_consistency(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.drop_dir")
            .expect("应有 package.drop_dir");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(
            finding.title.contains("不是字符串") && finding.detail.contains("true"),
            "{finding:#?}"
        );
    }

    #[test]
    fn flags_a_relative_drop_dir() {
        let tree = Tree::new("relative-drop");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "agent_package_drop_dir = \"packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
        );

        let findings = package_dir_consistency(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.drop_dir")
            .expect("应有 package.drop_dir");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.title.contains("绝对路径"), "{finding:#?}");
    }

    #[test]
    fn accepts_a_render_that_is_newer_than_its_value_file() {
        let tree = Tree::new("fresh-render");
        tree.write("configs/gwlinkd/gwlinkd.value.json", "{}\n");
        tree.write("configs/gwlinkd/gwlinkd.toml", "state_dir = \"/tmp\"\n");

        let findings = render_freshness(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.gwlinkd")
            .expect("应有新鲜度检查");
        assert_eq!(finding.status, Status::Ok, "{finding:#?}");
    }

    #[test]
    fn reports_history_gaps_and_orphan_signatures() {
        let tree = Tree::new("pairing-history");
        tree.write(
            "identity/gateway/public/knowledge-signing.pub.pem",
            "-----BEGIN PUBLIC KEY-----\n",
        );
        tree.write("packages/wist-knowledge-0.3.0.tar.gz", "old");
        tree.write("packages/wist-knowledge-0.4.0.tar.gz", "new");
        tree.write("packages/wist-knowledge-0.4.0.tar.gz.sig", "c2ln");
        // 孤立的 .sig：对应的包已经不在了。
        tree.write("packages/wist-knowledge-0.2.0.tar.gz.sig", "c2ln");

        let findings = package_pairing(&tree.stack());
        let by = |code: &str| {
            findings
                .iter()
                .find(|finding| finding.code == code)
                .unwrap_or_else(|| panic!("缺 {code}：{findings:#?}"))
        };
        assert_eq!(by("package.knowledge_signature").status, Status::Ok);
        assert_eq!(
            by("package.knowledge_signature.history").status,
            Status::Warn
        );
        assert_eq!(
            by("package.knowledge_signature.orphan").status,
            Status::Warn
        );
    }

    #[test]
    fn flags_a_missing_root_secret_file() {
        let tree = Tree::new("no-secret");
        let findings = secret_perms(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "secret.file_mode")
            .expect("应有密钥权限检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.blocking, "缺密钥文件会让网关 fail-closed，应阻断");
    }

    #[cfg(unix)]
    #[test]
    fn grades_root_secret_file_modes() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("secret-modes");
        let path = tree.write(".wist/sec-value.yml", "admin_token: x\n");
        let check = |mode: u32| {
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
            secret_perms(&tree.stack())
                .into_iter()
                .find(|finding| finding.code == "secret.file_mode")
                .expect("应有密钥权限检查")
        };

        assert_eq!(check(0o600).status, Status::Ok);
        assert_eq!(check(0o640).status, Status::Ok);
        assert_eq!(check(0o644).status, Status::Fail, "world 可读");
        assert_eq!(check(0o660).status, Status::Warn, "属组可写只提示");
    }

    // ── 第三轮审阅补的「假绿」用例 ────────────────────────────────────

    #[test]
    fn warns_instead_of_passing_when_nothing_was_scanned() {
        let tree = Tree::new("nothing-scanned");
        let findings = render_placeholders(&tree.stack());
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("跳过"), "{findings:#?}");
    }

    #[test]
    fn warns_when_the_value_file_exists_but_the_render_is_missing() {
        let tree = Tree::new("missing-render");
        tree.write("configs/gwlinkd/gwlinkd.value.json", "{}\n");

        let findings = render_freshness(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.gwlinkd")
            .expect("值文件在时应报一项");
        assert_eq!(finding.status, Status::Warn, "{finding:#?}");
        assert!(finding.title.contains("缺失"), "{finding:#?}");
    }

    // ── 新增的身份材料 / 初始知识库用例 ──────────────────────────────

    #[test]
    fn flags_a_missing_signing_public_key() {
        let tree = Tree::new("signing-pubkey");
        tree.write(
            "configs/gateway/wist-gateway.value.json",
            "{\"knowledge_signing_pubkey\":\"identity/public/knowledge-signing.pub.pem\"}\n",
        );

        let findings = identity_paths(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "identity.signing_pubkey")
            .expect("应有验签公钥检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(!finding.blocking, "公钥缺失不该拦升级");

        // 放在 identity/gateway/public/ 下应当被认出来（容器 `/config/identity` 那条路）。
        tree.write(
            "identity/gateway/public/knowledge-signing.pub.pem",
            "-----BEGIN PUBLIC KEY-----\n",
        );
        let findings = identity_paths(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "identity.signing_pubkey")
            .expect("应有验签公钥检查");
        assert_eq!(finding.status, Status::Ok, "{finding:#?}");
    }

    #[test]
    fn warns_about_dangling_gwlinkd_paths() {
        let tree = Tree::new("gwlinkd-paths");
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "state_dir = \"/nonexistent/state\"\nidentity_dir = \"/nonexistent/identity\"\n",
        );
        tree.write(
            "identity/gwlinkd/.env",
            "GWLINKD_TRUST_BUNDLE=/nonexistent/control-center.pem\n",
        );

        let findings = identity_paths(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "identity.gwlinkd_paths")
            .expect("应有 gwlinkd 路径检查");
        assert_eq!(finding.status, Status::Warn, "{finding:#?}");
        assert!(finding.detail.contains("GWLINKD_TRUST_BUNDLE"), "{finding:#?}");
    }

    #[test]
    fn checks_the_initial_knowledge_layout() {
        let tree = Tree::new("knowledge-layout");

        // 目录不在：提示（可能本来就关掉了初始知识库）。
        let findings = initial_knowledge_layout(&tree.stack());
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");

        // 只有一半文件：真问题（网关会加载一个残缺包）。
        tree.write("configs/gateway/knowledge/initial/catalog.toml", "");
        tree.write("configs/gateway/knowledge/initial/packs.toml", "");
        let findings = initial_knowledge_layout(&tree.stack());
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].detail.contains("templates.toml"), "{findings:#?}");

        // 补齐后 OK，并带出版本号。
        for name in [
            "templates.toml",
            "purpose-rules.toml",
            "aspect-policies.toml",
        ] {
            tree.write(&format!("configs/gateway/knowledge/initial/{name}"), "");
        }
        tree.write(
            "configs/gateway/knowledge/initial/manifest.json",
            "{\"version\":\"0.4.0\"}\n",
        );
        let findings = initial_knowledge_layout(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
        assert!(findings[0].detail.contains("0.4.0"), "{findings:#?}");
    }

    // ── TLS 证书用例（PEM 固定在此，单测不依赖 openssl） ────────────

    /// SAN = `DNS:gw.example.test, DNS:localhost`，有效期到 2036（生成于 2026-10-22）。
    const GOOD_CERT: &str = "-----BEGIN CERTIFICATE-----\n\
MIIDPDCCAiSgAwIBAgIUBUEMZZGnmtZmqcbpRU4/u8ROyTcwDQYJKoZIhvcNAQEL\n\
BQAwGjEYMBYGA1UEAwwPZ3cuZXhhbXBsZS50ZXN0MB4XDTI2MTAyMjE2NDE0OFoX\n\
DTM2MTAxOTE2NDE0OFowGjEYMBYGA1UEAwwPZ3cuZXhhbXBsZS50ZXN0MIIBIjAN\n\
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArraZ8kxDY14N5CBljxowDmnc5blM\n\
iwOzL2DgGiwIHS8/6MBWUsUxmdP/9Zj4YomOQeSipQ4flUaPWDKYFWkE8L++J7YO\n\
9RB19jewWBmHl3ToSRUPXLSkdBdfGYzc8qnrVYA6MMUuELQD/Y2HQ+nks4aLCnpv\n\
Px8UdXcqX6wEWlrszkxNGmdgPDegifUpAUaP9rPbmM1Wy5VqRWCbLL2loN2LkBWh\n\
3yAkqZUs7dXhCcGfaeiNPMCYcE28yHkC7l+0EELRnui6eMqEeC3evzqgligmTm7P\n\
bYK//omudDvKeGXAYF6+ZIOACvD5CD+CUhH64D/RIvx72Nao/hJSiPp0xwIDAQAB\n\
o3oweDAdBgNVHQ4EFgQUu5LeBBZilxpaQmIpyOAil2CcoRMwHwYDVR0jBBgwFoAU\n\
u5LeBBZilxpaQmIpyOAil2CcoRMwDwYDVR0TAQH/BAUwAwEB/zAlBgNVHREEHjAc\n\
gg9ndy5leGFtcGxlLnRlc3SCCWxvY2FsaG9zdDANBgkqhkiG9w0BAQsFAAOCAQEA\n\
ftzmc2G5NLcEIskDfMxim8G6+nPDoCQ7nKz0BPdUjxVv/YhdMZEcCBDl1R2FiH8K\n\
NIidJhrFxgUXHThuKV/tyhpBIMkYRV+2DJ1NdbMXEJyDKDOSlNqIhFCOV7Pu0JyC\n\
ZDqFZoyo53F7E2wONySisAb0k3zI+jWjf4jzc/b+kJqip33EaIauuwMY80AYrNbg\n\
ui3CO8QZoW9/hnQYFF2ux9y2xGjt54IBK9f34otLEV3WmNw/XoL388GnUdUKHV0W\n\
u9jyh5qSgYj7wgb7hY2unoOJeKHxq9mAUiZwhogPtbuMMLw7mOx9PvUghZKg3Y6u\n\
hHMwdrNwVjGziWTG80IWoA==\n\
-----END CERTIFICATE-----\n";

    /// 同一个域名，但 notBefore/notAfter = 2020-01/2020-02（早已过期）。
    const EXPIRED_CERT: &str = "-----BEGIN CERTIFICATE-----\n\
MIIDMTCCAhmgAwIBAgIUb1YRbrexItrAUTJSp1nkw2NxxxMwDQYJKoZIhvcNAQEL\n\
BQAwGjEYMBYGA1UEAwwPZ3cuZXhhbXBsZS50ZXN0MB4XDTIwMDEwMTAwMDAwMFoX\n\
DTIwMDIwMTAwMDAwMFowGjEYMBYGA1UEAwwPZ3cuZXhhbXBsZS50ZXN0MIIBIjAN\n\
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzEfGMisM9Mzc2Ru3EALIFU5nn1hp\n\
xw3beuRzXKEsAVFjj65LC2Yxkr48OxBeQIoiPO4TA3kvYtkPUhpQ03aAfr1sCyry\n\
hcY6ptfjIEp6tpCCoI5ff+HxYCUq7Hx7MiiQNypZt2cUf4X7xi6IrKn5aA5yuXRm\n\
CAcip2d8W1wwzfC6v+3CGkGIyY7j6CpsQaIElD0bBGriXsYwkXgSxav9W6xNzUb+\n\
/yVmEP6uxq6HqNwkAiEuW/vXGV4rbOub+WfLEaa/gdVxsFSWOVomoK5NHYt1/Vgw\n\
pkicp1CfNd7eqUuYZvkAXsPBoTEEeDf+PiWmd+yIr4lKAu6ubisMetwpVwIDAQAB\n\
o28wbTAdBgNVHQ4EFgQUXHmeVSdonPyxOVBdPoMVTpGBFsEwHwYDVR0jBBgwFoAU\n\
XHmeVSdonPyxOVBdPoMVTpGBFsEwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzAR\n\
gg9ndy5leGFtcGxlLnRlc3QwDQYJKoZIhvcNAQELBQADggEBAMcl4TnCwGroH9y0\n\
YsOAAYhd50MxeIK9GBZOLeYlkvGtmxi6pxQMNm8oWOd7yAFT0mclvgrVcwvU3fKh\n\
Ok+MTnn7iRbumD9AvudqFBzTgC6OgYKT2WJnBYJoEEasx2NfBVjkFjCAN5GH22MG\n\
qZEA78xmO6ZL1NE5GNIGy4VbPsiqnvOnVPqD64CLh53i9OjUy+yh/q7zw6LQBCWX\n\
2RGdRHcfZ1VQjS37FTeMCmkrdmPMaKubwyrZ2Bnv27MvdpXEt0l4XGtkwYteC6LM\n\
I2roBhIIiZ+J2lC/W8RybKGuQr1Rups3hQPmwGU1CcGM0LS9NCoXzDpgj+vYDAR7\n\
jx0fk6s=\n\
-----END CERTIFICATE-----\n";

    fn tls_tree(tag: &str, cert: &str) -> Tree {
        let tree = Tree::new(tag);
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_DOMAIN\n  value: gw.example.test\n",
        );
        tree.write(
            "configs/gateway/wist-gateway.toml",
            "[server]\ntls_cert_file = \"identity/public/admin-tls.crt.pem\"\n",
        );
        tree.write("identity/gateway/public/admin-tls.crt.pem", cert);
        tree
    }

    #[test]
    fn effective_vars_handles_comments_quotes_and_blank_lines() {
        let tree = Tree::new("env-parsing");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            "# 注释\n\nPACKAGE_DIR='./packages'\nGWLINKD_AGENT_PACKAGE_CONTAINER_DIR=\"/packages\"\n",
        );
        tree.write("sys/docker-compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            &format!(
                "agent_package_drop_dir = \"{}/packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
                tree.root.display()
            ),
        );

        let findings = package_dir_consistency(&tree.stack());
        assert!(
            findings.iter().all(|finding| finding.status == Status::Ok),
            "{findings:#?}"
        );
    }

    #[test]
    fn merged_vars_unquotes_single_quoted_values() {
        let tree = Tree::new("vars-quoted");
        tree.write(
            "sys/merged_vars.yml",
            "- name: PACKAGE_DIR\n  value: './packages'\n- name: GWLINKD_AGENT_PACKAGE_CONTAINER_DIR\n  value: '/packages'\n",
        );
        tree.write("sys/docker-compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            &format!(
                "agent_package_drop_dir = \"{}/packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
                tree.root.display()
            ),
        );

        let findings = package_dir_consistency(&tree.stack());
        assert!(
            findings.iter().all(|finding| finding.status == Status::Ok),
            "{findings:#?}"
        );
    }

    #[test]
    fn finds_compose_under_an_alternative_file_name() {
        let tree = Tree::new("compose-alt");
        tree.write("sys/merged_vars.yml", VARS);
        // gops 自己认多种文件名；写死 docker-compose.yml 会把正常部署报成「找不到挂载」。
        tree.write("sys/compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            &format!(
                "agent_package_drop_dir = \"{}/packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
                tree.root.display()
            ),
        );

        let findings = package_dir_consistency(&tree.stack());
        let mount = findings
            .iter()
            .find(|finding| finding.code == "package.compose_mount")
            .expect("应有挂载检查");
        assert_eq!(mount.status, Status::Ok, "{mount:#?}");
    }

    #[test]
    fn reads_the_long_syntax_mount() {
        let tree = Tree::new("compose-long");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "sys/docker-compose.yml",
            "services:\n  gateway:\n    volumes:\n      - type: bind\n        source: ${PACKAGE_DIR}\n        target: /packages\n        read_only: true\n",
        );
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            &format!(
                "agent_package_drop_dir = \"{}/packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
                tree.root.display()
            ),
        );

        let findings = package_dir_consistency(&tree.stack());
        let mount = findings
            .iter()
            .find(|finding| finding.code == "package.compose_mount")
            .expect("应有挂载检查");
        assert_eq!(mount.status, Status::Ok, "{mount:#?}");
    }

    #[test]
    fn signature_is_not_required_when_signing_is_off() {
        let tree = Tree::new("pairing-off");
        tree.write("packages/wist-knowledge-0.4.0.tar.gz", "dummy");

        let findings = package_pairing(&tree.stack());
        let finding = findings
            .iter()
            .find(|finding| finding.code == "package.knowledge_signature")
            .expect("应有配对检查");
        assert_eq!(finding.status, Status::Ok, "{finding:#?}");
    }

    #[test]
    fn initial_layout_tolerates_a_missing_manifest() {
        let tree = Tree::new("layout-no-manifest");
        for name in [
            "catalog.toml",
            "packs.toml",
            "templates.toml",
            "purpose-rules.toml",
            "aspect-policies.toml",
        ] {
            tree.write(&format!("configs/gateway/knowledge/initial/{name}"), "");
        }

        let findings = initial_knowledge_layout(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
        assert!(findings[0].detail.contains("未知"), "{findings:#?}");
    }

    #[test]
    fn freshness_says_nothing_when_neither_side_exists() {
        let tree = Tree::new("freshness-empty");
        assert!(render_freshness(&tree.stack()).is_empty());
    }

    #[test]
    fn effective_values_in_env_win_over_the_default_vars_file() {
        let tree = Tree::new("effective-vars");
        // `sys/merged_vars.yml` 是**默认值**；站点把 PACKAGE_DIR 覆盖成别的目录完全合法。
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            "PACKAGE_DIR=/data/packages\nGWLINKD_AGENT_PACKAGE_CONTAINER_DIR=/packages\n",
        );
        tree.write("sys/docker-compose.yml", COMPOSE);
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "agent_package_drop_dir = \"/data/packages/agents\"\nagent_package_container_dir = \"/packages/agents\"\n",
        );

        let findings = package_dir_consistency(&tree.stack());
        assert!(
            findings.iter().all(|finding| finding.status == Status::Ok),
            "拿默认值比对会误拦升级：{findings:#?}"
        );
    }

    #[test]
    fn tls_domain_comes_from_the_effective_values_too() {
        let tree = tls_tree("tls-env", GOOD_CERT);
        // 现场覆盖：默认值里没有 / 不是这个域名，`.env` 里才是真的。
        tree.write("sys/merged_vars.yml", "- name: WEB_DOMAIN\n  value: default.example.test\n");
        tree.write(".env", "WEB_DOMAIN=gw.example.test\n");

        let findings = tls_certificate(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn accepts_a_certificate_covering_the_domain() {
        let tree = tls_tree("tls-ok", GOOD_CERT);
        let findings = tls_certificate(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn accepts_a_container_absolute_certificate_path() {
        let tree = Tree::new("tls-config-path");
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_DOMAIN\n  value: gw.example.test\n",
        );
        // 站点也可以直接写容器内路径；`/config/identity` 挂的就是宿主 identity/gateway。
        tree.write(
            "configs/gateway/wist-gateway.toml",
            "[server]\ntls_cert_file = \"/config/identity/public/admin-tls.crt.pem\"\n",
        );
        tree.write("identity/gateway/public/admin-tls.crt.pem", GOOD_CERT);

        let findings = tls_certificate(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn rejects_a_certificate_that_does_not_cover_the_domain() {
        let tree = tls_tree("tls-mismatch", GOOD_CERT);
        // 子串匹配会放过它（`gw.example.test` 是它的前缀）；精确匹配不能。
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_DOMAIN\n  value: gw.example.test.evil\n",
        );
        let findings = tls_certificate(&tree.stack());
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].title.contains("不覆盖"), "{findings:#?}");
    }

    #[test]
    fn rejects_an_expired_certificate() {
        let tree = tls_tree("tls-expired", EXPIRED_CERT);
        let findings = tls_certificate(&tree.stack());
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].title.contains("有效期"), "{findings:#?}");
    }

    #[test]
    fn san_matching_is_exact_or_one_label_wildcard() {
        assert!(san_covers("gw.example.test", "gw.example.test"));
        assert!(san_covers("GW.Example.Test", "gw.example.test"));
        assert!(san_covers("*.example.test", "gw.example.test"));
        // 通配只覆盖一层。
        assert!(!san_covers("*.example.test", "a.b.example.test"));
        // 后缀攻击：不能因为“以它结尾”就放行。
        assert!(!san_covers("gw.example.test", "gw.example.test.evil"));
        assert!(!san_covers("other.example.test", "gw.example.test"));
    }

    // ── 端口 / 镜像用例 ─────────────────────────────────────────────

    #[test]
    fn expands_compose_variables_with_defaults() {
        let mut vars = BTreeMap::new();
        vars.insert("GATEWAY_PORT".to_string(), "443".to_string());
        vars.insert("EMPTY".to_string(), String::new());

        assert_eq!(expand("${GATEWAY_PORT}", &vars), "443");
        assert_eq!(expand("x${MISSING:-3000}y", &vars), "x3000y");
        // 空值当作未设，用缺省值（与 compose 一致）。
        assert_eq!(expand("${EMPTY:-9000}", &vars), "9000");
        assert_eq!(expand("no vars", &vars), "no vars");
    }

    #[test]
    fn reads_ports_from_every_service_block() {
        // 每个 service 各有一份 `ports:`，只取第一个就会漏掉后面的（实测：只查了 VM 一个）。
        let compose = "services:\n  a:\n    ports:\n      - \"1111:1\"\n  b:\n    ports:\n      - \"2222:2\"\n      - \"3333:3/udp\"\n";
        let ports = compose_ports(compose, &BTreeMap::new());
        assert_eq!(
            ports.iter().map(|port| port.host_port).collect::<Vec<_>>(),
            vec![1111, 2222, 3333]
        );
    }

    #[test]
    fn project_name_ignores_indented_volume_names() {
        let compose = "services:\n  a:\n    image: x\nvolumes:\n  run:\n    name: wist-gateway-stack-wparse-run\n";
        assert_eq!(
            compose_project_name(&Stack::new("/tmp/my-stack"), compose),
            "my-stack"
        );

        let named = "name: explicit-project\nservices: {}\n";
        assert_eq!(
            compose_project_name(&Stack::new("/tmp/my-stack"), named),
            "explicit-project"
        );
    }

    #[test]
    fn reads_published_ports_from_compose() {
        let mut vars = BTreeMap::new();
        vars.insert("GATEWAY_PORT".to_string(), "443".to_string());
        vars.insert("VM_PORT".to_string(), "18429".to_string());
        let compose = "services:\n  g:\n    ports:\n      - \"${GATEWAY_PORT}:3000\"\n      - \"127.0.0.1:${VM_PORT}:8428\"\n      - \"9000:9000/udp\"\n";

        assert_eq!(
            compose_ports(compose, &vars),
            vec![
                PublishedPort {
                    host_port: 443,
                    protocol: "tcp".into()
                },
                PublishedPort {
                    host_port: 18429,
                    protocol: "tcp".into()
                },
                PublishedPort {
                    host_port: 9000,
                    protocol: "udp".into()
                },
            ]
        );
    }

    #[test]
    fn reads_long_syntax_ports() {
        let compose = "services:\n  g:\n    ports:\n      - target: 3000\n        published: 8443\n        protocol: tcp\n";
        assert_eq!(
            compose_ports(compose, &BTreeMap::new()),
            vec![PublishedPort {
                host_port: 8443,
                protocol: "tcp".into()
            }]
        );
    }

    #[test]
    fn reads_images_and_ignores_comments() {
        let mut vars = BTreeMap::new();
        vars.insert("WIST_SPC".to_string(), "ghcr.io/dayu-sec".to_string());
        vars.insert("GATEWAY_TAG".to_string(), "v0.19.0-alpha".to_string());
        let compose = "# image: ignored/comment:1\n    image: ${WIST_SPC}/wist-gateway:${GATEWAY_TAG}\n";

        assert_eq!(
            compose_images(compose, &vars),
            vec!["ghcr.io/dayu-sec/wist-gateway:v0.19.0-alpha".to_string()]
        );
    }

    #[test]
    fn parses_published_ports_from_docker_ps() {
        let text = "0.0.0.0:443->3000/tcp, [::]:443->3000/tcp, 127.0.0.1:18429->8428/tcp";
        let ports = published_ports_from_ps(text);
        assert!(ports.contains(&443));
        assert!(ports.contains(&18429));
        assert_eq!(ports.len(), 2);
    }

    #[test]
    fn flags_a_port_taken_by_another_process() {
        // 拿一个真实空端口，自己占住它（用通配地址，与 compose 发布方式一致）。
        let listener = std::net::TcpListener::bind(("0.0.0.0", 0)).expect("bind ephemeral");
        let port = listener.local_addr().unwrap().port();

        let tree = Tree::new("port-conflict");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "sys/docker-compose.yml",
            &format!("services:\n  gateway:\n    ports:\n      - \"{port}:3000\"\n"),
        );

        let findings = ports_available_with(&tree.stack(), Some(&std::collections::HashSet::new()));
        let finding = findings
            .iter()
            .find(|finding| finding.code == "port.available")
            .expect("应有端口检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.detail.contains(&port.to_string()), "{finding:#?}");

        // 这个端口是本栈自己发布的（栈在跑）：不该报。
        let mut ours = std::collections::HashSet::new();
        ours.insert(port);
        let findings = ports_available_with(&tree.stack(), Some(&ours));
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn image_check_collapses_when_the_whole_site_is_offline() {
        let tree = Tree::new("images-offline");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "sys/docker-compose.yml",
            "services:\n  a:\n    image: a:1\n  b:\n    image: b:1\n",
        );

        let findings = image_reachable_with(&tree.stack(), &|_| {
            Err("dial tcp: lookup registry: no such host".to_string())
        });
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("离线"), "{findings:#?}");
    }

    #[test]
    fn image_check_reports_a_missing_tag() {
        let tree = Tree::new("images-missing");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "sys/docker-compose.yml",
            "services:\n  a:\n    image: repo/app:v9\n",
        );

        let findings = image_reachable_with(&tree.stack(), &|_| {
            Err("manifest unknown".to_string())
        });
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("取不到"), "{findings:#?}");
        assert!(!findings[0].blocking);
    }

    #[test]
    fn image_check_passes_when_all_are_reachable() {
        let tree = Tree::new("images-ok");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", "services:\n  a:\n    image: a:1\n");

        let findings = image_reachable_with(&tree.stack(), &|_| Ok(()));
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn image_check_is_skipped_when_offline_is_requested() {
        let tree = Tree::new("images-skip");
        let findings = image_reachable(&tree.stack(), true);
        assert_eq!(findings[0].status, Status::Ok);
        assert!(findings[0].title.contains("--offline"), "{findings:#?}");
    }

    #[test]
    fn scans_the_site_face_file_for_placeholders() {
        let tree = Tree::new("pub-placeholder");
        tree.write(
            "identity/gateway/public/wist-gateway-pub.toml",
            "public_base_url = \"https://gw.example.com\"\n",
        );

        let findings = render_placeholders(&tree.stack());
        let finding = &findings[0];
        assert_eq!(finding.status, Status::Fail);
        assert!(
            finding.detail.contains("wist-gateway-pub.toml"),
            "{}",
            finding.detail
        );
    }

    // ── prereq（环境前置条件）────────────────────────────────────────────────

    #[test]
    fn which_requires_an_executable_in_one_of_the_path_dirs() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("which");
        let bin = tree.root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let path = Some(bin.as_os_str());

        // 不存在
        assert!(which("openssl", path).is_none());

        // 存在但不可执行（多发生在拷贝 / 解包丢了权限位）
        let plain = bin.join("openssl");
        fs::write(&plain, "").unwrap();
        fs::set_permissions(&plain, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(which("openssl", path).is_none());

        // 可执行
        fs::set_permissions(&plain, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(which("openssl", path), Some(plain));

        // 空 PATH（`set -u` 筛掉空段）不能“碰运气命中当前目录”
        assert!(which("openssl", Some(OsStr::new(""))).is_none());
    }

    #[test]
    fn missing_commands_reports_hash_tool_as_one_item() {
        let tree = Tree::new("missing-cmds");
        let bin = tree.root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let path = Some(bin.as_os_str());

        let missing = missing_commands(path);
        assert!(missing.contains(&"openssl".to_string()));
        assert!(missing.contains(&"python3".to_string()));
        assert!(missing.contains(&"sha256sum|shasum".to_string()));

        // 有一条 sha256 工具就不再报那个合成项
        let shasum = bin.join("shasum");
        fs::write(&shasum, "").unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&shasum, fs::Permissions::from_mode(0o755)).unwrap();
        let missing = missing_commands(path);
        assert!(!missing.contains(&"sha256sum|shasum".to_string()));
        assert!(missing.contains(&"openssl".to_string()));
    }

    #[test]
    fn toolchain_finding_blocks_on_current_path_but_only_warns_on_daemon_path() {
        let missing = vec!["openssl".to_string()];

        // 当前 PATH 就缺 → 阻断（后面必然失败）
        let blocked = toolchain_finding("prereq.toolchain", &missing, &missing);
        assert_eq!(blocked.status, Status::Fail);
        assert!(blocked.blocking);
        assert!(blocked.detail.contains("openssl"), "{}", blocked.detail);

        // 只在守护进程的 PATH 下缺 → 只 WARN（开发机不该被拦住）
        let warned = toolchain_finding("prereq.toolchain", &[], &missing);
        assert_eq!(warned.status, Status::Warn);
        assert!(!warned.blocking);
        assert!(warned.hint.contains("gwlinkd"), "{}", warned.hint);

        // 两套 PATH 都齐全 → OK
        let fine = toolchain_finding("prereq.toolchain", &[], &[]);
        assert_eq!(fine.status, Status::Ok);
    }

    #[test]
    fn san_finding_maps_the_real_world_outcomes() {
        let cert = Path::new("/tmp/leaf.pem");
        let names = SanProbe::Read("gw.example.test\nlocalhost".to_string());
        // 老实现在 LibreSSL 下的形状：**退出码 0、输出为空**（管道退出码来自 sed）
        let empty = SanProbe::Read(String::new());
        let boom = SanProbe::Failed("helper 退出码 1".to_string());

        // 还没有证书：跳过（首次部署），不报错
        let none = san_finding("prereq.tls_san_reader", None, &SanProbe::NoCert, &SanProbe::NoCert);
        assert_eq!(none.status, Status::Ok);
        assert!(none.title.contains("还没有"), "{}", none.title);

        // 当前 PATH 读不出 = 后面 localize 必然炸 → 阻断，且 detail 点明用的是哪份 openssl
        let blocked = san_finding("prereq.tls_san_reader", Some(cert), &boom, &boom);
        assert_eq!(blocked.status, Status::Fail);
        assert!(blocked.blocking);
        assert!(blocked.detail.contains("openssl"), "{}", blocked.detail);

        // 交互式能读、守护进程的 PATH 读不了 → 只 WARN（开发机不该被拦住）
        let warned = san_finding("prereq.tls_san_reader", Some(cert), &names, &boom);
        assert_eq!(warned.status, Status::Warn);
        assert!(!warned.blocking);
        assert!(warned.title.contains("守护进程"), "{}", warned.title);

        // **静默读空**也必须算「守护进程不行」——2026-10-23 事故就是这个形状，
        // 只看退出码会把它判成 OK。
        let silent = san_finding("prereq.tls_san_reader", Some(cert), &names, &empty);
        assert_eq!(silent.status, Status::Warn);
        assert!(!silent.blocking);
        assert!(silent.detail.contains("静默读空"), "{}", silent.detail);

        // 两套 PATH 都读空 → WARN（证书可能真没 DNS SAN；localize 会重签）
        let blank = san_finding("prereq.tls_san_reader", Some(cert), &empty, &empty);
        assert_eq!(blank.status, Status::Warn);
        assert!(!blank.blocking);

        // 读得出 → OK，detail 列出 SAN
        let fine = san_finding("prereq.tls_san_reader", Some(cert), &names, &names);
        assert_eq!(fine.status, Status::Ok);
        assert!(fine.detail.contains("localhost"), "{}", fine.detail);

        // 没证书但随包 helper 缺失（包不完整）仍然要拦
        let broken = san_finding(
            "prereq.tls_san_reader",
            None,
            &SanProbe::Failed("缺少 scripts/lib/tls-san.sh".to_string()),
            &SanProbe::NoCert,
        );
        assert_eq!(broken.status, Status::Fail);
        assert!(broken.blocking);

        // helper 缺失（旧包 / 手工拷过 scripts/）与 openssl 能力不足要分开：
        // 两者的修法不同，提示不能写成“换 openssl”。
        let no_helper = san_finding(
            "prereq.tls_san_reader",
            Some(cert),
            &SanProbe::MissingHelper("缺少 scripts/lib/tls-san.sh（安装包不完整）".to_string()),
            &SanProbe::MissingHelper("缺少 scripts/lib/tls-san.sh（安装包不完整）".to_string()),
        );
        assert_eq!(no_helper.status, Status::Fail);
        assert!(no_helper.blocking);
        assert!(
            no_helper.hint.contains("重新解包"),
            "helper 缺失的提示应是“重新解包”，实际：{}",
            no_helper.hint
        );
        assert!(
            !no_helper.hint.contains("openssl"),
            "helper 缺失不该建议换 openssl：{}",
            no_helper.hint
        );
    }
}
