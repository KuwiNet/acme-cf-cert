# acme_cert.sh —— SSL 证书自动化管理脚本

基于 [acme.sh](https://github.com/acmesh-official/acme.sh) 的 Let's Encrypt 证书申请 / 安装 / 自动续期工具。

- **多 DNS 服务商**：Cloudflare、阿里云、DNSPod、腾讯云、华为云、Route 53 等 14 家 + 手动模式
- **首次运行向导**：除了 API 凭据，还会引导填写邮箱、证书目录、续期命令和域名组
- **交互 / 非交互双模式**：手工运维直接跑，CI 用 `-y` + 参数跑
- **签发结果可预期**：默认不强制重签（不烧 Let's Encrypt 限额），支持 `--staging` 测试环境
- **配置集中持久化**：一个 600 权限的 `config.conf`，域名组按行记录、自动去重
- **1.x 配置自动迁移**：老的 `token.cfg` / `email.cfg` / `configdir.cfg` / `domains.cfg` 无需手动搬

---

## 快速开始

```bash
# 一条命令：引导脚本自动测速选源，下载校验后保存并运行
curl -fsSL https://gitee.com/kuwinet/acme-cf-cert/raw/main/install.sh | bash

# Gitee 不可用时的备用入口
curl -fsSL https://raw.githubusercontent.com/KuwiNet/acme-cf-cert/main/install.sh | bash
```

`install.sh` 自己只用一次、不落盘，它会：

1. 探测 GitHub / Gitee / `acme.kuwi.net` 三个源，选**当前网络最快**的那个拉取 `acme_cert.sh`
2. 校验正文（体积、shebang、`SCRIPT_VERSION`、`bash -n`），错误页或旧版本一律丢弃并换源
3. 保存为 `acme_cert.sh`（当前目录，或 `-d` 指定目录）并 `chmod +x`
4. 立即运行（`-n` 只保存不运行），后面 `--` 之后的参数会原样传给 `acme_cert.sh`

| 引导脚本参数 | 说明 |
|---|---|
| `-d, --dir DIR` | 保存目录（默认当前目录） |
| `-n, --no-run` | 只下载保存，不立即运行 |
| `-m, --mirror auto\|github\|gitee\|cdn` | 强制下载源，默认 `auto`（测速） |
| `-f, --force` | 忽略探测，逐源重试直到成功 |
| `--min-version V` | 拒绝低于该版本的正文（默认 `2.0.0`） |
| `-- <参数>` | 传给 `acme_cert.sh`，如 `-- --dry-run` |

```bash
# 只保存不运行，装到 /usr/local/bin
curl -fsSL https://gitee.com/kuwinet/acme-cf-cert/raw/main/install.sh | bash -s -- -n -d /usr/local/bin

# 装完直接带参数执行（非交互签发示例）
curl -fsSL https://gitee.com/kuwinet/acme-cf-cert/raw/main/install.sh | bash -s -- -- -y -p aliyun --cred Ali_Key=x
```

首次运行会依次询问（输入凭据时不回显）：

1. **DNS 服务商**（编号选择，默认 Cloudflare）
2. **服务商凭据**（如 Cloudflare 的 `CF_Token`，只问必填项，可选项可留空）
3. **管理员邮箱**（Let's Encrypt 到期提醒用，任意有效邮箱）
4. **证书保存目录**（默认 `/root/cert`，非 root 用户默认 `$HOME/cert`）
5. **证书更新后执行的命令**（如 `nginx -s reload`，可留空）
6. **域名组**（第一个为主域名，可再填其他域名 / 通配符）

之后每次运行会直接复用配置，只让你选择要处理的域名组。

---

## 支持的服务商

`-p/--provider` 取值、对应 acme.sh 的 dnsapi 脚本、以及需要填写的凭据变量：

| `--provider` | 服务商 | acme.sh dnsapi | 必填凭据 | 可选凭据 |
|---|---|---|---|---|
| `cloudflare` | Cloudflare | `dns_cf` | `CF_Token` | `CF_Account_ID` `CF_Zone_ID` |
| `aliyun` | 阿里云 DNS | `dns_ali` | `Ali_Key` `Ali_Secret` | - |
| `dnspod` | DNSPod（dnspod.cn） | `dns_dp` | `DP_Id` `DP_Key` | - |
| `tencent` | 腾讯云 DNSPod（API3） | `dns_tencent` | `Tencent_SecretId` `Tencent_SecretKey` | - |
| `huaweicloud` | 华为云 DNS | `dns_huaweicloud` | `HUAWEICLOUD_Username` `HUAWEICLOUD_Password` | `HUAWEICLOUD_DomainName` `HUAWEICLOUD_Region` |
| `aws` | AWS Route 53 | `dns_aws` | `AWS_ACCESS_KEY_ID` `AWS_SECRET_ACCESS_KEY` | `AWS_DNS_SLOWRATE` |
| `digitalocean` | DigitalOcean | `dns_dgon` | `DO_API_KEY` | - |
| `vultr` | Vultr | `dns_vultr` | `VULTR_API_KEY` | - |
| `linode` | Linode / Akamai | `dns_linode_v4` | `LINODE_V4_API_KEY` | - |
| `godaddy` | GoDaddy | `dns_gd` | `GD_Key` `GD_Secret` | - |
| `namecheap` | Namecheap | `dns_namecheap` | `NAMECHEAP_USERNAME` `NAMECHEAP_API_KEY` | `NAMECHEAP_SOURCEIP` |
| `namesilo` | NameSilo | `dns_namesilo` | `Namesilo_Key` | - |
| `cloudns` | ClouDNS | `dns_cloudns` | `CLOUDNS_AUTH_ID` `CLOUDNS_AUTH_PASSWORD` | `CLOUDNS_SUB_AUTH_ID` |
| `porkbun` | Porkbun | `dns_porkbun` | `PORKBUN_API_KEY` `PORKBUN_SECRET_API_KEY` | - |
| `manual` | 手动 DNS（任意服务商/自建 DNS） | 手工验证 | - | - |

> 需要其它服务商时，可在 `provider_creds` / `provider_dnsapi` / `provider_label` 三处照样式新增；
> acme.sh 已内置 200+ 家 dnsapi，名字见 [dnsapi 目录](https://github.com/acmesh-official/acme.sh/tree/master/dnsapi)。
> 不想改脚本也可以先用 `manual` 模式，或把 acme.sh 环境变量直接导出后手工调用 acme.sh。

---

## 命令

| 命令 | 说明 |
|---|---|
| `./acme_cert.sh` | 交互式申请证书（首次运行自动进入配置向导） |
| `./acme_cert.sh --issue` | 申请 / 安装证书（默认命令） |
| `./acme_cert.sh --list` | 查看配置、域名组、已装证书到期时间 |
| `./acme_cert.sh --status` | 同 `--list`，并显示 acme.sh 内部证书清单与下次续期时间 |
| `./acme_cert.sh --renew` | 续期所有域名组（默认只续快到期的，`-f` 强制） |
| `./acme_cert.sh --config` | 重新进入配置向导（改服务商/凭据/邮箱/目录/密钥/CA） |
| `./acme_cert.sh --check` | 环境自检（依赖、acme.sh、dnsapi、配置、证书到期） |
| `./acme_cert.sh --update-acme` | 升级 acme.sh 客户端 |
| `./acme_cert.sh --update` | 更新本脚本（`acme.kuwi.net` 优先、GitHub raw 回退，校验后覆盖并留 `.bak`） |
| `./acme_cert.sh --clean` | 交互式清理配置 |
| `./acme_cert.sh --clean-all` | 清除全部配置（加 `-y` 不再确认） |
| `./acme_cert.sh --clean-auth` | 仅清除 DNS 凭据（`--clean-token` 为兼容别名） |
| `./acme_cert.sh --clean-domains` | 仅清除域名组 |
| `./acme_cert.sh --clean-email` | 仅清除邮箱 |
| `./acme_cert.sh --clean-certdir` | 仅清除证书目录设置 |
| `./acme_cert.sh --help` / `-h` | 帮助 |
| `./acme_cert.sh --version` / `-V` | 版本号 |

## 参数

| 参数 | 说明 |
|---|---|
| `-d, --domain LIST` | 域名组，逗号或空格分隔，**第一个为主域名**；例 `-d "example.com,*.example.com"` |
| `-p, --provider NAME` | DNS 服务商，见上表 |
| `-e, --email ADDR` | 管理员邮箱 |
| `-o, --cert-dir DIR` | 证书输出目录 |
| `-k, --keylength LEN` | `ec-256`（默认）/ `ec-384` / `2048` / `4096` |
| `-c, --reload-cmd CMD` | 证书更新后执行的命令，如 `"nginx -s reload"` |
| `--ca NAME` | `letsencrypt`（默认）/ `zerossl` / `sslcom` / `google` |
| `-s, --staging` | 用 Let's Encrypt 测试环境（不占限额、证书不受信任，仅本次生效、不写入配置） |
| `-f, --force` | 强制重新签发（**会消耗限额**，慎用） |
| `-y, --yes` | 非交互：全部取参数/已存配置，缺项直接报错退出 |
| `--cred KEY=VALUE` | 指定凭据，可重复；值里含 `=` 也没问题 |
| `--no-update-check` | 跳过脚本版本检查 |
| `--dry-run` | 只打印将执行的 acme.sh 命令，不实际执行（不写配置、不装 cron） |

---

## 常用示例

```bash
# Cloudflare 通配符证书（凭据从参数传入，首次运行同时落盘）
./acme_cert.sh -p cloudflare -d "example.com,*.example.com" \
    --cred CF_Token=xxxxxxxx -e me@example.com -o /root/cert -y

# 阿里云 DNS（两个凭据）
./acme_cert.sh -p aliyun -d "example.com,*.example.com" \
    --cred Ali_Key=LTAIxxxx --cred Ali_Secret=xxxx -e me@example.com -y

# 腾讯云 DNSPod
./acme_cert.sh -p tencent -d "example.com" \
    --cred Tencent_SecretId=xxx --cred Tencent_SecretKey=xxx -e me@example.com -y

# CI / 环境变量方式（凭据不落在命令行历史里）
CF_Token=xxxx ./acme_cert.sh -p cloudflare -d "example.com" -e me@example.com -y

# 新服务商先跑测试环境，确认流程通了再正式签
./acme_cert.sh -p dnspod --cred DP_Id=xxx --cred DP_Key=xxx -d "test.example.com" -s -y

# 证书更新后自动 reload nginx
./acme_cert.sh -d "example.com" -c "nginx -t && nginx -s reload" -y

# 只看看会执行什么
./acme_cert.sh -d "example.com" --dry-run -y
```

---

## 配置文件与证书目录

| 路径 | 内容 |
|---|---|
| `~/.acme_cert/config.conf` | 服务商、凭据、邮箱、证书目录、密钥类型、CA、reload 命令（权限 `600`，目录 `700`） |
| `~/.acme_cert/domains.conf` | 每行一个域名组，主域名在前；重复组不会重复写入 |
| `~/.acme_cert/.update_check` | 版本检查缓存（24 小时内不再联网） |

- 配置目录可用环境变量 `ACME_CERT_CONF_DIR` 覆盖（例如装到 `/etc/acme_cert`）。
- 凭据只在申请 / 续期时通过环境变量传给 acme.sh，不会出现在命令行参数或进程列表里。
- 生成目录结构：

```
/root/cert/
├── example.com/                 # 主域名命名的目录
│   ├── cert.pem                 # 域名证书
│   ├── key.pem                  # 私钥（600）
│   ├── ca.pem                   # 中间 CA 链
│   └── fullchain.pem            # 证书 + CA 链（Nginx/Apache 推荐）
└── wildcard.example.com/       # 主域名为 *.example.com 时
```

多域名（SAN）组统一安装在「主域名」对应目录下；`*.example.com` 会自动补上基础域名 `example.com`（可拒绝）。

## 自动续期

- 签发后自动添加 acme.sh 计划任务（每日检查，到期前 30 天左右自动续期）。
- 续期成功后 acme.sh 会按 `--reloadcmd`（即 `-c/--reload-cmd` 保存的命令）自动重载服务，并重新写回上面四个 pem 文件。
- 想手动触发：`./acme_cert.sh --renew`（默认只处理该续期的，加 `-f` 强制）。
- `manual` 模式无法自动续期，到期需人工重新签发。

## 从 1.x 升级

直接替换脚本即可。首次运行会检测 `~/cert/config/` 下的旧配置（`token.cfg`、`email.cfg`、`configdir.cfg`、`domains.cfg`），
自动迁移成 `~/.acme_cert/config.conf` + `domains.conf`，旧目录保留不删。

> 注意：1.x 的证书目录规则是 `<证书目录>/<主域名去掉 *.>`，2.0 改为 `<证书目录>/wildcard.example.com`。
> 迁移后重跑一次 `./acme_cert.sh`（选原域名组）会把证书落到新目录，旧目录可自行清理。

---

## 常见问题

**1. 申请失败，提示 403 / 权限不足？**
Token 权限不够。Cloudflare 需要 `Zone.DNS:Edit`；阿里云 RAM 用户需要 `AliyunDNSFullAccess`；Route 53 需要 `route53:ChangeResourceRecordSets`。

**2. 提示 `Domains not changed` / `Skipping`？**
证书还没到续期时间，属于正常跳过（脚本按成功处理）。确实要立刻重签再加 `-f`。

**3. 反复失败会不会被封？**
Let's Encrypt 对同一域名组有「每周 5 张重复证书」限制。调试请用 `-s`（测试环境），它不占正式限额。

**4. 通配符 `*.example.com` 一定要加 `example.com` 吗？**
通配符只覆盖一级子域，不带 `example.com` 本身。脚本默认会自动补上基础域名，也可以选择不加。

**5. 想换服务商 / 换凭据？**
`./acme_cert.sh --config`，或重新用 `-p` + `--cred` 跑一次。切换服务商时会自动清理其它服务商的旧凭据。

**6. 提示 `当前不是以文件方式运行或文件不可写`？**
用上面的 `install.sh` 引导安装不会遇到这个问题：它会先把 `acme_cert.sh` 存盘再执行，`--update` 正常可用。只有把正文直接管道执行（`curl ... acme_cert.sh | bash`）才会没有可写文件。

**7. 想看最终执行的 acme.sh 命令？**
加 `--dry-run`；或直接查看 `acme.sh` 自己的日志：`~/.acme.sh/acme.sh.log`。

---

## License

与上游 acme.sh 一致，仅供自用与学习参考。
