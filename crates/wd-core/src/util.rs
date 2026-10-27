//! 杂项：从分享文案里抠链接、JSON 取值、文件名清理。

use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

pub const DESKTOP_UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

fn re(cell: &'static OnceLock<Regex>, pat: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pat).unwrap())
}

/// 分享文案（"7.94 复制打开抖音，看看【…】 https://v.douyin.com/abc/ …"）里找出所有链接，
/// 去掉末尾粘连的中文标点。
pub fn extract_urls(text: &str) -> Vec<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = re(&R, r#"https?://[^\s<>"'，。！？、；：（）【】《》「」]+"#);
    let mut out: Vec<String> = Vec::new();
    for m in r.find_iter(text) {
        let u = m.as_str().trim_end_matches(['.', ',', ')', ']', '!', '?', ';', ':']).to_string();
        if !out.contains(&u) {
            out.push(u);
        }
    }
    out
}

/// 按路径取 JSON 值，路径段是对象键或数组下标："a.b.0.c"
pub fn jget<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = v;
    for seg in path.split('.') {
        cur = match seg.parse::<usize>() {
            Ok(i) if cur.is_array() => cur.get(i)?,
            _ => cur.get(seg)?,
        };
    }
    if cur.is_null() { None } else { Some(cur) }
}

pub fn jstr(v: &Value, path: &str) -> Option<String> {
    jget(v, path).and_then(|x| match x {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    })
}

pub fn ju64(v: &Value, path: &str) -> Option<u64> {
    jget(v, path).and_then(|x| match x {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().map(|f| f as u64)),
        Value::String(s) => s.parse().ok(),
        _ => None,
    })
}

pub fn jarr<'a>(v: &'a Value, path: &str) -> &'a [Value] {
    jget(v, path).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

/// 字符串数组里第一个非空串
pub fn first_str(v: &Value, path: &str) -> Option<String> {
    jarr(v, path).iter().filter_map(Value::as_str).find(|s| !s.is_empty()).map(str::to_string)
}

pub fn str_list(v: &Value, path: &str) -> Vec<String> {
    jarr(v, path).iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).collect()
}

/// 递归找第一个满足条件的对象
pub fn find_object<'a>(v: &'a Value, pred: &dyn Fn(&serde_json::Map<String, Value>) -> bool) -> Option<&'a Value> {
    match v {
        Value::Object(m) => {
            if pred(m) {
                return Some(v);
            }
            m.values().find_map(|x| find_object(x, pred))
        }
        Value::Array(a) => a.iter().find_map(|x| find_object(x, pred)),
        _ => None,
    }
}

/// 页面里 `<script ...>` 的内容
pub fn script_blocks(html: &str) -> Vec<&str> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = re(&R, r"(?s)<script[^>]*>(.*?)</script>");
    r.captures_iter(html).filter_map(|c| c.get(1)).map(|m| m.as_str()).collect()
}

/// 取 `window.NAME = {...}` 赋值的 JSON（到 `</script>` 为止）。小红书会写出 `undefined`，替换成 null。
pub fn window_json(html: &str, name: &str) -> Option<Value> {
    let key = format!("window.{name}");
    for s in script_blocks(html) {
        let Some(i) = s.find(&key) else { continue };
        let rest = &s[i + key.len()..];
        let Some(eq) = rest.find('=') else { continue };
        let body = rest[eq + 1..].trim().trim_end_matches(';').trim();
        if let Ok(v) = serde_json::from_str::<Value>(body) {
            return Some(v);
        }
        let fixed = replace_undefined(body);
        if let Ok(v) = serde_json::from_str::<Value>(&fixed) {
            return Some(v);
        }
    }
    None
}

/// 把 JS 对象字面量里的裸 `undefined` 换成 `null`（不动字符串里的）
fn replace_undefined(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_str = false;
    let mut esc = false;
    let mut i = 0;
    while i < s.len() {
        let rest = &s[i..];
        let ch = rest.chars().next().unwrap();
        i += ch.len_utf8();
        if in_str {
            if esc {
                esc = false;
            } else if ch == '\\' {
                esc = true;
            } else if ch == '"' {
                in_str = false;
            }
        } else if ch == '"' {
            in_str = true;
        } else if rest.starts_with("undefined") {
            out.push_str("null");
            i += "undefined".len() - 1;
            continue;
        }
        out.push(ch);
    }
    out
}

/// 页面 `<meta property="og:xxx" content="...">`
pub fn meta_content(html: &str, prop: &str) -> Option<String> {
    let r = Regex::new(&format!(
        r#"(?i)<meta[^>]+(?:property|name)=["']{}["'][^>]*content=["']([^"']+)["']"#,
        regex::escape(prop)
    ))
    .ok()?;
    r.captures(html).map(|c| html_unescape(&c[1]))
}

pub fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 去掉文件名里各系统不允许的字符、话题标签后的多余空白，并限制长度
pub fn sanitize_filename(s: &str, max_chars: usize) -> String {
    let mut out = String::new();
    let mut last_space = false;
    for ch in s.chars() {
        let c = match ch {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => ' ',
            c if c.is_control() => ' ',
            c => c,
        };
        if c.is_whitespace() {
            if !last_space && !out.is_empty() {
                out.push(' ');
            }
            last_space = true;
        } else {
            out.push(c);
            last_space = false;
        }
    }
    let mut t: String = out.trim().trim_end_matches('.').chars().take(max_chars).collect();
    t = t.trim().to_string();
    if t.is_empty() { "untitled".into() } else { t }
}

/// 标题太长时取第一行 / 去掉 #话题
pub fn short_title(desc: &str) -> String {
    let first = desc.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    static R: OnceLock<Regex> = OnceLock::new();
    let r = re(&R, r"#[^#\s]+(\[话题\])?#?");
    let t = r.replace_all(first, "").trim().to_string();
    if t.is_empty() { first.to_string() } else { t }
}

pub fn ext_from_url(u: &str, fallback: &str) -> String {
    let path = u.split(['?', '#']).next().unwrap_or("");
    let last = path.rsplit('/').next().unwrap_or("");
    match last.rsplit_once('.') {
        Some((_, e)) if (2..=4).contains(&e.len()) && e.chars().all(|c| c.is_ascii_alphanumeric()) => {
            e.to_ascii_lowercase()
        }
        _ => fallback.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_from_share_text() {
        let t = "7.94 复制打开抖音，看看【小蘑菇的作品】新疆太好吃啦！ https://v.douyin.com/iRNBho5m/ yGi:/ 03/12 a@G.vS";
        assert_eq!(extract_urls(t), vec!["https://v.douyin.com/iRNBho5m/"]);
        let x = "看看这个 http://xhslink.com/a/AbCdEf，复制本条信息";
        assert_eq!(extract_urls(x), vec!["http://xhslink.com/a/AbCdEf"]);
    }

    #[test]
    fn undefined_replaced_outside_strings() {
        let v = window_json(
            r#"<script>window.__INITIAL_STATE__={"a":undefined,"b":"undefined","c":[1,undefined],"d":"与你有瓜\"x"}</script>"#,
            "__INITIAL_STATE__",
        )
        .unwrap();
        assert!(v["a"].is_null());
        assert_eq!(v["b"], "undefined");
        assert!(v["c"][1].is_null());
        assert_eq!(v["d"], "与你有瓜\"x");
    }

    #[test]
    fn filenames() {
        assert_eq!(sanitize_filename("a/b:c?  d ", 50), "a b c d");
        assert_eq!(short_title("新疆太好吃啦！ #美食 #新疆\n第二行"), "新疆太好吃啦！");
        assert_eq!(ext_from_url("https://x/y/a.MP4?x=1", "bin"), "mp4");
        assert_eq!(ext_from_url("https://x/y/abc", "jpg"), "jpg");
    }
}
