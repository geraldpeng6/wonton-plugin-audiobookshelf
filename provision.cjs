/*
 * 一次性 provision 服务的脚本：把 Audiobookshelf 的 OIDC 指到核心的身份提供方，发信服务器接到核心的内部邮箱。
 *
 * 为什么要有这个服务：ABS 的认证、发信设置都存在自己的 SQLite 里，上游没有环境变量或配置文件的入口，
 * 只能由管理员经 API 修改（认证是 MiscController.updateAuthSettings，发信是 EmailController.updateSettings）。所以：
 *   1. 空库时经 POST /init 建以注入用户名命名的 root 账号（密码是插件密钥 WONTON_SECRET_ADMIN_PASSWORD）；
 *   2. 本地登录拿 access token，PATCH /api/auth-settings 写入 OIDC 设置；
 *   3. PATCH /api/emails/settings 把发信服务器配成核心的 SMTP。只在应用还没配过时写：注入的地址和端口不会变，
 *      而主人可能在应用里改发信设置（比如给「发送到阅读器」配自己的服务器投到外部邮箱），每次覆盖会抹掉这些改动；
 *   4. 每次容器创建（安装、升级、重建）都会重跑：OIDC 客户端的密钥核心会换，这里每次覆盖写最新的，
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
// 核心的内部 SMTP：明文 25 端口、不认证不加密，信由核心按收件地址转进收件人的 Wonton 私聊，只收家里人的地址。
const SMTP = {
  host: required('WONTON_SMTP_HOST'),
  port: Number(required('WONTON_SMTP_PORT')),
  fromAddress: required('WONTON_MAIL_FROM'),
  // 测试信按钮没填测试地址时会寄给发件地址，核心只认家里人，插件自己的地址会被拒收
  testAddress: required('WONTON_OWNER_EMAIL')
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

// 不再重试的失败（如登录 401：密码对不上，重试只会耗登录限流名额）
class FatalError extends Error {}

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
        throw new FatalError(
          `管理员账号登录不了（401）：数据目录里已有 root 账号但密码不是本插件的密钥。` +
            `保留数据时不要在应用里改 "${OWNER}" 的密码；删掉插件数据重装可以恢复。`
        )
      }
      const payload = await response.json()
      const token = payload.user?.accessToken
      if (!token) throw new Error('登录响应里没有 accessToken')
      return token
    } catch (error) {
      if (error instanceof FatalError) throw error
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
  // ABS 要求显式配置全部端点；JWKS 和登出地址核心没有单独注入，从身份提供方的发现文档取。
  // 冒烟/新装时身份提供方可能比应用晚几秒就绪，这里给出有界的重试，超时照实报错
  let lastError = null
  for (let attempt = 1; attempt <= 10; attempt++) {
    try {
      const discoveryUrl = `${OIDC.issuer.replace(/\/+$/, '')}/.well-known/openid-configuration`
      const config = await getJson(discoveryUrl)
      if (!config.jwks_uri) throw new Error(`发现文档里没有 jwks_uri：${discoveryUrl}`)
      const algorithms = config.id_token_signing_alg_values_supported || []
      if (algorithms.length && !algorithms.includes('RS256')) {
        throw new Error(`身份提供方不支持 RS256 签名（支持：${algorithms.join(', ')}）`)
      }
      return { jwksUrl: config.jwks_uri, logoutUrl: config.end_session_endpoint || '' }
    } catch (error) {
      lastError = error
      if (attempt < 10) {
        log(`身份提供方发现文档第 ${attempt} 次没取到，重试：${error.message}`)
        await new Promise((resolve) => setTimeout(resolve, 3000))
      }
    }
  }
  throw lastError
}

async function configureEmailSettings(token) {
  const headers = { Authorization: `Bearer ${token}` }
  const { settings } = await getJson(`${APP_URL}/api/emails/settings`, headers)
  if (settings.host) {
    log(`应用里已有发信配置（host=${settings.host}:${settings.port}），不覆盖`)
    return
  }
  const response = await request('PATCH', `${APP_URL}/api/emails/settings`, {
    headers,
    body: {
      host: SMTP.host,
      port: SMTP.port,
      secure: false,
      // 不填用户名密码（核心的 SMTP 不需要认证）；显式置空，免得旧数据里的凭据留在设置里
      user: null,
      pass: null,
      fromAddress: SMTP.fromAddress,
      testAddress: SMTP.testAddress
    }
  })
  const written = (await response.json()).settings
  if (written.host !== SMTP.host || written.port !== SMTP.port || written.fromAddress !== SMTP.fromAddress) {
    throw new Error(`发信设置写入后对不上：host=${written.host}:${written.port}，from=${written.fromAddress}`)
  }
  log(`发信服务器已配成 ${written.host}:${written.port}（发件地址 ${written.fromAddress}），测试信寄到 ${written.testAddress}`)
}

async function main() {
  await waitUntilHealthy()
  await ensureRootUser()
  const token = await loginAsRoot()
  const { jwksUrl, logoutUrl } = await discoverIssuer()

  const oidcSettings = {
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

  // ABS 在启动时把 OIDC 客户端（含密钥）缓存在内存里，PATCH 改密钥不会重建（上游 updateAuthSettings 只在
  // 认证方式增减时重建）。保留数据重装时核心会换新客户端密钥，不重建的话回调拿旧密钥换不到 token。
  // 所以先经应用自己的接口关掉 openid（unuse，清缓存），再带着新设置开启（use，按当前设置重建）。
  await request('PATCH', `${APP_URL}/api/auth-settings`, {
    headers: { Authorization: `Bearer ${token}` },
    body: { authActiveAuthMethods: ['local'] }
  })
  await request('PATCH', `${APP_URL}/api/auth-settings`, {
    headers: { Authorization: `Bearer ${token}` },
    body: oidcSettings
  })
  log('OIDC 设置已写入')

  const status = await getJson(`${APP_URL}/status`)
  if (!Array.isArray(status.authMethods) || !status.authMethods.includes('openid')) {
    throw new Error(`写入后 OIDC 没有生效（authMethods：${JSON.stringify(status.authMethods)}）`)
  }
  log(`OIDC 已生效，authMethods=${status.authMethods.join(',')}`)

  await configureEmailSettings(token)
  log('完成')
}

main().catch((error) => {
  console.error(`[provision] 失败：${error?.message ?? error}`)
  process.exit(1)
})
