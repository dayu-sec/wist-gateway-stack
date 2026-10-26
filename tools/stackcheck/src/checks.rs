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

// 通用引擎（变量 / compose / 端口 / 镜像 / x509）来自共享 crate；本文件只保留
// gateway 专属判据（package / knowledge / identity / prereq / TLS 策略）。
pub use wist_stackcheck_core::checks::*;
pub use wist_stackcheck_core::x509::*;

// ── 通用工具（来自 wist-stackcheck-core）─────────────────────────────────────

/// 文档根上的字符串值。
fn root_str(doc: &toml::Value, key: &str) -> Option<String> {
    doc.as_table()?.get(key)?.as_str().map(str::to_string)
}

/// 文档根上的原始值（用于判「是不是字符串」）。
fn root_value<'a>(doc: &'a toml::Value, key: &str) -> Option<&'a toml::Value> {
    doc.as_table()?.get(key)
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

/// `prereq.container_gid`：部署账号是否已在 compose 里**有 bind 挂载的非 root 服务**的 gid 组里。
///
/// 为什么算前置：`gops sys perms --apply` 以部署账号身份只做 `chmod`/`chgrp`，而内核判定
/// `chgrp` 用的是「进程凭据里有没有这个 gid」（按**数字**比对，与 `/etc/group` 里有没有名字无关）。
/// 缺这一步时 localize 最后一步会整片 `Operation not permitted`（`0 项待修 / N 项失败`），
/// 而修复要 root（`usermod -aG`）、gops 明确不提权 —— 所以只能在这里一次性拦下。
///
/// 判据只看**有 bind 挂载**的服务：只用 named volume 的服务不需要宿主属组对齐。
pub fn prereq_container_gid(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "prereq.container_gid";

    if !cfg!(target_os = "linux") {
        return vec![Finding::ok(
            CODE,
            "非 Linux，跳过容器组检查",
            "`gops sys perms` 只在 Linux 生效（macOS 上 bind 挂载不参与对齐）",
        )];
    }
    let Some(compose_path) = compose_file(stack) else {
        return Vec::new(); // 缺 compose 已由 layout.mounts 判
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return vec![Finding::warn(
            CODE,
            "读不到 compose，跳过容器组检查",
            compose_path.display().to_string(),
        )];
    };
    let (required, unnamed) = compose_container_gids(&compose);
    if required.is_empty() && unnamed.is_empty() {
        return vec![Finding::ok(CODE, "没有需要宿主属组对齐的非 root 服务", "")];
    }
    let Some(identity) = process_identity() else {
        return vec![
            Finding::warn(
                CODE,
                "读不到进程身份，跳过容器组检查",
                "/proc/self/status 不可读",
            )
            .with_hint("手工确认：`id -G` 输出里应包含 compose 里服务 `user:` 的 gid"),
        ];
    };
    container_gid_findings(CODE, &required, &unnamed, &identity)
}

/// 纯函数：给定「需要哪些 gid」与「当前进程的组」，产出判据（单测直接喂结果）。
fn container_gid_findings(
    code: &str,
    required: &BTreeMap<u32, Vec<String>>,
    unnamed: &[String],
    identity: &ProcessIdentity,
) -> Vec<Finding> {
    let mut out = Vec::new();

    // root 能 chgrp 到任意 gid，不存在「成员缺失」。
    if identity.uid == 0 {
        out.push(Finding::ok(
            code,
            "以 root 运行，跳过容器组检查",
            "root 可 chgrp 到任意 gid（但 gops 的常规姿态是部署账号零 sudo）",
        ));
    } else {
        let missing: Vec<(u32, &Vec<String>)> = required
            .iter()
            .filter(|(gid, _)| !identity.groups.contains(gid))
            .map(|(gid, services)| (*gid, services))
            .collect();
        let groups = identity
            .groups
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join("、");
        if missing.is_empty() {
            let have = required
                .iter()
                .map(|(gid, services)| format!("{gid}（{}）", services.join("、")))
                .collect::<Vec<_>>()
                .join("；");
            out.push(Finding::ok(
                code,
                "部署账号已在容器 gid 组里",
                format!("{have}；当前进程的组：{groups}"),
            ));
        } else {
            let detail = missing
                .iter()
                .map(|(gid, services)| format!("{gid}（{}）", services.join("、")))
                .collect::<Vec<_>>()
                .join("；");
            let gids = missing
                .iter()
                .map(|(gid, _)| gid.to_string())
                .collect::<Vec<_>>()
                .join(",");
            out.push(
                Finding::fail(
                    code,
                    "部署账号不在容器 gid 组里，`gops sys perms --apply` 会整片失败",
                    format!("缺：{detail}；当前进程的组：{groups}"),
                )
                .with_hint(format!(
                    "管理员执行 `sudo groupadd -g <gid> <组名>`（该 gid 尚无组时）与 \
                     `sudo usermod -aG {gids} <部署账号>`；**重新登录**（systemd 服务需重启单元）\
                     后才生效，然后再跑 `gops sys localize`"
                )),
            );
        }
    }

    // `user:` 是用户名时无法推导 gid：不阻断，但要说清楚为什么没法判。
    if !unnamed.is_empty() {
        out.push(
            Finding::warn(
                code,
                "有服务用非数字 `user:`，无法推导宿主属组",
                unnamed.join("；"),
            )
            .with_hint(
                "写成 `user: \"<uid>:<gid>\"`，或在 `sys-prj.yml: perms.services.<name>` \
                 声明 uid/gid（gops 会按它对齐）",
            ),
        );
    }
    out
}

/// 当前进程的身份（euid + 全部组）。直接读 `/proc/self/status`：
/// 不 spawn 子进程、也不受 `id` 的参数语义影响。
#[derive(Debug)]
struct ProcessIdentity {
    uid: u32,
    groups: Vec<u32>,
}

fn process_identity() -> Option<ProcessIdentity> {
    parse_process_identity(&fs::read_to_string("/proc/self/status").ok()?)
}

fn parse_process_identity(status: &str) -> Option<ProcessIdentity> {
    let mut uid = None;
    let mut egid = None;
    let mut groups = Vec::new();
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            uid = rest.split_whitespace().nth(1)?.parse().ok();
        } else if let Some(rest) = line.strip_prefix("Gid:") {
            egid = rest.split_whitespace().nth(1)?.parse().ok();
        } else if let Some(rest) = line.strip_prefix("Groups:") {
            groups = rest
                .split_whitespace()
                .filter_map(|g| g.parse().ok())
                .collect();
        }
    }
    let uid = uid?;
    // `Groups:` 只有补充组，主组要单独加（linux 的 getgroups 也不含 egid）。
    if let Some(gid) = egid {
        groups.push(gid);
    }
    groups.sort_unstable();
    groups.dedup();
    Some(ProcessIdentity { uid, groups })
}

/// 从 compose 文本里取「有 bind 挂载的非 root 服务」的 gid。
/// 返回（gid → 服务名，无法推导 gid 的服务描述）。
fn compose_container_gids(compose: &str) -> (BTreeMap<u32, Vec<String>>, Vec<String>) {
    let mut required: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    let mut unnamed = Vec::new();

    for (service, body) in compose_services(compose) {
        if !body_has_bind(&body) {
            continue;
        }
        let Some(user) = body_user(&body) else {
            continue; // 没有 `user:` = root（Docker 语义），root 跳过
        };
        match parse_user_gid(&user) {
            Some(0) => {}
            Some(gid) => required.entry(gid).or_default().push(service),
            None => unnamed.push(format!("{service}（user: {user}）")),
        }
    }
    (required, unnamed)
}

/// 切出 `services:` 下每个服务名及其块内行。
fn compose_services<'a>(compose: &'a str) -> Vec<(String, Vec<&'a str>)> {
    let mut out: Vec<(String, Vec<&'a str>)> = Vec::new();
    let mut in_services = false;
    let mut services_indent = 0usize;
    let mut service_indent: Option<usize> = None;

    for line in compose.lines() {
        let trimmed = line.trim();
        let indent = line.len() - line.trim_start().len();
        if !in_services {
            if trimmed == "services:" {
                in_services = true;
                services_indent = indent;
            }
            continue;
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if indent <= services_indent {
            break; // 离开 services 块
        }
        match service_indent {
            None => {
                if trimmed.ends_with(':') {
                    service_indent = Some(indent);
                    out.push((trimmed.trim_end_matches(':').to_string(), Vec::new()));
                }
            }
            Some(base) if indent == base => {
                if trimmed.ends_with(':') {
                    out.push((trimmed.trim_end_matches(':').to_string(), Vec::new()));
                }
            }
            Some(base) if indent > base => {
                if let Some(last) = out.last_mut() {
                    last.1.push(line);
                }
            }
            Some(_) => {}
        }
    }
    out
}

/// 服务块里的 `user:`（去引号；空值视为未声明）。
fn body_user(lines: &[&str]) -> Option<String> {
    lines.iter().find_map(|line| {
        let rest = line.trim().strip_prefix("user:")?;
        let value = rest.trim().trim_matches('"').trim_matches('\'').trim();
        (!value.is_empty()).then(|| value.to_string())
    })
}

/// `user: "<uid>:<gid>"` → `Some(gid)`；名字、只有 uid、值非法 → `None`。
fn parse_user_gid(user: &str) -> Option<u32> {
    let (uid, gid) = user.split_once(':')?;
    uid.trim().parse::<u32>().ok()?;
    gid.trim().parse::<u32>().ok()
}

/// 服务块里是否有 bind 挂载（命名卷不算：它不参与宿主属主对齐）。
fn body_has_bind(lines: &[&str]) -> bool {
    let mut in_volumes = false;
    let mut volumes_indent = 0usize;
    for line in lines {
        let trimmed = line.trim();
        let indent = line.len() - line.trim_start().len();
        if let Some(rest) = trimmed.strip_prefix("volumes:") {
            let rest = rest.trim();
            if rest.starts_with('[') {
                if inline_volumes_have_bind(rest) {
                    return true;
                }
                in_volumes = false;
            } else {
                in_volumes = true;
                volumes_indent = indent;
            }
            continue;
        }
        if !in_volumes {
            continue;
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if indent <= volumes_indent {
            in_volumes = false;
            continue;
        }
        if volume_entry_is_bind(trimmed) {
            return true;
        }
    }
    false
}

fn inline_volumes_have_bind(rest: &str) -> bool {
    rest.trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .any(|entry| volume_entry_is_bind(entry.trim().trim_matches('"').trim_matches('\'')))
}

fn volume_entry_is_bind(entry: &str) -> bool {
    let entry = entry.trim().trim_start_matches('-').trim();
    // 长语法：`type: bind`
    if let Some(rest) = entry.strip_prefix("type:") {
        return rest.trim().trim_matches('"').trim_matches('\'') == "bind";
    }
    let entry = entry.trim_matches('"').trim_matches('\'');
    let source = entry.split(':').next().unwrap_or_default();
    // bind 的 source 是路径（相对 / 绝对 / 家目录 / 以变量给出）；命名卷是裸名字。
    source.starts_with('.')
        || source.starts_with('/')
        || source.starts_with('~')
        || source.contains('$')
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
                Finding::fail("package.vars", "读不到合并后的系统变量", err).with_hint(
                    "先跑一次 `gops sys localize`（生成 .env / sys/merged_vars.yml）再检查",
                ),
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
                        .with_hint(
                            "init-gwlinkd.sh 会把相对 PACKAGE_DIR 绝对化；别手工改回相对路径",
                        ),
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
                    format!("`{key}` 在 `{section}` 里，不在文档根 —— gwlinkd 在根读到的是 None"),
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
        Ok(compose) => match compose_mount_target(&compose, "${PACKAGE_DIR}") {
            Some(target) if trim_slash(&target) == trim_slash(container_base) => {
                out.push(Finding::ok(
                    "package.compose_mount",
                    "compose 已把投放目录挂到容器",
                    format!("${{PACKAGE_DIR}}:{target}"),
                ))
            }
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

// ── 渲染 / 占位值 / 密钥：通用实现来自 wist-stackcheck-core ────────────────

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
                format!(
                    "{} 旁边没有 .sig（导入会 422 package_signature_invalid）",
                    newest_name
                ),
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
    let mut anchor_problem: Option<(String, String)> = None;
    let mut anchor_source: Option<PathBuf> = None;

    for (label, dir) in [
        ("state_dir", root_str_of(&toml_path, "state_dir")),
        ("identity_dir", root_str_of(&toml_path, "identity_dir")),
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
            // 现场值可能是相对路径（`./identity/gwlinkd/...`）—— 必须相对**栈根**解析，
            // 不能用进程 CWD：`--root` 指到别处时就会把正常部署判成悬空。
            let path = resolve(stack, value.trim());
            anchor_source = Some(path.clone());
            match fs::metadata(&path) {
                Ok(meta) if meta.is_dir() => anchor_problem = Some((
                    value.to_string(),
                    "这个路径是**目录**，不是文件 —— 典型的「源文件缺失、docker 把 bind 建成了目录」"
                        .to_string(),
                )),
                Ok(_) => {
                    let pem = fs::read_to_string(&path)
                        .is_ok_and(|text| text.contains("BEGIN CERTIFICATE"));
                    if !pem {
                        anchor_problem = Some((
                            value.to_string(),
                            "文件里没有 `BEGIN CERTIFICATE`，不是可用的 PEM".to_string(),
                        ));
                    }
                }
                Err(_) => missing.push(format!(
                    "GWLINKD_TRUST_BUNDLE={value}（gwlinkd 会报 UnknownIssuer；wparse 会因此起不来）"
                )),
            }
        }
    }

    // (c) 信任锚（Center CA）：不只是「存在」，还得**是能读的 PEM**。
    //
    // 反例是 2026-10-23 的现场事故：`identity/gwlinkd/control-center.pem` 缺失，compose 里
    // `./identity/gwlinkd/control-center.pem:/data/identity/control-center.pem` 这条 bind 被
    // docker 建成一个**目录**；wparse 容器把这个路径当 `SSL_CERT_FILE`，建 HTTP 客户端失败
    // （`sink error / build victoriametric client failed`）——容器连重启 52 次，症状与根因隔着一个
    // 网络层。这里把「目录 / 不是 PEM」单独拎成一条，且在 localize 闸门里就报。
    if let Some((value, why)) = anchor_problem {
        out.push(
            Finding::fail(
                "identity.trust_anchor",
                "信任锚不是可用的 PEM 文件",
                format!("{value}：{why}"),
            )
            .with_hint(
                "若是空目录：`rmdir <路径>`，再跑 `gops sys localize` 让 gwlinkd 重新写入 CA；\
                     中心用公有 CA 时该文件可以不存在，但**不能是目录**",
            ),
        );
    } else {
        out.push(Finding::ok(
            "identity.trust_anchor",
            "信任锚形态正常",
            "缺失或可读 PEM 都放行（缺失时各组件回落系统根）",
        ));
    }

    // (d) 容器的**信任锚投影**（`identity/gwlinkd/trust/control-center.pem`）。
    //
    // compose 只挂这个**目录**、不挂单文件（否则 docker 会把缺失的源建成同名目录，见
    // `identity.trust_anchor` 的事故）。真身与投影分两处 ⇒ 必须有人保证它们同步：
    // 投影缺失 = 容器读不到中心 CA（私有 CA 中心拉不了规则）；投影残留 = 早就不该信那张 CA 了。
    let projection = stack.at("identity/gwlinkd/trust/control-center.pem");
    let source_text = anchor_source
        .as_deref()
        .and_then(|path| fs::read(path).ok());
    let projection_text = fs::read(&projection).ok();
    let source_is_pem = source_text
        .as_deref()
        .is_some_and(|bytes| String::from_utf8_lossy(bytes).contains("BEGIN CERTIFICATE"));
    match (&source_is_pem, &projection_text) {
        (true, Some(projected)) if source_text.as_deref() == Some(projected.as_slice()) => {
            out.push(Finding::ok(
                "identity.trust_projection",
                "容器侧信任锚投影与真身一致",
                projection
                    .strip_prefix(&stack.root)
                    .unwrap_or(&projection)
                    .display()
                    .to_string(),
            ));
        }
        (true, _) => out.push(
            Finding::warn(
                "identity.trust_projection",
                "容器侧信任锚投影缺失或过期",
                "真身有可读 PEM，但 identity/gwlinkd/trust/ 里没有同一份 —— 私有 CA 中心会拉不了规则",
            )
            .with_hint("跑一次 `gops sys localize`（init-gwlinkd-pub.sh 会把真身投影过去）"),
        ),
        (false, Some(_)) => out.push(
            Finding::warn(
                "identity.trust_projection",
                "容器侧信任锚投影是陈旧的",
                "真身已不存在或已不是 PEM，但投影里还留着一份旧 CA",
            )
            .with_hint("跑一次 `gops sys localize`（脚本会删掉陈旧投影）"),
        ),
        (false, None) => out.push(Finding::ok(
            "identity.trust_projection",
            "没有中心信任锚，容器回落系统根",
            "公网 CA 的中心、或尚未接入中心 —— 这是合法现场",
        )),
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

// ── 7. compose 挂载源的类型 ────────────────────────────────

/// bind 给容器的**文件**（`*.pem` / `*.toml` / `*.conf`）在宿主上必须是文件。
///
/// docker 对**缺失**的 bind 源不报错：它建一个同名**目录**顶上。于是
/// `identity/gwlinkd/control-center.pem` 在容器里变成目录 —— 把它当 `SSL_CERT_FILE` 用的
/// wparse 建 HTTP 客户端直接失败，容器无限重启（详见 `identity.trust_anchor` 记的那次事故）。
///
/// 判据只取一种形状：**源存在、是目录，而容器目标的末段长得像文件名**。不猜方向，
/// 也不报「文件挂到目录目标」：那种错位在 docker 里直接报错，不会静默。
pub fn bind_source_type(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "layout.bind_source_type";

    let Some(compose_path) = compose_file(stack) else {
        return vec![
            Finding::fail(
                CODE,
                "找不到 compose 文件",
                "按 gops 的候选顺序都没找到，无法校对挂载源类型",
            )
            .with_hint("确认栈目录完整（`sys/docker-compose.yml` 随制品发布）"),
        ];
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return vec![Finding::warn(
            CODE,
            "读不到 compose 文件，跳过挂载源类型检查",
            compose_path.display().to_string(),
        )];
    };

    let mut wrong = Vec::new();
    let mut checked = 0usize;
    for (service, source, target) in compose_bind_mounts(&compose) {
        if !target_looks_like_file(&target) {
            continue;
        }
        // 变量源（`${PACKAGE_DIR}`）与家目录源不在这里判：它们的落点由別处的派生值保证。
        if source.contains('$') || source.starts_with('~') {
            continue;
        }
        let source_path = resolve(stack, source.trim());
        // 源**不存在**不归本条（gops 的 mount 检查会报），这里只抓「存在但类型错」。
        if !source_path.exists() {
            continue;
        }
        checked += 1;
        if source_path.is_dir() {
            wrong.push(format!("{service}: {source} → {target}（源是目录）"));
        }
    }

    if wrong.is_empty() {
        vec![Finding::ok(
            CODE,
            "文件类挂载源都是文件",
            format!("检查 {checked} 项（变量源与缺失源不在此判）"),
        )]
    } else {
        vec![
            Finding::fail(CODE, "有文件类挂载源在宿主上是个目录", wrong.join("；")).with_hint(
                "这是「源文件缺失 + 曾经 `up` 过」留下的空目录（docker 自己建的）：\
                 删掉它（`rmdir <路径>`，空目录才能删），再把真正的文件补回去",
            ),
        ]
    }
}

/// 工作根的 `conf/wparse.toml` 是否还是改版前的模板（里面还带 `[admin_api]`）。
///
/// 为什么需要这一条：容器启动时用的是 `cp --update=none`（只补缺失、不覆盖），
/// 所以改版前起的站点会一直留着旧模板；而 wparse 0.34 起不再接受
/// `[admin_api.auth].mode`，引擎启动即 `exit 300`。现场表现是容器无限重启、
/// 日志只有一句 `load /data/conf/wparse.toml failed`，看上去像配置写坏了，
/// 实际是「模板过时」。
///
/// 判据刻意宽松：只看有没有 `[admin_api]` 段，不解析每一行 —— 旧模板的几种历史
/// 写法（含 `auth.mode`、含 TLS 段）都会命中，而新模板把整个段挪到了 `wparse.local.toml`。
pub fn wparse_conf_legacy_admin_api(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "wparse.conf_legacy_admin_api";

    let rel = "data-plane-run/work/conf/wparse.toml";
    let path = resolve(stack, rel);
    // 还没跑过容器：首次启动会从种子补齐，不在此判。
    if !path.exists() {
        return vec![Finding::ok(
            CODE,
            "工作根尚无 conf/wparse.toml",
            format!("{}（容器首次启动时由种子补齐）", path.display()),
        )];
    }
    let Ok(text) = fs::read_to_string(&path) else {
        return vec![
            Finding::warn(
                CODE,
                "读不到工作根配置，跳过检查",
                path.display().to_string(),
            )
            .with_hint("用部署账号或 sudo 重跑（该文件在容器工作根里）"),
        ];
    };

    let legacy = text.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("[admin_api]") || line.starts_with("[admin_api.")
    });
    if !legacy {
        return vec![Finding::ok(
            CODE,
            "工作根配置是新模板（无 [admin_api]）",
            path.display().to_string(),
        )];
    }

    vec![
        Finding::warn(
            CODE,
            "工作根的 conf/wparse.toml 还是旧模板（含 [admin_api]）",
            format!(
                "{}；wparse 0.34 起不再接受 [admin_api.auth].mode，引擎会以 exit 300 启动失败",
                path.display()
            ),
        )
        .with_hint(
            "先备份，再用种子覆盖：\
             `cp sys/data-plane/conf/wparse.toml <工作根>/conf/wparse.toml`；\
             管理面配置只在工作根的 `wparse.local.toml` 里维护",
        ),
    ]
}

/// 容器目标末段是否长得像文件（含 `.`，且不是 `..`/隐藏目录名）。
fn target_looks_like_file(target: &str) -> bool {
    let name = target
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("");
    name.contains('.') && name != "." && name != ".."
}

/// 从 compose 文本里取所有 bind 挂载的（服务、源、容器路径）。
///
/// 只认三种写法：短语法 `./a:/b[:ro]`、长语法 `type: bind` + `source`/`target`、
/// 以及内联数组。命名卷（`metrics_data:/storage`）跳过 —— 它们的「源」不是宿主路径。
fn compose_bind_mounts(compose: &str) -> Vec<(String, String, String)> {
    /// 长语法正在收集的一条。
    #[derive(Default)]
    struct Entry {
        kind: Option<String>,
        source: Option<String>,
        target: Option<String>,
    }

    /// 把一条长语法条目定型；不是 bind 或字段不齐就丢掉。
    fn push_entry(out: &mut Vec<(String, String, String)>, service: &str, entry: Option<Entry>) {
        let Some(entry) = entry else { return };
        if entry.kind.as_deref().is_some_and(|kind| kind != "bind") {
            return;
        }
        if let (Some(source), Some(target)) = (entry.source, entry.target) {
            out.push((service.to_string(), source, target));
        }
    }

    let mut out = Vec::new();

    for (service, body) in compose_services(compose) {
        let mut in_volumes = false;
        let mut volumes_indent = 0usize;
        let mut current: Option<Entry> = None;

        for line in &body {
            let trimmed = line.trim();
            let indent = line.len() - line.trim_start().len();

            if let Some(rest) = trimmed.strip_prefix("volumes:") {
                let rest = rest.trim();
                if rest.starts_with('[') {
                    for (source, target) in short_mounts(rest) {
                        out.push((service.clone(), source, target));
                    }
                    in_volumes = false;
                } else {
                    in_volumes = true;
                    volumes_indent = indent;
                }
                continue;
            }
            if !in_volumes {
                continue;
            }
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if indent <= volumes_indent {
                in_volumes = false;
                continue;
            }

            if let Some(rest) = trimmed.strip_prefix('-') {
                push_entry(&mut out, &service, current.take());
                let rest = rest.trim();
                if let Some(kind) = rest.strip_prefix("type:") {
                    current = Some(Entry {
                        kind: Some(unquote_str(kind).to_string()),
                        ..Entry::default()
                    });
                } else if let Some((source, target)) = short_mount(rest) {
                    out.push((service.clone(), source, target));
                }
                continue;
            }

            if let Some(entry) = current.as_mut() {
                if let Some(value) = trimmed.strip_prefix("source:") {
                    entry.source = Some(unquote_str(value).to_string());
                } else if let Some(value) = trimmed.strip_prefix("target:") {
                    entry.target = Some(unquote_str(value).to_string());
                } else if let Some(value) = trimmed.strip_prefix("type:") {
                    entry.kind = Some(unquote_str(value).to_string());
                }
            }
        }

        push_entry(&mut out, &service, current.take());
    }

    out
}

/// 内联数组 `[\"./a:/b\", \"./c:/d:ro\"]` → 短语法对。
fn short_mounts(rest: &str) -> Vec<(String, String)> {
    rest.trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .filter_map(|entry| short_mount(entry.trim()))
        .collect()
}

/// `./a:/b[:ro]` → `(./a, /b)`；命名卷 / 非法条目 → `None`。
fn short_mount(entry: &str) -> Option<(String, String)> {
    let entry = unquote_str(entry.trim());
    // 长语法字段行不是挂载条目。
    if entry.contains("type:") || entry.starts_with("source:") || entry.starts_with("target:") {
        return None;
    }
    let mut parts = entry.split(':');
    let source = parts.next()?.trim();
    let target = parts.next()?.trim();
    if !volume_entry_is_bind(entry) || source.is_empty() || target.is_empty() {
        return None;
    }
    Some((source.to_string(), target.to_string()))
}

fn unquote_str(value: &str) -> &str {
    value.trim_matches('"').trim_matches('\'').trim()
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
        return vec![
            Finding::fail(
                CODE,
                "网关叶证书不存在",
                format!("`{raw}` 在 {} 个候选位置都没找到", candidates.len()),
            )
            .with_hint("跑一次 `gops sys localize`（init-gateway.sh 会签发）"),
        ];
    };

    let Ok(bytes) = fs::read(found) else {
        return vec![Finding::fail(
            CODE,
            "网关叶证书读不了",
            found.display().to_string(),
        )];
    };
    let leaf = match wist_stackcheck_core::x509::parse_pem(&bytes) {
        Ok(leaf) => leaf,
        Err(err) => {
            return vec![Finding::fail(
                CODE,
                format!("网关叶证书：{err}"),
                found.display().to_string(),
            )];
        }
    };

    if !leaf.valid {
        return vec![
            Finding::fail(
                CODE,
                "网关叶证书不在有效期内",
                format!("notBefore={} notAfter={}", leaf.not_before, leaf.not_after),
            )
            .with_hint(
                "重新签发：删掉 identity/gateway/{public,private}/admin-tls.* 后跑 localize",
            ),
        ];
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

    let sans = wist_stackcheck_core::x509::san_summary(&leaf);
    if wist_stackcheck_core::x509::covers(&leaf, &domain) {
        return vec![Finding::ok(
            CODE,
            "叶证书 SAN 覆盖 WEB_DOMAIN",
            format!("{domain} ∈ [{sans}]"),
        )];
    }
    vec![
        Finding::fail(
            CODE,
            "叶证书 SAN 不覆盖 WEB_DOMAIN",
            format!("WEB_DOMAIN={domain}，证书 SAN=[{sans}]"),
        )
        .with_hint("跑一次 `gops sys localize`：init-gateway.sh 发现 SAN 缺域名会重签"),
    ]
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
        return vec![
            Finding::warn(
                "knowledge.initial_layout",
                "没有初始知识库目录",
                dir.display().to_string(),
            )
            .with_hint("ARTIFACT_HOME / KNOWLEDGE_PATH 为空时这是正常的；否则跑一次 localize"),
        ];
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

// ── 端口 / 镜像：通用实现来自 wist-stackcheck-core ─────────────────────────

// ── 测试 ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;
    use crate::Status;
    use crate::profile;
    use std::collections::BTreeMap;

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
        tree.write(
            "configs/gwlinkd/gwlinkd.value.json",
            "{\"state_dir\":\"/tmp\"}\n",
        );

        // 把渲染产物拨回一分钟前（值文件保持「现在」）。
        let file = File::options().write(true).open(&rendered).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();

        let findings = render_freshness(&tree.stack(), &profile::GATEWAY);
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

        let findings = render_placeholders(&tree.stack(), &profile::GATEWAY);
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
        tree.write(
            "sys/merged_vars.yml",
            "variables:\n  PACKAGE_DIR: ./packages\n",
        );
        tree.write(
            "configs/gwlinkd/gwlinkd.toml",
            "agent_package_drop_dir = \"/tmp/a\"\n",
        );

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

        let findings = render_freshness(&tree.stack(), &profile::GATEWAY);
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
        let findings = secret_perms(&tree.stack(), &profile::GATEWAY);
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
            secret_perms(&tree.stack(), &profile::GATEWAY)
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
        let findings = render_placeholders(&tree.stack(), &profile::GATEWAY);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("跳过"), "{findings:#?}");
    }

    #[test]
    fn warns_when_the_value_file_exists_but_the_render_is_missing() {
        let tree = Tree::new("missing-render");
        tree.write("configs/gwlinkd/gwlinkd.value.json", "{}\n");

        let findings = render_freshness(&tree.stack(), &profile::GATEWAY);
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
        assert!(
            finding.detail.contains("GWLINKD_TRUST_BUNDLE"),
            "{finding:#?}"
        );
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
        assert!(
            findings[0].detail.contains("templates.toml"),
            "{findings:#?}"
        );

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
        assert!(render_freshness(&tree.stack(), &profile::GATEWAY).is_empty());
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
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_DOMAIN\n  value: default.example.test\n",
        );
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
            compose_project_name(&Stack::new("/tmp/my-stack"), compose, &profile::GATEWAY),
            "my-stack"
        );

        let named = "name: explicit-project\nservices: {}\n";
        assert_eq!(
            compose_project_name(&Stack::new("/tmp/my-stack"), named, &profile::GATEWAY),
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
                    bind_ip: None,
                    protocol: "tcp".into()
                },
                PublishedPort {
                    host_port: 18429,
                    bind_ip: Some("127.0.0.1".to_string()),
                    protocol: "tcp".into()
                },
                PublishedPort {
                    host_port: 9000,
                    bind_ip: None,
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
                bind_ip: None,
                protocol: "tcp".into()
            }]
        );
    }

    #[test]
    fn reads_images_and_ignores_comments() {
        let mut vars = BTreeMap::new();
        vars.insert("WIST_SPC".to_string(), "ghcr.io/dayu-sec".to_string());
        vars.insert("GATEWAY_TAG".to_string(), "v0.19.0-alpha".to_string());
        let compose =
            "# image: ignored/comment:1\n    image: ${WIST_SPC}/wist-gateway:${GATEWAY_TAG}\n";

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

        let compose = format!("services:\n  gateway:\n    ports:\n      - \"{port}:3000\"\n");
        tree.write("sys/docker-compose.yml", &compose);
        let vars = Vars::load(&tree.stack());

        let findings = ports_available_with(
            &tree.stack(),
            &vars,
            &profile::GATEWAY,
            &compose,
            Some(&std::collections::HashSet::new()),
        );
        let finding = findings
            .iter()
            .find(|finding| finding.code == "port.available")
            .expect("应有端口检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.detail.contains(&port.to_string()), "{finding:#?}");

        // 这个端口是本栈自己发布的（栈在跑）：不该报。
        let mut ours = std::collections::HashSet::new();
        ours.insert(port);
        let findings = ports_available_with(
            &tree.stack(),
            &vars,
            &profile::GATEWAY,
            &compose,
            Some(&ours),
        );
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn image_check_collapses_when_the_whole_site_is_offline() {
        let images = vec!["a:1".to_string(), "b:1".to_string()];
        let findings = image_reachable_with(&images, &|_| {
            Err("dial tcp: lookup registry: no such host".to_string())
        });
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("离线"), "{findings:#?}");
    }

    #[test]
    fn image_check_reports_a_missing_tag() {
        let images = vec!["repo/app:v9".to_string()];
        let findings = image_reachable_with(&images, &|_| Err("manifest unknown".to_string()));
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("取不到"), "{findings:#?}");
        assert!(!findings[0].blocking);
    }

    #[test]
    fn image_check_passes_when_all_are_reachable() {
        let images = vec!["a:1".to_string()];
        let findings = image_reachable_with(&images, &|_| Ok(()));
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn image_check_is_skipped_when_offline_is_requested() {
        let tree = Tree::new("images-skip");
        let findings = image_reachable(
            &tree.stack(),
            &Vars::load(&tree.stack()),
            &profile::GATEWAY,
            true,
        );
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

        let findings = render_placeholders(&tree.stack(), &profile::GATEWAY);
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
        let none = san_finding(
            "prereq.tls_san_reader",
            None,
            &SanProbe::NoCert,
            &SanProbe::NoCert,
        );
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

    // ── prereq.container_gid ────────────────────────────────────────────────

    const GID_COMPOSE: &str = r#"
services:
  gateway:
    image: gw:1
    user: "999:999"
    volumes:
      - ${CFG}/wist-gateway.toml:/config/wist-gateway.toml:ro
      - ./.wist:/secrets:ro
  wparse:
    image: wp:1
    user: 999:999
    volumes:
      - ${RUN_WORK}:/data
      - wparse-run:/data/.run
  web:
    image: web:1
    volumes:
      - ./identity/web:/certs:ro
  metrics:
    image: vm:1
    volumes:
      - ./data:/storage
"#;

    #[test]
    fn container_gids_come_from_non_root_services_with_bind_mounts() {
        let (required, unnamed) = compose_container_gids(GID_COMPOSE);

        // web / metrics 没写 `user:` = root；wparse 只有命名卷也要算出（它还有 ${RUN_WORK}）。
        let services = required.get(&999).expect("999 是容器 gid");
        assert!(services.contains(&"gateway".to_string()), "{services:?}");
        assert!(services.contains(&"wparse".to_string()), "{services:?}");
        assert!(
            !services.contains(&"web".to_string()),
            "root 服务不参与：{services:?}"
        );
        assert!(unnamed.is_empty(), "{unnamed:?}");
    }

    #[test]
    fn named_volume_only_service_needs_no_host_group() {
        let compose = r#"
services:
  db:
    user: "999:999"
    volumes:
      - pgdata:/var/lib/postgresql/data
"#;
        let (required, unnamed) = compose_container_gids(compose);
        assert!(required.is_empty(), "命名卷不需要宿主属组：{required:?}");
        assert!(unnamed.is_empty());
    }

    #[test]
    fn long_syntax_bind_mount_is_recognized() {
        let compose = r#"
services:
  gw:
    user: "999:999"
    volumes:
      - type: bind
        source: ./configs
        target: /config
"#;
        let (required, _) = compose_container_gids(compose);
        assert_eq!(
            required.get(&999).map(Vec::as_slice),
            Some(&["gw".to_string()][..])
        );
    }

    #[test]
    fn non_numeric_user_is_reported_not_guessed() {
        let compose = r#"
services:
  gw:
    user: wist
    volumes:
      - ./configs:/config:ro
"#;
        let (required, unnamed) = compose_container_gids(compose);
        assert!(required.is_empty(), "名字推不出 gid：{required:?}");
        assert_eq!(unnamed.len(), 1);
        assert!(unnamed[0].contains("gw"), "{unnamed:?}");
    }

    #[test]
    fn process_identity_includes_primary_group() {
        let status = "Name:\tstackcheck\nUid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\nGroups:\t27 1001 999\n";
        let identity = parse_process_identity(status).expect("parse");
        assert_eq!(identity.uid, 1000);
        assert_eq!(identity.groups, vec![27, 999, 1001]);
    }

    #[test]
    fn missing_gid_is_one_blocking_finding_with_the_exact_command() {
        let mut required = BTreeMap::new();
        required.insert(999, vec!["gateway".to_string(), "wparse".to_string()]);
        let identity = ProcessIdentity {
            uid: 1000,
            groups: vec![27, 1001],
        };
        let findings = container_gid_findings("prereq.container_gid", &required, &[], &identity);
        assert_eq!(findings.len(), 1);
        let finding = &findings[0];
        assert_eq!(finding.status, Status::Fail);
        assert!(finding.blocking);
        assert!(finding.title.contains("容器 gid"), "{}", finding.title);
        assert!(finding.detail.contains("999"), "{}", finding.detail);
        assert!(finding.detail.contains("gateway"), "{}", finding.detail);
        assert!(
            finding.hint.contains("usermod -aG 999"),
            "提示要给出可直接执行的命令：{}",
            finding.hint
        );
    }

    #[test]
    fn present_gid_and_root_and_named_user_are_ok_or_warn() {
        let mut required = BTreeMap::new();
        required.insert(999, vec!["gateway".to_string()]);

        // 已在组里 → OK
        let identity = ProcessIdentity {
            uid: 1000,
            groups: vec![999, 1001],
        };
        let ok = container_gid_findings("prereq.container_gid", &required, &[], &identity);
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].status, Status::Ok);

        // root → OK（不需要补组）
        let root = ProcessIdentity {
            uid: 0,
            groups: vec![0],
        };
        let root_findings = container_gid_findings("prereq.container_gid", &required, &[], &root);
        assert_eq!(root_findings[0].status, Status::Ok);

        // 名字形式的 user: → WARN（不阻断）
        let warn = container_gid_findings(
            "prereq.container_gid",
            &required,
            &["gw（user: wist）".to_string()],
            &identity,
        );
        let warn = warn
            .iter()
            .find(|f| f.status == Status::Warn)
            .expect("应当有一条 WARN");
        assert!(!warn.blocking);
        assert!(warn.hint.contains("perms.services"), "{}", warn.hint);
    }

    // ── layout.bind_source_type ────────────────────────────────────────
    //
    // 现场事故的形状：`identity/gwlinkd/control-center.pem` 缺失，docker 把这条 bind
    // 建成了**目录**；wparse 把它当 SSL_CERT_FILE，容器无限重启。

    const COMPOSE_FILE_MOUNTS: &str = "\
services:
  wparse:
    image: wparse
    volumes:
      - ./identity/gwlinkd/control-center.pem:/data/identity/control-center.pem:ro
      - ./packages:/packages:ro
  gateway:
    image: gateway
    volumes:
      - metrics_data:/storage
";

    #[test]
    fn dir_source_onto_file_target_fails() {
        let tree = Tree::new("bind-source-dir");
        tree.write("sys/docker-compose.yml", COMPOSE_FILE_MOUNTS);
        fs::create_dir_all(tree.root.join("packages")).unwrap();
        // 缺失的源被 docker 建成了目录
        fs::create_dir_all(tree.root.join("identity/gwlinkd/control-center.pem")).unwrap();

        let findings = bind_source_type(&tree.stack());
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(findings[0].status, Status::Fail);
        assert!(
            findings[0].detail.contains("control-center.pem"),
            "{}",
            findings[0].detail
        );
        // 目录 → 目录的正常挂载不能跟着报。
        assert!(
            !findings[0].detail.contains("/packages"),
            "{}",
            findings[0].detail
        );
        assert!(findings[0].hint.contains("rmdir"), "{}", findings[0].hint);
    }

    #[test]
    fn file_source_onto_file_target_is_ok() {
        let tree = Tree::new("bind-source-file");
        tree.write("sys/docker-compose.yml", COMPOSE_FILE_MOUNTS);
        tree.write(
            "identity/gwlinkd/control-center.pem",
            "-----BEGIN CERTIFICATE-----\n",
        );
        fs::create_dir_all(tree.root.join("packages")).unwrap();

        let findings = bind_source_type(&tree.stack());
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(findings[0].status, Status::Ok);
    }

    #[test]
    fn missing_source_is_not_reported_here() {
        // 源缺失由 gops 的 mount 检查报；本检查只管「存在但类型错」。
        let tree = Tree::new("bind-source-missing");
        tree.write("sys/docker-compose.yml", COMPOSE_FILE_MOUNTS);
        fs::create_dir_all(tree.root.join("packages")).unwrap();

        let findings = bind_source_type(&tree.stack());
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn long_syntax_bind_is_checked_too() {
        let tree = Tree::new("bind-source-long");
        tree.write(
            "sys/docker-compose.yml",
            "\
services:
  wparse:
    image: wparse
    volumes:
      - type: bind
        source: ./identity/gwlinkd/control-center.pem
        target: /data/identity/control-center.pem
        read_only: true
      - metrics_data:/storage
",
        );
        fs::create_dir_all(tree.root.join("identity/gwlinkd/control-center.pem")).unwrap();

        let findings = bind_source_type(&tree.stack());
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].detail.contains("control-center.pem"));
    }

    #[test]
    fn legacy_wparse_conf_with_admin_api_is_warned() {
        // 0.34 前的模板把管理面写在 conf 里；引擎升级后会以 exit 300 启动失败。
        let tree = Tree::new("wparse-legacy-conf");
        tree.write(
            "data-plane-run/work/conf/wparse.toml",
            "version = \"1.0\"\n\n[admin_api]\nenabled = true\n\n[admin_api.auth]\nmode = \"bearer_token\"\ntoken_file = \".run/admin_api.token\"\n",
        );

        let findings = wparse_conf_legacy_admin_api(&tree.stack());
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(
            findings[0].detail.contains("exit 300"),
            "{}",
            findings[0].detail
        );
        assert!(
            findings[0].hint.contains("wparse.local.toml"),
            "{}",
            findings[0].hint
        );
    }

    #[test]
    fn new_wparse_conf_without_admin_api_is_ok() {
        let tree = Tree::new("wparse-new-conf");
        tree.write(
            "data-plane-run/work/conf/wparse.toml",
            "version = \"1.0\"\n\n[project_remote]\nenabled = true\n",
        );

        let findings = wparse_conf_legacy_admin_api(&tree.stack());
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn missing_work_root_conf_is_not_reported() {
        // 还没起过容器：首次启动由种子补齐，不应该报。
        let tree = Tree::new("wparse-no-conf");
        let findings = wparse_conf_legacy_admin_api(&tree.stack());
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn named_volumes_and_inline_arrays_are_parsed() {
        let mounts = compose_bind_mounts(
            "\
services:
  vm:
    image: vm
    volumes: [./identity:/config/identity, metrics_data:/storage]
",
        );
        assert_eq!(
            mounts,
            vec![(
                "vm".to_string(),
                "./identity".to_string(),
                "/config/identity".to_string()
            )]
        );
    }

    // ── identity.trust_anchor ──────────────────────────────────────────

    fn trust_anchor_findings(tree: &Tree) -> Vec<Finding> {
        identity_paths(&tree.stack())
    }

    #[test]
    fn trust_anchor_directory_is_a_blocking_failure() {
        let tree = Tree::new("trust-anchor-dir");
        tree.write(
            "identity/gwlinkd/.env",
            "GWLINKD_TRUST_BUNDLE=./identity/gwlinkd/control-center.pem\n",
        );
        fs::create_dir_all(tree.root.join("identity/gwlinkd/control-center.pem")).unwrap();

        let findings = trust_anchor_findings(&tree);
        let anchor = findings
            .iter()
            .find(|finding| finding.code == "identity.trust_anchor")
            .expect("应有信任锚检查");
        assert_eq!(anchor.status, Status::Fail, "{anchor:#?}");
        assert!(anchor.detail.contains("目录"), "{}", anchor.detail);
    }

    #[test]
    fn trust_anchor_garbage_file_fails_and_valid_pem_passes() {
        let tree = Tree::new("trust-anchor-pem");
        tree.write(
            "identity/gwlinkd/.env",
            "GWLINKD_TRUST_BUNDLE=./identity/gwlinkd/control-center.pem\n",
        );
        tree.write("identity/gwlinkd/control-center.pem", "not a pem\n");
        let bad = trust_anchor_findings(&tree);
        let anchor = bad
            .iter()
            .find(|finding| finding.code == "identity.trust_anchor")
            .expect("应有信任锚检查");
        assert_eq!(anchor.status, Status::Fail, "{anchor:#?}");

        tree.write(
            "identity/gwlinkd/control-center.pem",
            "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
        );
        let good = trust_anchor_findings(&tree);
        let anchor = good
            .iter()
            .find(|finding| finding.code == "identity.trust_anchor")
            .expect("应有信任锚检查");
        assert_eq!(anchor.status, Status::Ok, "{anchor:#?}");
    }

    #[test]
    fn trust_anchor_missing_is_ok_but_gwlinkd_paths_warns() {
        let tree = Tree::new("trust-anchor-missing");
        tree.write(
            "identity/gwlinkd/.env",
            "GWLINKD_TRUST_BUNDLE=./identity/gwlinkd/control-center.pem\n",
        );

        let findings = trust_anchor_findings(&tree);
        let anchor = findings
            .iter()
            .find(|finding| finding.code == "identity.trust_anchor")
            .expect("应有信任锚检查");
        assert_eq!(anchor.status, Status::Ok, "{anchor:#?}");

        let paths = findings
            .iter()
            .find(|finding| finding.code == "identity.gwlinkd_paths")
            .expect("应有路径检查");
        assert_eq!(paths.status, Status::Warn, "{paths:#?}");
        assert!(paths.detail.contains("wparse"), "{}", paths.detail);
    }

    // ── identity.trust_projection ──────────────────────────────────────
    //
    // compose 只挂 `identity/gwlinkd/trust/` 目录、不挂单文件，所以真身与投影必须同步：
    // 投影缺失 = 容器读不到中心 CA；投影残留 = 还在信一张已经撤掉的 CA。

    const PEM: &str = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";

    fn projection_status(tree: &Tree) -> Status {
        identity_paths(&tree.stack())
            .into_iter()
            .find(|finding| finding.code == "identity.trust_projection")
            .expect("应有投影检查")
            .status
    }

    fn trust_env(tree: &Tree) {
        tree.write(
            "identity/gwlinkd/.env",
            "GWLINKD_TRUST_BUNDLE=./identity/gwlinkd/control-center.pem\n",
        );
    }

    #[test]
    fn trust_projection_in_sync_is_ok() {
        let tree = Tree::new("projection-ok");
        trust_env(&tree);
        tree.write("identity/gwlinkd/control-center.pem", PEM);
        tree.write("identity/gwlinkd/trust/control-center.pem", PEM);
        assert_eq!(projection_status(&tree), Status::Ok);
    }

    #[test]
    fn trust_projection_missing_warns() {
        let tree = Tree::new("projection-missing");
        trust_env(&tree);
        tree.write("identity/gwlinkd/control-center.pem", PEM);
        assert_eq!(projection_status(&tree), Status::Warn);
    }

    #[test]
    fn trust_projection_stale_warns() {
        let tree = Tree::new("projection-stale");
        trust_env(&tree);
        // 真身没了，但容器目录里还留着一份旧 CA
        tree.write("identity/gwlinkd/trust/control-center.pem", PEM);
        assert_eq!(projection_status(&tree), Status::Warn);
    }

    #[test]
    fn trust_projection_absent_everywhere_is_ok() {
        // 公网 CA 的中心 / 尚未接入中心：两头都没有，是合法现场，不是缺陷。
        let tree = Tree::new("projection-none");
        trust_env(&tree);
        assert_eq!(projection_status(&tree), Status::Ok);
    }
}
