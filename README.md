# SSL证书自动化管理脚本

一个用于自动化申请和管理 Let's Encrypt SSL 证书的工具，基于 acme.sh 客户端开发。它通过 Cloudflare 的 DNS API 自动验证域名所有权，并将证书安装到指定目录，同时设置自动续期任务。

## 使用
```bash
curl -LO https://raw.githubusercontent.com/KuwiNet/acme-cf-cert/main/acme_cert.sh && chmod +x acme_cert.sh && ./acme_cert.sh
```
### 国内网络
```bash
curl -LO https://gitee.com/kuwinet/acme-cf-cert/raw/main/acme_cert.sh && chmod +x acme_cert.sh && ./acme_cert.sh
```

## 查看已配置域名
```bash
./acme_cert.sh --list
```

## 清理配置
```bash
./acme_cert.sh --clean           # 交互式清理配置
```
```bash
./acme_cert.sh --clean-all       # 清除所有配置
```
```bash
./acme_cert.sh --clean-domains   # 仅清除域名配置
```
```bash
./acme_cert.sh --clean-email     # 仅清除邮箱配置
```
```bash
./acme_cert.sh --clean-token     # 仅清除Token配置
```

## 帮助信息
```bash
./acme_cert.sh --help            # 显示帮助信息
```
