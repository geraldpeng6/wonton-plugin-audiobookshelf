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
# 邮箱：extra_check 走 notify 的端到端——发真实测试信，信进内部邮箱（Mailpit），核心投进收件人私聊后
#       删掉（投完才会删，见核心 smoke-mailbox 的口径）；外部地址在 SMTP 阶段被 550 拒收。
# 清单没有 mcp：工具一项由 harness 记 N/A。

web_assert() { grep -qi '<title>audiobookshelf</title>'; } # 标准输入：SPA 首页 HTML

BASE_PATH="/audiobookshelf" # 上游镜像的网页在 /audiobookshelf 子路径下（构建期定死在客户端 bundle 里）

_qparam() { # <url> <名字>：取查询参数
  python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get(sys.argv[2]) or [""])[0])' "$1" "$2"
}

# 核心会话 Cookie：数据钩子跑在套件第一次会话建立之前（升级腿在最前面），自己登录（网关只认核心会话）。
smoke_core_login() { # <jar> <插件地址>：先拿核心会话 Cookie，再走一次插件首页的登录跳转——
  # 网关的会话 Cookie 要落在插件主机上，应用的登录链和接口才认（两步都要，少一步后面全是 401）。
  local base token
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" && -n "${2:-}" ]] || { echo "没有核心地址、主人令牌或插件地址"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$token" "$base/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
}

_oidc_login() { # <jar> <网页地址>：走完 OIDC 链；最终落点 URL 里带 ABS 发的 accessToken
  local jar="$1" base="$2" start final
  smoke_core_login "$jar" "$base" || { echo "核心会话登录不了（$base）"; return 1; }
  # provision 是一次性服务，核心在应用健康后就返回"装好了"，OIDC 可能还差最后几秒；等到跳起来为止
  for _ in $(seq 1 15); do
    start="$(curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" \
      -w '%{redirect_url}' --max-time 30 "$base$BASE_PATH/auth/openid?callback=$BASE_PATH/")" ||
      { echo "进不了 /auth/openid"; return 1; }
    [[ -n "$start" ]] && break
    sleep 2
  done
  [[ -n "$start" ]] || { echo "/auth/openid 没有跳到身份提供方（等了 30 秒）"; return 1; }
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

# ---------- 内部邮箱（notify）的端到端检查 ----------

_mp_api() { # <路径>：调 Mailpit 的 HTTP API（basic core:<api-password>）。Mailpit 只挂在插件网络，
  # 宿主够不着；照核心自己 smoke-mailbox 的做法，在核心容器的网络栈里起一次性 curl 访问它。
  local core pw dd out
  core="wonton-${SMOKE_INSTANCE:?}--core"
  docker inspect "$core" >/dev/null 2>&1 || { echo "找不到核心容器 $core"; return 1; }
  # e2e 冒烟用 read_env 读实例 .env；dev.sh probes 用 probes_setting。没有就报错，不猜路径。
  if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"
  elif declare -F probes_setting >/dev/null; then dd="$(probes_setting WONTON_DATA_DIR)"
  else echo "读不到 WONTON_DATA_DIR（read_env / probes_setting 都没有）"; return 1; fi
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
  echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
  return 1
}

_mp_wait() { # <jq 参数…> [轮数=20]：轮询 Mailpit 信箱直到过滤命中。参数原样交给 jq（--arg 键 值、过滤串）；
  # 最后一个参数是纯数字时取作轮数。
  local -a args=()
  local n=20 a i out
  while (($#)); do
    a="$1"; shift
    if (($# == 0)) && [[ "$a" =~ ^[0-9]+$ ]]; then n="$a"; else args+=("$a"); fi
  done
  ((${#args[@]})) || { echo "mp_wait 没给 jq 过滤"; return 1; }
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "${args[@]}" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

_owner_email() { # 主人资料里的内部邮箱（收件人用它，不猜域名）
  local base token me
  base="${E2E_BASE:-${SMOKE_BASE:-}}"; token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" ]] || { echo "没有核心地址或主人令牌"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $token" "$base/_wonton/api/me")" ||
    { echo "读不到主人资料（/_wonton/api/me）"; return 1; }
  jq -er '.email // empty' <<<"$me" || { echo "主人资料里没有邮箱：$me"; return 1; }
}

extra_check() { # 内部邮箱端到端：真实测试信进 Mailpit、核心投进主人私聊后删掉、外部地址 550 拒收
  local to at rc
  to="$(_owner_email)" || { echo "$to"; return 1; }
  at="$(_oidc_token)" || return 1

  # 1) 真实测试信：收件人是 provision 配好的主人内部邮箱；应用报成功、信进 Mailpit
  rc="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $at" -X POST "$SMOKE_WEB_URL$BASE_PATH/api/emails/test")" ||
    { echo "测试信接口请求失败"; return 1; }
  [[ "$rc" == 200 ]] || { echo "测试信没发出去（HTTP $rc）"; return 1; }
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mp_wait --arg to "$to" --arg from 'app.audiobookshelf@plugins.wonton.internal' \
    '.messages | any(.To[].Address == $to and .From.Address == $from)' ||
    { echo "60 秒内没在内部邮箱看到收件人 $to 的测试信"; return 1; }
  echo "测试信已进内部邮箱（收件人 $to）"
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mp_wait --arg to "$to" '(.messages | map(select(.To[].Address == $to)) | length) == 0' ||
    { echo "测试信一直留在 Mailpit：核心没把它投进收件人的 Wonton 私聊（投完才会删）"; return 1; }
  echo "核心已把测试信投进 $to 的 Wonton 私聊"

  # 2) 外部地址：把测试信地址改成 example.com 再发——SMTP 阶段被核心拒收（550），应用报失败，
  #    Mailpit 里不该出现；改完把设置还原，不污染后续的身份/数据检查
  local out
  out="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $at" -H 'Content-Type: application/json' \
    -X PATCH -d '{"testAddress":"nobody-smoke@example.com"}' "$SMOKE_WEB_URL$BASE_PATH/api/emails/settings")" ||
    { echo "改测试信地址失败"; return 1; }
  [[ "$out" == 200 ]] || { echo "改测试信地址没成功（HTTP $out）"; return 1; }
  rc="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $at" -X POST "$SMOKE_WEB_URL$BASE_PATH/api/emails/test")" || rc=0
  [[ "$rc" != 200 ]] || { echo "外部地址 $to 的测试信竟然发送成功（HTTP 200），550 拒收没生效"; return 1; }
  sleep 10
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mp_wait --arg to 'nobody-smoke@example.com' \
    '.messages | any(.To[].Address == $to)' 1 &&
    { echo "外部地址的信进了 Mailpit（550 拒收没生效）"; return 1; }
  echo "外部地址 nobody-smoke@example.com 被拒收（应用 HTTP $rc，Mailpit 里没有这封信）"
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' -X PATCH -d "{\"testAddress\":\"$to\"}" \
    "$SMOKE_WEB_URL$BASE_PATH/api/emails/settings" ||
    { echo "测试信地址没改回主人邮箱，后续检查用的应用设置已污染"; return 1; }
}
