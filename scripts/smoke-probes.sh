# shellcheck shell=bash
# scripts/smoke.sh / dev.sh probes 的探测，跟着插件走。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 按浏览器的请求链走完 ABS 的 OIDC 登录（/auth/openid?callback=/ → 身份提供方
#       → /auth/openid/callback），落回后调 ABS 自己的 /api/me 断言认出的是用户管理员。
#       网关认的是会话 Cookie，Bearer 只给 ABS 自己；两个都要带。
# 数据：data_write 用随机名字建一个有声书库，把名字存进标记文件（放在 harness 会话 jar 旁边，两套
#       harness 的 jar 目录都可写）；data_check 读回名字、去书架里找，对不上就打印看到了什么并返回非 0。
# 同时兼容两套 harness 的变量：e2e 用 E2E_*，dev.sh probes 用 SMOKE_*。
# 清单没有 mcp：工具一项由 harness 记 N/A。

web_assert() { grep -qi '<title>audiobookshelf</title>'; } # 标准输入：SPA 首页 HTML

_probe_env() { # 输出 <jar> <网页地址> <用户名>
  local jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  local url="${E2E_WEB_URL:-${SMOKE_WEB_URL:-}}"
  local owner="${E2E_OWNER:-${SMOKE_OWNER:-owner}}"
  [[ -n "$jar" && -n "$url" ]] || { echo "探针环境不全（jar/url 为空）" >&2; return 1; }
  printf '%s\n%s\n%s\n' "$jar" "$url" "$owner"
}

BASE_PATH="/audiobookshelf" # 上游镜像的网页在 /audiobookshelf 子路径下（构建期定死在客户端 bundle 里）

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

_qparam() { # <url> <名字>：取查询参数
  python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get(sys.argv[2]) or [""])[0])' "$1" "$2"
}

identity_check() { # OIDC 链落回后用 ABS 的当前用户接口核对：主人、管理员
  local env start at me
  env="$(_probe_env)" || return 1
  {
    read -r jar
    read -r base
    read -r owner
  } <<<"$env"
  start="$(_oidc_login "$jar" "$base")" || { echo "$start"; return 1; }
  at="$(_qparam "$start" accessToken)"
  [[ -n "$at" ]] || { echo "落点没有 accessToken：$start"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "Authorization: Bearer $at" "$base$BASE_PATH/api/me")" ||
    { echo "/api/me 失败"; return 1; }
  jq -e --arg u "$owner" '.username == $u and (.type == "root" or .type == "admin")' <<<"$me" >/dev/null ||
    { echo "当前用户不是 $owner 管理员：$me"; return 1; }
}

_marker_file() { # 标记放在会话 jar 旁边（dev.sh 的 .wonton/ 和 e2e 的 work/ 都可写）
  local env jar
  env="$(_probe_env)" || return 1
  jar="$(head -1 <<<"$env")"
  printf '%s.data-marker' "$jar"
}

data_write() { # 用随机名字建一个有声书库（触发一次扫描），名字存进标记文件
  local env jar base marker name start at out
  env="$(_probe_env)" || return 1
  {
    read -r jar
    read -r base
    read -r _
  } <<<"$env"
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  name="wonton-smoke-$marker"
  start="$(_oidc_login "$jar" "$base")" || { echo "$start"; return 1; }
  at="$(_qparam "$start" accessToken)"
  [[ -n "$at" ]] || { echo "落点没有 accessToken：$start"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"folders\":[{\"fullPath\":\"/audiobooks\"}],\"mediaType\":\"book\"}" \
    "$base$BASE_PATH/api/libraries")" || { echo "建书库失败：$out"; return 1; }
  printf '%s' "$name" >"$(_marker_file)" || { echo "写标记文件失败"; return 1; }
}

data_check() { # 升级/重装后重新走 OIDC，核对书库还在
  local env jar base marker name start at out
  env="$(_probe_env)" || return 1
  {
    read -r jar
    read -r base
    read -r _
  } <<<"$env"
  local marker_file
  marker_file="$(_marker_file)"
  name="$(cat "$marker_file" 2>/dev/null)" || true
  [[ -n "$name" ]] || { echo "没有 data_write 留下的标记（$marker_file）"; return 1; }
  start="$(_oidc_login "$jar" "$base")" || { echo "$start"; return 1; }
  at="$(_qparam "$start" accessToken)"
  [[ -n "$at" ]] || { echo "落点没有 accessToken：$start"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "Authorization: Bearer $at" "$base$BASE_PATH/api/libraries")" ||
    { echo "读书库列表失败：$out"; return 1; }
  jq -e --arg n "$name" 'any(.libraries[]; .name == $n)' <<<"$out" >/dev/null ||
    { echo "书库 $name 不见了：$(head -c 200 <<<"$out")"; return 1; }
}
