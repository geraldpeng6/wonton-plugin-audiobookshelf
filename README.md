# 云吞插件：Audiobookshelf

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

把共享文件夹 `audiobooks` 里的有声书做成自己的书架，播放进度在手机和网页之间同步。网页登录走核心的身份提供方
（`sso: oidc`），打开就是自己的管理员账号，不用再登录一次。

## 插件行为

- 登录：Audiobookshelf 的认证设置存在应用自己的数据库里、只能由管理员改（上游没有环境变量入口），所以由一次性
  `provision` 服务配置：空库时用注入的用户名建 root 账号（密码是核心密钥 `admin_password`），本地登录后
  `PATCH /api/auth-settings` 把 OIDC 指到核心的身份提供方。每次创建容器（安装、升级、重建）都会重跑，OIDC
  客户端密钥换了就覆盖写最新的。登录用"按用户名匹配已有用户"把 root 账号连到核心用户，不开自动注册
  （自动注册建出来的是普通用户，角色不对）。
- 应用内保留本地登录作为备用入口：`/login/?autoLaunch=0`，账号是注入的用户名，密码是插件详情里 `admin_password`
  密钥的值。OIDC 万一配错，用它还能进去（上游文档的建议）。
- 有声书目录只读（`storage.share.audiobooks:read`），应用不会被改动文件；播客由应用按 RSS 订阅下载，存在应用
  自己的数据目录（`/metadata`）里。第一次打开时在应用里建书库，目录选 `/audiobooks` 就能扫到共享文件夹。
- 发信：provision 把应用的发信服务器（Server Settings → Email）接到核心的内部 SMTP（`smtp.wonton.internal:25`，不认证
  不加密），只在应用还没配过时写一次（注入的地址不会变，主人自己改过发信设置就不覆盖）。应用发的信出现在收件人的
  Wonton 私聊里，设置页的「发送测试邮件」寄到主人自己的内部邮箱；收件人是外部地址（「发送到阅读器」填的 Kindle 邮箱）
  时核心在 SMTP 阶段就拒收，应用报发送失败。
- 申请了 `network.egress`：播客 RSS 下载和元数据匹配（封面、简介）需要访问外网，经云吞的出网代理走；
  应用内直接监听局域网的功能没有开（没有 `lan.ports`），所有网页访问都经核心网关。

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印它的地址，用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 列出插件要的权限，确认后
装上并打印插件网页的地址，打开就是用户自己的书架。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `provision.cjs` | 一次性 `provision` 服务的脚本：建管理员、配置 OIDC 和发信服务器 |
| `icon.png` | 插件图标 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送（只用上游镜像，无自建镜像） |
| `scripts/smoke-probes.sh` | 冒烟的网页、身份、数据探测 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件许可证、上游 GPL-3.0 许可证和商标声明 |

## 图标来源与授权

`icon.png` 使用 Audiobookshelf 官方标志（`client/static/Logo.png`，原样放在白色底上），未用图片模型生成；来源、
版权、处理方式、上游 GPL-3.0 全文和商标说明见 [NOTICE](NOTICE)。Audiobookshelf 名称和标志是 Audiobookshelf
项目的商标；本插件是独立维护的云吞插件包，不代表上游官方出品、合作或背书。
