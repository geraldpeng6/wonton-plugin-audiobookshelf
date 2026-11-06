/*
 * 一次性 provision 服务的脚本：把 Audiobookshelf 的 OIDC 指到核心的身份提供方。
 *
 * 为什么要有这个服务：ABS 的认证设置存在自己的 SQLite 里，上游没有环境变量或配置文件的入口，
 * 只能由管理员经 /api/auth-settings 修改（MiscController.updateAuthSettings）。所以：
 *   1. 空库时经 POST /init 建以注入用户名命名的 root 账号（密码是插件密钥 WONTON_SECRET_ADMIN_PASSWORD）；
 *   2. 本地登录拿 access token，PATCH /api/auth-settings 写入 OIDC 设置；
 *   3. 每次容器创建（安装、升级、重建）都重跑：核心重建 OIDC 客户端时密钥会换，这里每次覆盖写最新的，
 *      不是"已存在就跳过"。
 * 登录方式：OIDC 的"按用户名匹配已有用户"把 root 账号和核心用户连起来，主人打开网页就是管理员。
 * 任何一步失败都以非 0 退出，错误写清原因（安装会带着这段日志失败回滚）。
 */

const APP_URL = process.env.APP_URL || 'http://audiobookshelf:80'
const OWNER = required('WONTON_OWNER_NAME')
const ADMIN_PASSWORD = required('WONTON_SECRET_ADMIN_PASSWORD')
const OIDC = {
  issuer: required('WONTON_OIDC_ISSUER'),
  clientId: required('WONTON_OIDC_CLIENT_ID'),
  clientSecret: required('WONTON_OIDC_CLIENT_SECRET'),
  authUrl: required('WONTON_OIDC_AUTH_URL'),
  tokenUrl: required('WONTON_OIDC_TOKEN_URL'),
  userinfoUrl: required('WONTON_OIDC_USERINFO_URL')
}

function required(name) {
  const value = process.env[name]
  if (!value) {
    console.error(`[provision] 缺环境变量 ${name}：核心没有注入，装不了`)
    process.exit(1)
  }
  return value
}

function log(message) {
  console.log(`[provision] ${message}`)
}

async function request(method, url, { body, headers = {}, allowStatus = [] } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...headers
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15000)
  })
  if (!response.ok && !allowStatus.includes(response.status)) {
    const text = await response.text().catch(() => '')
    throw new Error(`${method} ${url} 失败：HTTP ${response.status}${text ? `，响应：${text.slice(0, 300)}` : ''}`)
  }
  return response
}

async function getJson(url, headers) {
  const response = await request('GET', url, { headers })
  return response.json()
}

async function waitUntilHealthy() {
  for (let attempt = 1; ; attempt++) {
    try {
      await request('GET', `${APP_URL}/healthcheck`)
      return
    } catch (error) {
      if (attempt >= 60) {
        throw new Error(`主服务一直没就绪（试了 ${attempt} 次）：${error.message}`)
      }
      if (attempt === 1) log(`等主服务就绪：${error.message}`)
      await new Promise((resolve) => setTimeout(resolve, 2000))
    }
  }
}

async function ensureRootUser() {
  const status = await getJson(`${APP_URL}/status`)
  if (status.isInit) {
    log('已有 root 账号，跳过建号')
    return
  }
  await request('POST', `${APP_URL}/init`, {
    body: { newRoot: { username: OWNER, password: ADMIN_PASSWORD } }
  })
  log(`空库，已建 root 账号 "${OWNER}"`)
}

async function loginAsRoot() {
  // 登录接口有速率限制（10 次/10 分钟）：只在网络错误和服务端错误上重试，401 直接失败
  let lastError = null
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const response = await request('POST', `${APP_URL}/login`, {
        body: { username: OWNER, password: ADMIN_PASSWORD },
        allowStatus: [401]
      })
      if (response.status === 401) {
        throw new Error(
          `管理员账号登录不了（401）：数据目录里已有 root 账号但密码不是本插件的密钥。` +
            `保留数据时不要在应用里改 "${OWNER}" 的密码；删掉插件数据重装可以恢复。`
        )
      }
      const payload = await response.json()
      const token = payload.user?.accessToken
      if (!token) throw new Error('登录响应里没有 accessToken')
      return token
    } catch (error) {
      lastError = error
      if (attempt < 3) {
        log(`登录第 ${attempt} 次失败，重试：${error.message}`)
        await new Promise((resolve) => setTimeout(resolve, 3000))
      }
    }
  }
  throw lastError
}

async function discoverIssuer() {
  // ABS 要求显式配置全部端点；JWKS 和登出地址核心没有单独注入，从身份提供方的发现文档取
  const discoveryUrl = `${OIDC.issuer.replace(/\/+$/, '')}/.well-known/openid-configuration`
  const config = await getJson(discoveryUrl)
  if (!config.jwks_uri) throw new Error(`发现文档里没有 jwks_uri：${discoveryUrl}`)
  const algorithms = config.id_token_signing_alg_values_supported || []
  if (algorithms.length && !algorithms.includes('RS256')) {
    throw new Error(`身份提供方不支持 RS256 签名（支持：${algorithms.join(', ')}）`)
  }
  return { jwksUrl: config.jwks_uri, logoutUrl: config.end_session_endpoint || '' }
}

async function main() {
  await waitUntilHealthy()
  await ensureRootUser()
  const token = await loginAsRoot()
  const { jwksUrl, logoutUrl } = await discoverIssuer()

  await request('PATCH', `${APP_URL}/api/auth-settings`, {
    headers: { Authorization: `Bearer ${token}` },
    body: {
      authActiveAuthMethods: ['local', 'openid'],
      authOpenIDIssuerURL: OIDC.issuer,
      authOpenIDAuthorizationURL: OIDC.authUrl,
      authOpenIDTokenURL: OIDC.tokenUrl,
      authOpenIDUserInfoURL: OIDC.userinfoUrl,
      authOpenIDJwksURL: jwksUrl,
      authOpenIDLogoutURL: logoutUrl,
      authOpenIDClientID: OIDC.clientId,
      authOpenIDClientSecret: OIDC.clientSecret,
      authOpenIDTokenSigningAlgorithm: 'RS256',
      // 登录页自动跳 OIDC；按用户名把 root 账号连到核心用户；不开自动注册（新用户只会是普通用户，角色不对）
      authOpenIDAutoLaunch: true,
      authOpenIDAutoRegister: false,
      authOpenIDMatchExistingBy: 'username',
      // 核心的组声明是 ["owner"]，而 ABS 的组映射只认 admin/user/guest 字面值，配了反而拒绝登录
      authOpenIDGroupClaim: '',
      authOpenIDAdvancedPermsClaim: '',
      // 上游镜像的网页在 /audiobookshelf 子路径下，回调地址要带上它
      authOpenIDSubfolderForRedirectURLs: '/audiobookshelf'
    }
  })
  log('OIDC 设置已写入')

  const status = await getJson(`${APP_URL}/status`)
  if (!Array.isArray(status.authMethods) || !status.authMethods.includes('openid')) {
    throw new Error(`写入后 OIDC 没有生效（authMethods：${JSON.stringify(status.authMethods)}）`)
  }
  log(`完成，authMethods=${status.authMethods.join(',')}`)
}

main().catch((error) => {
  console.error(`[provision] 失败：${error?.message ?? error}`)
  process.exit(1)
})
