//! 五组栈级检查。每组只回答一个问题，输出 `Finding`（Flow Result v1 的 `checks[]`）。
//!
//! 判据全部来自**栈自己生成的东西**：`sys/merged_vars.yml`（变量）、`configs/*`（渲染产物）、
//! `sys/docker-compose.yml`（挂载）、`packages/`（投放区）、`identity/`（密钥）。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
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
pub fn tls_certificate(stack: &Stack) -> Vec<Finding> {
    const CODE: &str = "tls.san_covers_domain";

    let toml_path = stack.at("configs/gateway/wist-gateway.toml");
    // 真实形状是 `[server] tls_cert_file = …`；也认文档根（以后搬家不会静默失效）。
    let raw = config_str(&toml_path, Some("server"), "tls_cert_file")
        .or_else(|| config_str(&toml_path, None, "tls_cert_file"));
    let Some(raw) = raw.filter(|value| !value.trim().is_empty()) else {
        return vec![Finding::warn(
            CODE,
            "网关配置里没有 tls_cert_file",
            toml_path.display().to_string(),
        )];
    };
    let raw = raw.trim();

    let candidates = relative_candidates(stack, raw);
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

// ── 测试 ───────────────────────────────────────────────────────────────

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
}
