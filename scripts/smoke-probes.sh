# shellcheck shell=bash
# scripts/smoke.sh / dev.sh probes 的探测，跟着插件走。
# 钩子能用的东西只有：变量 SMOKE_STATE（存数据标记的文件，data_write 覆盖写、data_check 读）、SMOKE_JAR
# （主人会话 cookie）、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE，助手 web_get、dweb。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 按浏览器的请求链走完 ABS 的 OIDC 登录（/auth/openid?callback=… → 身份提供方
#       → /auth/openid/callback），落回后调 ABS 自己的 /api/me 断言认出的是主人管理员。
#       网关认的是会话 Cookie，Bearer 只给 ABS 自己；两个都要带。
# 数据：data_write 用随机名字建一个有声书库，名字写进 SMOKE_STATE；data_check 读回名字、去书架里找，
#       对不上就打印看到了什么并返回非 0。
# 清单没有 mcp：工具一项由 harness 记 N/A。

web_assert() { grep -qi '<title>audiobookshelf</title>'; } # 标准输入：SPA 首页 HTML

BASE_PATH="/audiobookshelf" # 上游镜像的网页在 /audiobookshelf 子路径下（构建期定死在客户端 bundle 里）

_qparam() { # <url> <名字>：取查询参数
  python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get(sys.argv[2]) or [""])[0])' "$1" "$2"
}

_oidc_login() { # <jar> <网页地址>：走完 OIDC 链；最终落点 URL 里带 ABS 发的 accessToken
  local jar="$1" base="$2" start final
  start="$(curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" \
    -w '%{redirect_url}' --max-time 30 "$base$BASE_PATH/auth/openid?callback=$BASE_PATH/")" ||
    { echo "进不了 /auth/openid"; return 1; }
  [[ -n "$start" ]] || { echo "/auth/openid 没有跳到身份提供方"; return 1; }
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' \
    -w '%{url_effective}' --max-time 60 "$start")" || { echo "authorize 链失败：$start"; return 1; }
  [[ "$final" == "$base"* ]] || { echo "OIDC 链没有落回插件网页：$final"; return 1; }
  printf '%s' "$final"
}

_oidc_token() { # 走完 OIDC 链，输出 accessToken；走不通时把原因打到标准错误并返回非 0
  local start at
  start="$(_oidc_login "${SMOKE_JAR:-}" "${SMOKE_WEB_URL:-}")" || { echo "$start" >&2; return 1; }
  at="$(_qparam "$start" accessToken)"
  [[ -n "$at" ]] || { echo "落点没有 accessToken：$start" >&2; return 1; }
  printf '%s' "$at"
}

identity_check() { # OIDC 链落回后用 ABS 的当前用户接口核对：主人、管理员
  local at me
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" ]] || { echo "SMOKE_JAR/SMOKE_WEB_URL 没有就绪"; return 1; }
  at="$(_oidc_token)" || return 1
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: Bearer $at" "$SMOKE_WEB_URL$BASE_PATH/api/me")" ||
    { echo "/api/me 失败"; return 1; }
  jq -e --arg u "${SMOKE_OWNER:-owner}" '.username == $u and (.type == "root" or .type == "admin")' <<<"$me" >/dev/null ||
    { echo "当前用户不是 $SMOKE_OWNER 管理员：$me"; return 1; }
}

data_write() { # 用随机名字建一个有声书库（触发一次扫描），名字写进标记文件 SMOKE_STATE
  local marker name at out
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  name="wonton-smoke-$marker"
  at="$(_oidc_token)" || return 1
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"folders\":[{\"fullPath\":\"/audiobooks\"}],\"mediaType\":\"book\"}" \
    "$SMOKE_WEB_URL$BASE_PATH/api/libraries")" || { echo "建书库失败：$out"; return 1; }
  printf '%s' "$name" >"$SMOKE_STATE" || { echo "写标记文件失败（$SMOKE_STATE）"; return 1; }
}

data_check() { # 升级/重装后重新走 OIDC，核对书库还在
  local name at out
  name="$(cat "${SMOKE_STATE:-}" 2>/dev/null)" || true
  [[ -n "$name" ]] || { echo "没有 data_write 留下的标记（SMOKE_STATE=${SMOKE_STATE:-未设置}）"; return 1; }
  at="$(_oidc_token)" || return 1
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: Bearer $at" "$SMOKE_WEB_URL$BASE_PATH/api/libraries")" ||
    { echo "读书库列表失败：$out"; return 1; }
  jq -e --arg n "$name" 'any(.libraries[]; .name == $n)' <<<"$out" >/dev/null ||
    { echo "书库 $name 不见了：$(head -c 200 <<<"$out")"; return 1; }
}
