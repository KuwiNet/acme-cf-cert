#!/usr/bin/env bash
#
# acme_cert.sh —— 基于 acme.sh 的证书申请 / 安装 / 自动续期管理脚本
#   · 支持多个 DNS 服务商（Cloudflare / 阿里云 / DNSPod / 腾讯云 / 华为云 / Route53 ...）
#   · 首次运行引导填写 服务商凭据、管理员邮箱、证书目录、续期命令 与 域名组
#   · 交互式与命令行参数双模式，适合手工运维也适合 CI
#   · 1.x 版本配置（token.cfg / email.cfg / configdir.cfg / domains.cfg）自动迁移
#
# 仓库: https://github.com/KuwiNet/acme-cf-cert
#
# shellcheck shell=bash
# shellcheck disable=SC2086,SC2015,SC1090,SC2181

SCRIPT_NAME="acme_cert.sh"
SCRIPT_VERSION="2.0.3"
SCRIPT_URL="https://raw.githubusercontent.com/KuwiNet/acme-cf-cert/main/acme_cert.sh"
# acme.kuwi.net 现在只托管 install.sh（引导安装器），自更新改走 Gitee 镜像，
# 失败再回退 GitHub raw；顺序反过来在境内会明显变慢。
MIRROR_URL="https://gitee.com/kuwinet/acme-cf-cert/raw/main/acme_cert.sh"
REPO_URL="https://github.com/KuwiNet/acme-cf-cert"

set -o pipefail
umask 077

# ============================ 基础输出 ============================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${BLUE}[*]${NC} $*"; }
ok()   { printf '%s\n' "${GREEN}[✓]${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
err()  { printf '%s\n' "${RED}[✗]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
eline() { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${NC}"; }
kv()  { printf '  %s：%s\n' "$1" "$2"; }
kv4() { printf '    %s：%s\n' "$1" "$2"; }

# 交互输入固定在 fd 3 上读取：
#   · 有终端时直连 /dev/tty，兼容 curl | bash 这种 stdin 被脚本占用的场景
#   · 无终端时退回原始 stdin，兼容 echo "..." | ./acme_cert.sh 这种自动化输入
if [ -r /dev/tty ] && [ -t 1 ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

# ============================ 变量与路径 ============================
CONF_DIR="${ACME_CERT_CONF_DIR:-$HOME/.acme_cert}"
CONF_FILE="$CONF_DIR/config.conf"
DOMAINS_FILE="$CONF_DIR/domains.conf"
LEGACY_CONF_DIR="$HOME/cert/config"          # 1.x 版本配置目录，用于自动迁移

PROVIDER=""
EMAIL=""
CERT_DIR=""
RELOAD_CMD=""
KEYLEN="ec-256"
CA="letsencrypt"
STAGING="0"

OPT_EMAIL=""
OPT_CERT_DIR=""
OPT_RELOAD_CMD=""
OPT_KEYLEN=""
OPT_CA=""
OPT_STAGING="0"

ACME=""
ACME_HOME=""
SUDO=""
ASSUME_YES="0"
FORCE="0"
DRY_RUN="0"
NO_UPDATE_CHECK="${ACME_CERT_NO_UPDATE_CHECK:-0}"
ACTION="issue"
OPT_DOMAIN=""
OPT_PROVIDER=""
CRED_PAIRS=()

PROVIDERS="cloudflare aliyun dnspod tencent huaweicloud aws digitalocean vultr linode godaddy namecheap namesilo cloudns porkbun manual"

# ============================ DNS 服务商注册表 ============================
provider_label() {
    case "$1" in
        cloudflare)   printf 'Cloudflare' ;;
        aliyun)       printf '阿里云 DNS' ;;
        dnspod)       printf 'DNSPod（dnspod.cn）' ;;
        tencent)      printf '腾讯云 DNSPod（API3）' ;;
        huaweicloud)  printf '华为云 DNS' ;;
        aws)          printf 'AWS Route 53' ;;
        digitalocean) printf 'DigitalOcean' ;;
        vultr)        printf 'Vultr' ;;
        linode)       printf 'Linode / Akamai' ;;
        godaddy)      printf 'GoDaddy' ;;
        namecheap)    printf 'Namecheap' ;;
        namesilo)     printf 'NameSilo' ;;
        cloudns)      printf 'ClouDNS' ;;
        porkbun)      printf 'Porkbun' ;;
        manual)       printf '手动 DNS（任意服务商 / 自建 DNS）' ;;
        *)            printf '未配置' ;;
    esac
}

# acme.sh 的 dnsapi 脚本名（与其 dnsapi/*.sh 一一对应）
provider_dnsapi() {
    case "$1" in
        cloudflare)   printf 'dns_cf' ;;
        aliyun)       printf 'dns_ali' ;;
        dnspod)       printf 'dns_dp' ;;
        tencent)      printf 'dns_tencent' ;;
        huaweicloud)  printf 'dns_huaweicloud' ;;
        aws)          printf 'dns_aws' ;;
        digitalocean) printf 'dns_dgon' ;;
        vultr)        printf 'dns_vultr' ;;
        linode)       printf 'dns_linode_v4' ;;
        godaddy)      printf 'dns_gd' ;;
        namecheap)    printf 'dns_namecheap' ;;
        namesilo)     printf 'dns_namesilo' ;;
        cloudns)      printf 'dns_cloudns' ;;
        porkbun)      printf 'dns_porkbun' ;;
        manual)       printf 'manual' ;;
    esac
}

# 凭据表：变量名|说明|是否密文(1/0)|是否可留空(1/0)
# 变量名必须与 acme.sh 对应 dnsapi 脚本读取的环境变量一致
provider_creds() {
    case "$1" in
        cloudflare)
            printf '%s\n' \
                'CF_Token|API Token（权限 Zone.DNS:Edit）|1|0' \
                'CF_Account_ID|Account ID（多账号共用 Token 时填）|0|1' \
                'CF_Zone_ID|Zone ID（指定解析域时填）|0|1' ;;
        aliyun)
            printf '%s\n' \
                'Ali_Key|AccessKey ID|0|0' \
                'Ali_Secret|AccessKey Secret|1|0' ;;
        dnspod)
            printf '%s\n' \
                'DP_Id|DNSPod Token ID|0|0' \
                'DP_Key|DNSPod Token|1|0' ;;
        tencent)
            printf '%s\n' \
                'Tencent_SecretId|SecretId|0|0' \
                'Tencent_SecretKey|SecretKey|1|0' ;;
        huaweicloud)
            printf '%s\n' \
                'HUAWEICLOUD_Username|IAM 用户名|0|0' \
                'HUAWEICLOUD_Password|IAM 密码|1|0' \
                'HUAWEICLOUD_DomainName|账号所属企业域名（子账号时填）|0|1' \
                'HUAWEICLOUD_Region|区域，默认 cn-north-4|0|1' ;;
        aws)
            printf '%s\n' \
                'AWS_ACCESS_KEY_ID|Access Key ID|0|0' \
                'AWS_SECRET_ACCESS_KEY|Secret Access Key|1|0' \
                'AWS_DNS_SLOWRATE|Route53 生效慢时填 1|0|1' ;;
        digitalocean) printf '%s\n' 'DO_API_KEY|Personal Access Token|1|0' ;;
        vultr)        printf '%s\n' 'VULTR_API_KEY|API Key|1|0' ;;
        linode)       printf '%s\n' 'LINODE_V4_API_KEY|API Token|1|0' ;;
        godaddy)
            printf '%s\n' \
                'GD_Key|API Key|1|0' \
                'GD_Secret|API Secret|1|0' ;;
        namecheap)
            printf '%s\n' \
                'NAMECHEAP_USERNAME|账号用户名|0|0' \
                'NAMECHEAP_API_KEY|API Key|1|0' \
                'NAMECHEAP_SOURCEIP|API 白名单 IP，留空自动获取|0|1' ;;
        namesilo)     printf '%s\n' 'Namesilo_Key|API Key|1|0' ;;
        cloudns)
            printf '%s\n' \
                'CLOUDNS_AUTH_ID|Auth ID|0|0' \
                'CLOUDNS_AUTH_PASSWORD|Auth Password|1|0' \
                'CLOUDNS_SUB_AUTH_ID|子账号 ID（可选）|0|1' ;;
        porkbun)
            printf '%s\n' \
                'PORKBUN_API_KEY|API Key|0|0' \
                'PORKBUN_SECRET_API_KEY|Secret API Key|1|0' ;;
        manual) : ;;
    esac
}

provider_hint() {
    case "$1" in
        cloudflare)   printf '控制台 → 我的个人资料 → API 令牌 → 创建令牌（模板: Edit zone DNS）' ;;
        aliyun)       printf '阿里云控制台 → AccessKey 管理；RAM 用户需授予 AliyunDNSFullAccess' ;;
        dnspod)       printf 'DNSPod 控制台 → 用户中心 → 密钥管理 → 创建 Token（同时给出 ID 和 Token）' ;;
        tencent)      printf '腾讯云 → 访问管理 → API 密钥；账号需具备 DNSPod 解析权限' ;;
        huaweicloud)  printf '华为云 → 我的凭证 → 访问密钥，或 IAM 用户名密码；域名需已托管在华为云 DNS' ;;
        aws)          printf 'IAM 用户 Access Key，权限需包含 route53:ChangeResourceRecordSets' ;;
        digitalocean) printf 'API → Tokens → Generate New Token（读写权限）' ;;
        vultr)        printf 'Account → API → Personal Access Token（需启用 DNS 管理权限）' ;;
        linode)       printf 'Linode Cloud Manager → API Tokens（读写权限）' ;;
        godaddy)      printf 'GoDaddy → API Keys（需先申请 API 权限，Production Key）' ;;
        namecheap)    printf 'Profile → Tools → Namecheap API Access，需把服务器公网 IP 加入白名单' ;;
        namesilo)     printf 'NameSilo → API Manager → Generate API Key' ;;
        cloudns)      printf 'ClouDNS → API → 开启 API 并获取 Auth ID / Auth Password' ;;
        porkbun)      printf 'Porkbun → API Access → 创建 API Key 与 Secret Key' ;;
        manual)       printf '签发过程中会暂停，提示你到 DNS 服务商处手动添加 TXT 记录' ;;
    esac
}

# 全部凭据变量名（带缓存，避免反复生成）
CRED_KEYS_CACHE=""
cred_keys() {
    if [ -z "$CRED_KEYS_CACHE" ]; then
        local p
        CRED_KEYS_CACHE="$(for p in $PROVIDERS; do provider_creds "$p"; done | cut -d'|' -f1 | grep -v '^$' | sort -u)"
    fi
    printf '%s\n' "$CRED_KEYS_CACHE"
}

# ============================ 变量读写（不使用 eval，避免注入） ============================
get_var() {
    local _n="$1" _v=""
    printf -v _v '%s' "${!_n}" 2>/dev/null || _v=""
    printf '%s' "$_v"
}

set_var() {
    printf -v "$1" '%s' "$2" 2>/dev/null || return 1
}

conf_key_allowed() {
    case "$1" in
        PROVIDER|EMAIL|CERT_DIR|RELOAD_CMD|KEYLEN|CA|STAGING) return 0 ;;
    esac
    case " $(cred_keys | tr '\n' ' ') " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

load_conf() {
    [ -f "$CONF_FILE" ] || return 0
    local text key val
    while IFS= read -r text || [ -n "$text" ]; do
        text="${text%$'\r'}"
        case "$text" in ''|'#'*) continue ;; esac
        case "$text" in *=*) : ;; *) continue ;; esac
        key="${text%%=*}"
        val="${text#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        [ -z "$key" ] && continue
        if ! conf_key_allowed "$key"; then
            warn "配置文件中存在未知项 [$key]，已忽略"
            continue
        fi
        set_var "$key" "$val"
    done < "$CONF_FILE"
}

save_conf() {
    mkdir -p "$CONF_DIR" 2>/dev/null || die "无法创建配置目录: $CONF_DIR"
    chmod 700 "$CONF_DIR" 2>/dev/null || true
    local tmp="$CONF_FILE.tmp.$$" k v
    {
        printf '%s\n' "# acme_cert.sh 配置文件（含 DNS API 凭据，权限 600，请勿分享或提交到仓库）"
        printf '%s\n' "# 由 $SCRIPT_NAME v$SCRIPT_VERSION 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
        for k in PROVIDER EMAIL CERT_DIR RELOAD_CMD KEYLEN CA; do
            v="$(get_var "$k")"
            [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
        done
        for k in $(cred_keys); do
            v="$(get_var "$k")"
            [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
        done
        :
    } > "$tmp" || die "写入配置失败: $tmp"
    mv -f "$tmp" "$CONF_FILE" || die "保存配置失败: $CONF_FILE"
    chmod 600 "$CONF_FILE"
}

# 从 1.x 版本配置迁移（token.cfg / email.cfg / configdir.cfg / domains.cfg）
migrate_legacy() {
    [ -f "$CONF_FILE" ] && return 0
    [ -f "$CONF_DIR/.legacy_migrated" ] && return 0
    [ -d "$LEGACY_CONF_DIR" ] || return 0

    local t="" e="" d="" f text
    f="$LEGACY_CONF_DIR/token.cfg";     [ -f "$f" ] && t="$(tr -d '\r\n' < "$f")"
    f="$LEGACY_CONF_DIR/email.cfg";     [ -f "$f" ] && e="$(tr -d '\r\n' < "$f")"
    f="$LEGACY_CONF_DIR/configdir.cfg"; [ -f "$f" ] && d="$(tr -d '\r\n' < "$f")"
    [ -z "$t$e$d" ] && return 0

    PROVIDER="cloudflare"
    [ -n "$t" ] && set_var CF_Token "$t"
    [ -n "$e" ] && EMAIL="$e"
    [ -n "$d" ] && CERT_DIR="$d"

    f="$LEGACY_CONF_DIR/domains.cfg"
    if [ -f "$f" ]; then
        mkdir -p "$CONF_DIR" 2>/dev/null
        while IFS= read -r text || [ -n "$text" ]; do
            text="$(printf '%s' "$text" | tr -d '\r' | tr -s ' ')"
            [ -z "$text" ] && continue
            printf '%s\n' "$text" >> "$DOMAINS_FILE"
        done < "$f"
    fi

    save_conf
    mkdir -p "$CONF_DIR" 2>/dev/null && : > "$CONF_DIR/.legacy_migrated"
    ok "已从旧版配置迁移到 $CONF_FILE（原目录保留，未删除）"
}

# ============================ 域名组 ============================
# 规范化：逗号/分号/多空格 → 单空格并去重（保留首次出现，主域名始终在最前）
norm_group() {
    local w out=""
    for w in $(printf '%s' "$1" | tr ',;' '  '); do
        [ -z "$w" ] && continue
        case " $out " in *" $w "*) continue ;; esac
        out="${out:+$out }$w"
    done
    printf '%s' "$out"
}

has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

group_main() { set -- $1; printf '%s' "${1:-}"; }

DGROUPS=()
load_groups() {
    DGROUPS=()
    [ -f "$DOMAINS_FILE" ] || return 0
    local text n
    while IFS= read -r text || [ -n "$text" ]; do
        text="${text%$'\r'}"
        case "$text" in ''|'#'*) continue ;; esac
        n="$(norm_group "$text")"
        [ -z "$n" ] && continue
        DGROUPS+=("$n")
    done < "$DOMAINS_FILE"
}

add_group() {
    local g="$1" old
    g="$(norm_group "$g")"
    [ -z "$g" ] && return 1
    if [ "$DRY_RUN" = "1" ]; then
        info "预览模式，域名组不写入配置: $g"
        return 0
    fi
    load_groups
    for old in ${DGROUPS[@]+"${DGROUPS[@]}"}; do
        if [ "$old" = "$g" ]; then
            info "域名组已存在，跳过保存: $g"
            return 0
        fi
    done
    mkdir -p "$CONF_DIR" 2>/dev/null || die "无法创建配置目录: $CONF_DIR"
    printf '%s\n' "$g" >> "$DOMAINS_FILE" || die "无法写入 $DOMAINS_FILE"
    ok "域名组已保存: $g"
}

validate_domain() {
    local d="$1"
    [ -z "$d" ] && return 1
    [ "${#d}" -gt 253 ] && return 1
    case "$d" in
        \*.*) d="${d#\*.}" ;;
        *'*'*) return 1 ;;
    esac
    case "$d" in
        ''|.*|*.|*..*) return 1 ;;
    esac
    printf '%s' "$d" | grep -Eq '^([A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.)+[A-Za-z]{2,}$'
}

# 解析一串域名 → 规范化后的 PARSED_GROUP
PARSED_GROUP=""
parse_domain_list() {
    local raw="$1" d group="" w base
    for d in $(printf '%s' "$raw" | tr ',;' '  '); do
        if ! validate_domain "$d"; then
            err "域名格式无效: $d"
            err "只支持 ASCII 域名；中文域名请先转为 punycode（xn-- 开头）"
            return 1
        fi
        group="$group $d"
    done
    group="$(norm_group "$group")"
    [ -z "$group" ] && { err "未提供有效域名"; return 1; }
    PARSED_GROUP="$group"

    # 通配符证书一般需要同时包含基础域名
    for w in $PARSED_GROUP; do
        case "$w" in
            \*.*)
                base="${w#\*.}"
                if ! has_word "$PARSED_GROUP" "$base"; then
                    PARSED_GROUP="$PARSED_GROUP $base"
                    info "通配符证书一般需要同时包含基础域名，已自动加入: $base"
                fi ;;
        esac
    done
    return 0
}

# ============================ 交互输入 ============================
REPLY_VAL=""
ask_value() {   # $1=提示 $2=默认值
    local prompt="$1" def="${2:-}" ans=""
    REPLY_VAL=""
    if [ "$ASSUME_YES" = "1" ]; then
        REPLY_VAL="$def"
        return 0
    fi
    if [ -n "$def" ]; then
        printf '%s' "  ${CYAN}${prompt}${NC} [${def}]: "
    else
        printf '%s' "  ${CYAN}${prompt}${NC}: "
    fi
    if ! IFS= read -r ans <&3; then die "输入已结束（EOF），已退出"; fi
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    [ -z "$ans" ] && ans="$def"
    REPLY_VAL="$ans"
}

ask_secret() {  # $1=提示，输入不回显
    local prompt="$1" ans=""
    REPLY_VAL=""
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    printf '%s' "  ${CYAN}${prompt}${NC}（输入不显示）: "
    if ! IFS= read -rs ans <&3; then die "输入已结束（EOF），已退出"; fi
    printf '\n'
    REPLY_VAL="$ans"
}

ask_yes() {     # $1=提示 $2=默认(y/n)，返回 0 表示是
    local prompt="$1" def="${2:-y}" ans="" suffix
    case "$def" in [yY]*) suffix="[Y/n]" ;; *) suffix="[y/N]" ;; esac
    if [ "$ASSUME_YES" = "1" ]; then
        case "$def" in [yY]*) return 0 ;; *) return 1 ;; esac
    fi
    printf '%s' "  ${CYAN}${prompt}${NC} ${suffix}: "
    if ! IFS= read -r ans <&3; then die "输入已结束（EOF），已退出"; fi
    [ -z "$ans" ] && ans="$def"
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

validate_email() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
}

# ============================ 配置向导 ============================
choose_provider() {
    local i=0 p arr=() ans
    msg "  ${BOLD}可用 DNS 服务商${NC}"
    for p in $PROVIDERS; do
        i=$((i + 1))
        arr[i]="$p"
        printf '    %2d) %-11s %s\n' "$i" "$p" "$(provider_label "$p")"
    done

    while :; do
        ask_value "请输入编号，或直接输入服务商名称" "1"
        ans="$REPLY_VAL"
        case "$ans" in
            ''|*[!0-9]*)
                case " $PROVIDERS " in
                    *" $ans "*) PROVIDER="$ans"; break ;;
                    *) err "未知服务商: $ans" ;;
                esac ;;
            *)
                if [ "$ans" -ge 1 ] 2>/dev/null && [ "$ans" -le "$i" ]; then
                    PROVIDER="${arr[$ans]}"
                    break
                fi
                err "编号超出范围（1-$i）" ;;
        esac
    done
    ok "DNS 服务商: $(provider_label "$PROVIDER")"
    info "$(provider_hint "$PROVIDER")"
}

# 切换服务商后清理其它服务商的旧凭据，避免失效密钥长期留在配置里
drop_other_creds() {
    local keep="$1" key _ _o n=0 other=""
    while IFS='|' read -r key _ _ _o; do
        other="$other $key"
    done < <(provider_creds "$keep")
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        case " $other " in *" $key "*) continue ;; esac
        if [ -n "$(get_var "$key")" ]; then
            set_var "$key" ""
            n=$((n + 1))
        fi
    done < <(cred_keys)
    [ "$n" -gt 0 ] && warn "已清理其它服务商的 $n 项旧凭据"
    return 0
}

# init: 只补缺失项；edit: 逐项确认是否保留
prompt_credentials() {
    local mode="$1" key label secret optional cur val hint_text
    [ "$PROVIDER" = "manual" ] && return 0

    while IFS='|' read -r key label secret optional; do
        [ -z "$key" ] && continue
        cur="$(get_var "$key")"
        if [ -n "$cur" ]; then
            if [ "$mode" = "edit" ]; then
                ask_yes "保留 ${key} 现有值" y && continue
            else
                continue
            fi
        fi
        while :; do
            hint_text=""
            [ "$optional" = "1" ] && hint_text="（可留空）"
            if [ "$secret" = "1" ]; then
                ask_secret "$label（${key}）${hint_text}"
            else
                ask_value "$label（${key}）${hint_text}" ""
            fi
            val="$REPLY_VAL"
            if [ -z "$val" ] && [ "$optional" != "1" ]; then
                err "${key} 不能为空"
                [ "$ASSUME_YES" = "1" ] && return 1
                continue
            fi
            set_var "$key" "$val"
            break
        done
    done < <(provider_creds "$PROVIDER")
    return 0
}

wizard() {
    local mode="${1:-init}" newdir old_provider
    eline
    if [ "$mode" = "edit" ]; then
        info "修改配置（直接回车保留当前值）"
    else
        info "首次运行配置向导（只需一次，之后自动复用）"
    fi
    eline

    if [ -z "$PROVIDER" ]; then
        choose_provider
    elif [ "$mode" = "edit" ]; then
        if ask_yes "是否更换 DNS 服务商（当前 $(provider_label "$PROVIDER")）" n; then
            old_provider="$PROVIDER"
            choose_provider
            [ "$old_provider" != "$PROVIDER" ] && drop_other_creds "$PROVIDER"
        fi
    fi

    prompt_credentials "$mode" || die "凭据填写失败"

    if [ -z "$EMAIL" ]; then
        while :; do
            ask_value "管理员邮箱（Let's Encrypt 到期提醒，填任意有效邮箱即可）" ""
            if validate_email "$REPLY_VAL"; then
                EMAIL="$REPLY_VAL"
                break
            fi
            err "邮箱格式无效: $REPLY_VAL"
            [ "$ASSUME_YES" = "1" ] && return 1
        done
    elif [ "$mode" = "edit" ]; then
        if ! ask_yes "保留现有邮箱 $EMAIL" y; then
            ask_value "新的管理员邮箱" "$EMAIL"
            validate_email "$REPLY_VAL" && EMAIL="$REPLY_VAL" || warn "邮箱格式无效，保持 $EMAIL"
        fi
    fi

    if [ -z "$CERT_DIR" ]; then
        local def_dir="/root/cert"
        [ "$(id -u)" -ne 0 ] && def_dir="$HOME/cert"
        while :; do
            ask_value "证书保存目录" "$def_dir"
            newdir="$REPLY_VAL"
            if mkdir -p "$newdir" 2>/dev/null; then
                CERT_DIR="$newdir"
                break
            fi
            err "无法创建目录: $newdir"
            [ "$ASSUME_YES" = "1" ] && return 1
        done
    elif [ "$mode" = "edit" ]; then
        ask_value "证书保存目录" "$CERT_DIR"
        newdir="$REPLY_VAL"
        if mkdir -p "$newdir" 2>/dev/null; then
            CERT_DIR="$newdir"
        else
            warn "目录不可写，保持原值 $CERT_DIR"
        fi
    fi

    if [ "$mode" = "edit" ] || [ -z "$RELOAD_CMD" ]; then
        ask_value "证书更新后执行的命令（如 nginx -s reload，可留空）" "${RELOAD_CMD:-}"
        RELOAD_CMD="$REPLY_VAL"
    fi

    if [ "$mode" = "edit" ]; then
        ask_value "密钥类型 ec-256/ec-384/2048/4096" "$KEYLEN"
        case "$REPLY_VAL" in
            ec-256|ec-384|2048|4096) KEYLEN="$REPLY_VAL" ;;
            *) warn "无效密钥类型，保持 $KEYLEN" ;;
        esac
        ask_value "CA letsencrypt/zerossl/sslcom/google" "$CA"
        case "$REPLY_VAL" in
            letsencrypt|zerossl|sslcom|google) CA="$REPLY_VAL" ;;
            *) warn "无效 CA，保持 $CA" ;;
        esac
    fi

    save_conf
    ok "配置已保存: $CONF_FILE"
}

# 交互式输入域名组
input_domains() {
    local main extras
    [ "$ASSUME_YES" = "1" ] && die "非交互模式请用 -d/--domain 指定域名组"

    eline
    info "域名配置（多个域名用空格或逗号分隔，第一个为主域名）"
    while :; do
        ask_value "主域名（例: example.com 或 *.example.com）" ""
        main="$REPLY_VAL"
        if [ -z "$main" ]; then
            err "主域名不能为空"
            continue
        fi
        if validate_domain "$main"; then
            break
        fi
        err "域名格式无效: $main（只支持 ASCII 域名，中文域名请先转 punycode）"
    done

    while :; do
        ask_value "其他域名（直接回车跳过）" ""
        extras="$REPLY_VAL"
        parse_domain_list "$main ${extras}" && break
    done

    GROUP="$PARSED_GROUP"
    ok "本次域名组: $GROUP"
}

# 选择本次操作的域名组
GROUP=""
choose_group() {
    load_groups

    if [ -n "$OPT_DOMAIN" ]; then
        parse_domain_list "$OPT_DOMAIN" || exit 1
        GROUP="$PARSED_GROUP"
        add_group "$GROUP"
        return 0
    fi

    if [ ${#DGROUPS[@]} -eq 0 ]; then
        input_domains || exit 1
        add_group "$GROUP"
        return 0
    fi

    if [ "$ASSUME_YES" = "1" ]; then
        GROUP="${DGROUPS[0]}"
        return 0
    fi

    msg "  已保存的域名组:"
    local i=1 g ans
    for g in "${DGROUPS[@]}"; do
        printf '    %s%d)%s %s\n' "$CYAN" "$i" "$NC" "$g"
        i=$((i + 1))
    done

    while :; do
        ask_value "选择编号；输入 n 新建；也可直接输入新域名" "1"
        ans="$REPLY_VAL"
        case "$ans" in
            ''|*[!0-9]*)
                case "$ans" in
                    n|N)
                        input_domains || exit 1
                        add_group "$GROUP"
                        return 0 ;;
                    *)
                        parse_domain_list "$ans" || continue
                        GROUP="$PARSED_GROUP"
                        add_group "$GROUP"
                        return 0 ;;
                esac ;;
            *)
                if [ "$ans" -ge 1 ] 2>/dev/null && [ "$ans" -le ${#DGROUPS[@]} ]; then
                    GROUP="${DGROUPS[$((ans - 1))]}"
                    return 0
                fi
                err "编号超出范围（1-${#DGROUPS[@]}）" ;;
        esac
    done
}

# ============================ 参数覆盖 / 凭据解析 ============================
apply_overrides() {
    local pair k v
    if [ -n "$OPT_PROVIDER" ]; then
        case " $PROVIDERS " in
            *" $OPT_PROVIDER "*) PROVIDER="$OPT_PROVIDER" ;;
            *) die "不支持的 DNS 服务商: $OPT_PROVIDER
   可选: $PROVIDERS" ;;
        esac
    fi
    if [ -n "$OPT_EMAIL" ]; then
        validate_email "$OPT_EMAIL" || die "邮箱格式无效: $OPT_EMAIL"
        EMAIL="$OPT_EMAIL"
    fi
    [ -n "$OPT_CERT_DIR" ] && CERT_DIR="$OPT_CERT_DIR"
    [ -n "$OPT_RELOAD_CMD" ] && RELOAD_CMD="$OPT_RELOAD_CMD"
    [ -n "$OPT_KEYLEN" ] && KEYLEN="$OPT_KEYLEN"
    [ -n "$OPT_CA" ] && CA="$OPT_CA"
    [ "$OPT_STAGING" = "1" ] && STAGING="1"

    for pair in ${CRED_PAIRS[@]+"${CRED_PAIRS[@]}"}; do
        k="${pair%%=*}"
        v="${pair#*=}"
        case " $(cred_keys | tr '\n' ' ') " in
            *" $k "*) set_var "$k" "$v" ;;
            *) die "未知凭据名: $k
   可用: $(cred_keys | tr '\n' ' ')" ;;
        esac
    done
}

# 环境变量兜底，便于 CI / 手工临时输入：
#   CF_Token=xxx ./acme_cert.sh -p cloudflare -d example.com -y
resolve_creds_from_env() {
    [ -z "$PROVIDER" ] && return 0
    [ "$PROVIDER" = "manual" ] && return 0
    local key _ _o envv
    while IFS='|' read -r key _ _ _o; do
        [ -z "$key" ] && continue
        if [ -z "$(get_var "$key")" ]; then
            envv="$(printenv "$key" 2>/dev/null || true)"
            [ -n "$envv" ] && set_var "$key" "$envv"
        fi
    done < <(provider_creds "$PROVIDER")
    return 0
}

# 校验配置完整性；首次运行进入向导
ensure_config() {
    local missing="" k optional

    if [ -n "$PROVIDER" ]; then
        case " $PROVIDERS " in
            *" $PROVIDER "*) : ;;
            *) die "不支持的 DNS 服务商: $PROVIDER" ;;
        esac
    fi
    [ -z "$PROVIDER" ] && missing="PROVIDER"

    if [ -n "$PROVIDER" ] && [ "$PROVIDER" != "manual" ]; then
        while IFS='|' read -r k _ _ optional; do
            [ -z "$k" ] && continue
            if [ "$optional" != "1" ] && [ -z "$(get_var "$k")" ]; then
                missing="${missing:+$missing, }$k"
            fi
        done < <(provider_creds "$PROVIDER")
    fi

    [ -z "$EMAIL" ] && missing="${missing:+$missing, }EMAIL"
    [ -z "$CERT_DIR" ] && missing="${missing:+$missing, }CERT_DIR"

    if [ -n "$missing" ]; then
        if [ "$ASSUME_YES" = "1" ]; then
            die "配置不完整，缺少: $missing
   非交互(-y)模式请用参数补齐，例如:
     $SCRIPT_NAME -p cloudflare --cred CF_Token=xxx -e you@example.com -o /root/cert -d example.com -y"
        fi
        warn "配置不完整，缺少: $missing"
        wizard init
        [ -z "$PROVIDER" ] && die "未选择 DNS 服务商"
        [ -z "$CERT_DIR" ] && die "未配置证书目录"
    fi

    [ -z "$KEYLEN" ] && KEYLEN="ec-256"
    [ -z "$CA" ] && CA="letsencrypt"

    # 首次运行（或本次用参数补齐了配置）时落盘，下次直接复用
    if [ ! -f "$CONF_FILE" ] \
        || [ -n "$OPT_PROVIDER$OPT_EMAIL$OPT_CERT_DIR$OPT_RELOAD_CMD$OPT_KEYLEN$OPT_CA" ] \
        || [ ${#CRED_PAIRS[@]} -gt 0 ]; then
        save_conf
        ok "配置已保存: $CONF_FILE"
    fi
    return 0
}

# ============================ 依赖与 acme.sh ============================
run_root() {
    if [ -n "$SUDO" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

install_packages() {
    local cmds=("$@") pkgs=() p mgr=""
    for p in apt-get dnf yum apk pacman opkg; do
        if command -v "$p" >/dev/null 2>&1; then
            mgr="$p"
            break
        fi
    done
    [ -z "$mgr" ] && return 1
    for p in "${cmds[@]}"; do
        case "${mgr}:${p}" in
            apt-get:crontab) pkgs+=(cron) ;;
            apt-get:dig) pkgs+=(dnsutils) ;;
            dnf:crontab|yum:crontab) pkgs+=(cronie) ;;
            dnf:dig|yum:dig) pkgs+=(bind-utils) ;;
            apk:crontab) pkgs+=(cronie) ;;
            apk:dig) pkgs+=(bind-tools) ;;
            pacman:crontab) pkgs+=(cronie) ;;
            pacman:dig) pkgs+=(bind) ;;
            opkg:openssl) pkgs+=(openssl-util) ;;
            opkg:crontab|opkg:dig) : ;;
            *) pkgs+=("$p") ;;
        esac
    done
    [ ${#pkgs[@]} -eq 0 ] && return 0
    info "安装软件包: ${pkgs[*]}"
    case "$mgr" in
        apt-get) run_root apt-get update -qq && run_root apt-get install -y "${pkgs[@]}" ;;
        dnf)     run_root dnf install -y "${pkgs[@]}" ;;
        yum)     run_root yum install -y "${pkgs[@]}" ;;
        apk)     run_root apk add --no-cache "${pkgs[@]}" ;;
        pacman)  run_root pacman -Sy --noconfirm "${pkgs[@]}" ;;
        opkg)    run_root opkg update && run_root opkg install "${pkgs[@]}" ;;
        *) return 1 ;;
    esac
}

check_dependencies() {
    info "检查系统依赖..."
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"

    local missing=() m
    for m in curl openssl; do
        command -v "$m" >/dev/null 2>&1 || missing+=("$m")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "缺少必需依赖: ${missing[*]}"
        if [ "$ASSUME_YES" = "1" ]; then
            install_packages "${missing[@]}" || die "依赖安装失败，请手动安装: ${missing[*]}"
        else
            if ask_yes "是否自动安装缺失依赖（${missing[*]}）" y; then
                install_packages "${missing[@]}" || die "依赖安装失败，请手动安装: ${missing[*]}"
            else
                die "缺少必需依赖: ${missing[*]}"
            fi
        fi
        for m in "${missing[@]}"; do
            command -v "$m" >/dev/null 2>&1 || die "依赖仍缺失: $m"
        done
        ok "依赖安装完成"
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        warn "未检测到 crontab，证书无法自动续期"
        if ask_yes "是否尝试安装 cron 服务" y; then
            if install_packages crontab; then
                ok "cron 服务已安装"
            else
                warn "安装失败，请手动安装 cron/cronie 后重新运行"
            fi
        fi
    fi

    command -v socat >/dev/null 2>&1 || info "未检测到 socat（DNS 验证不需要，仅 standalone 模式需要）"
    ok "依赖检查完成"
}

detect_acme() {
    local cand="" d
    if [ -n "${ACME_SH:-}" ] && [ -x "$ACME_SH" ]; then
        cand="$ACME_SH"
    elif command -v acme.sh >/dev/null 2>&1; then
        cand="$(command -v acme.sh)"
    elif [ -x "$HOME/.acme.sh/acme.sh" ]; then
        cand="$HOME/.acme.sh/acme.sh"
    elif [ -x /usr/local/bin/acme.sh ]; then
        cand=/usr/local/bin/acme.sh
    elif [ -x /usr/share/acme.sh/acme.sh ]; then
        cand=/usr/share/acme.sh/acme.sh
    fi

    if [ -z "$cand" ]; then
        ACME=""
        ACME_HOME=""
        return 1
    fi
    ACME="$cand"
    d="$(dirname "$ACME")"
    if [ -d "$d/dnsapi" ]; then
        ACME_HOME="$d"
    elif [ -d "$d/../share/acme.sh/dnsapi" ]; then
        ACME_HOME="$(cd "$d/../share/acme.sh" && pwd)"
    elif [ -d /usr/share/acme.sh/dnsapi ]; then
        ACME_HOME=/usr/share/acme.sh
    elif [ -d /usr/local/share/acme.sh/dnsapi ]; then
        ACME_HOME=/usr/local/share/acme.sh
    else
        ACME_HOME="$d"
    fi
    return 0
}

install_acme() {
    local mode="${1:-}"

    if detect_acme; then
        if [ "$mode" = "force" ]; then
            info "升级 acme.sh..."
            if "$ACME" --upgrade >/dev/null 2>&1; then
                ok "acme.sh 已升级: $("$ACME" --version 2>/dev/null | tail -1)"
            else
                warn "acme.sh 升级失败（继续使用当前版本）"
            fi
        else
            ok "acme.sh 已安装: $ACME ($("$ACME" --version 2>/dev/null | tail -1))"
        fi
        return 0
    fi

    [ "$mode" = "force" ] && die "未检测到 acme.sh，无法升级"

    info "安装 acme.sh..."
    local installed=""
    # 国内优先 Gitee 镜像，失败回退官方源
    if curl -fsSL --connect-timeout 8 --max-time 90 \
        "https://gitee.com/neilpang/acme.sh/raw/master/install.sh" | sh -s email="$EMAIL" >/dev/null 2>&1; then
        installed=1
    fi
    if [ -z "$installed" ]; then
        warn "Gitee 镜像安装失败，改用官方源..."
        if curl -fsSL --connect-timeout 10 --max-time 90 https://get.acme.sh | sh -s email="$EMAIL" >/dev/null 2>&1; then
            installed=1
        fi
    fi

    detect_acme || die "acme.sh 安装失败，请手动安装后重试：$REPO_URL"
    ok "acme.sh 安装成功: $ACME"
}

check_dnsapi() {
    [ "$PROVIDER" = "manual" ] && return 0
    local name
    name="$(provider_dnsapi "$PROVIDER")"
    if [ ! -f "$ACME_HOME/dnsapi/$name.sh" ]; then
        err "当前 acme.sh 未包含 $name（$ACME_HOME/dnsapi/$name.sh）"
        err "请先执行: $SCRIPT_NAME --update-acme"
        return 1
    fi
    return 0
}

# ============================ 签发 / 安装 / 续期 ============================
export_creds() {
    [ "$PROVIDER" = "manual" ] && return 0
    local key _ _o v
    while IFS='|' read -r key _ _ _o; do
        [ -z "$key" ] && continue
        v="$(get_var "$key")"
        [ -n "$v" ] && export "$key=$v"
    done < <(provider_creds "$PROVIDER")
}

acme_server() {
    if [ "$STAGING" = "1" ]; then
        printf 'letsencrypt_test'
    else
        printf '%s' "$CA"
    fi
}

issue_group() {
    local group="$1" main="" w rc
    for w in $group; do
        [ -z "$main" ] && main="$w"
    done

    export_creds

    local args=(--issue --server "$(acme_server)")
    if [ "$PROVIDER" = "manual" ]; then
        args+=(--dns --yes-I-know-dns-manual-mode-enough-go-ahead-please)
    else
        args+=(--dns "$(provider_dnsapi "$PROVIDER")")
    fi
    for w in $group; do
        args+=(-d "$w")
    done
    args+=(--keylength "$KEYLEN")
    [ "$FORCE" = "1" ] && args+=(--force)

    if [ "$DRY_RUN" = "1" ]; then
        info "将执行: $ACME ${args[*]}"
        return 0
    fi

    info "向 $(acme_server) 申请证书: $group"
    "$ACME" "${args[@]}"
    rc=$?
    case "$rc" in
        0) ok "证书申请成功: $main" ;;
        2) info "证书未到期或域名未变化，本次跳过重新签发（需要强制请加 -f）" ;;
        *) return 1 ;;
    esac
    return 0
}

domain_slug() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/^\*\./wildcard./; s/\*/wildcard/g'
}

cert_dir_of() {
    printf '%s/%s' "${CERT_DIR%/}" "$(domain_slug "$(group_main "$1")")"
}

install_cert_group() {
    local group="$1" main cdir
    main="$(group_main "$group")"
    cdir="$(cert_dir_of "$group")"

    if [ "$DRY_RUN" = "1" ]; then
        info "将安装证书到: $cdir"
        return 0
    fi

    mkdir -p "$cdir" 2>/dev/null || { err "无法创建证书目录: $cdir"; return 1; }
    chmod 700 "$cdir" 2>/dev/null || true

    local args=(--install-cert -d "$main"
        --key-file "$cdir/key.pem"
        --cert-file "$cdir/cert.pem"
        --ca-file "$cdir/ca.pem"
        --fullchain-file "$cdir/fullchain.pem")
    case "$KEYLEN" in ec-*) args+=(--ecc) ;; esac
    [ -n "$RELOAD_CMD" ] && args+=(--reloadcmd "$RELOAD_CMD")

    if ! "$ACME" "${args[@]}"; then
        err "证书安装失败: $main"
        return 1
    fi
    chmod 600 "$cdir"/*.pem 2>/dev/null || true
    ok "证书已安装: $cdir"
}

renew_group() {
    local group="$1" main args rc
    main="$(group_main "$group")"
    export_creds
    args=(--renew -d "$main")
    case "$KEYLEN" in ec-*) args+=(--ecc) ;; esac
    [ "$FORCE" = "1" ] && args+=(--force)
    [ "$PROVIDER" = "manual" ] && args+=(--yes-I-know-dns-manual-mode-enough-go-ahead-please)

    if [ "$DRY_RUN" = "1" ]; then
        info "将执行: $ACME ${args[*]}"
        return 0
    fi

    "$ACME" "${args[@]}"
    rc=$?
    case "$rc" in
        0) ok "续期完成: $main" ;;
        2) info "未到续期时间，跳过: $main" ;;
        *) err "续期失败: $main"; return 1 ;;
    esac
    return 0
}

ensure_cronjob() {
    if [ "$PROVIDER" = "manual" ]; then
        warn "手动 DNS 模式无法自动续期，到期前请重新执行本脚本"
        return 0
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        warn "未找到 crontab，自动续期未设置（可用 systemd timer 调用: $ACME --cron）"
        return 0
    fi
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        ok "acme.sh 自动续期任务已存在"
        return 0
    fi
    if "$ACME" --install-cronjob >/dev/null 2>&1; then
        ok "已添加 acme.sh 自动续期任务（每日检查）"
    else
        warn "自动续期任务添加失败，可手动执行: $ACME --install-cronjob"
    fi
}

# ============================ 概览 / 自检 ============================
cert_expiry() {
    local f="$1" end epoch now days
    if [ ! -f "$f" ]; then
        printf '未安装'
        return 0
    fi
    end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -z "$end" ] && { printf '无法读取'; return 0; }
    epoch="$(date -d "$end" +%s 2>/dev/null || true)"
    if [ -n "$epoch" ]; then
        now="$(date +%s)"
        days=$(((epoch - now) / 86400))
        if [ "$days" -lt 0 ]; then
            printf '%s（已过期）' "$end"
        elif [ "$days" -le 15 ]; then
            printf '%s（剩余 %d 天 ⚠）' "$end" "$days"
        else
            printf '%s（剩余 %d 天）' "$end" "$days"
        fi
    else
        printf '%s' "$end"
    fi
}

show_overview() {
    local mode="${1:-list}" i g main cdir exp
    load_groups
    eline
    printf '  %s\n' "${BOLD}acme_cert.sh${NC} v$SCRIPT_VERSION"
    eline
    kv "DNS 服务商" "$([ -n "$PROVIDER" ] && provider_label "$PROVIDER" || echo '未配置')"
    kv "管理员邮箱" "${EMAIL:-未配置}"
    kv "证书目录" "${CERT_DIR:-未配置}"
    kv "密钥类型" "$KEYLEN"
    kv "CA" "$CA$([ "$STAGING" = "1" ] && echo '（测试环境）')"
    kv "更新后命令" "${RELOAD_CMD:-未设置}"
    kv "配置文件" "$CONF_FILE"
    if [ -f "$CONF_FILE" ]; then
        kv "文件权限" "$(stat -c '%a' "$CONF_FILE" 2>/dev/null || stat -f '%Lp' "$CONF_FILE" 2>/dev/null)"
    fi

    eline
    if [ ${#DGROUPS[@]} -eq 0 ]; then
        warn "还没有配置任何域名组"
    else
        printf '  %-3s %-34s %-30s %s\n' "#" "域名组" "证书目录" "证书到期"
        i=1
        for g in "${DGROUPS[@]}"; do
            main="$(group_main "$g")"
            cdir="$(cert_dir_of "$g")"
            exp="$(cert_expiry "$cdir/fullchain.pem")"
            local disp="$cdir"
            # shellcheck disable=SC2088  # 这里就是要输出字面量 ~
            case "$disp" in "$HOME"/*) disp="~/${disp#"$HOME"/}" ;; esac
            printf '  %-3s %-34s %-30s %s\n' "$i" "$g" "$disp" "$exp"
            i=$((i + 1))
        done
    fi
    eline

    if [ "$mode" = "status" ]; then
        if detect_acme; then
            info "acme.sh 证书清单（$ACME）："
            "$ACME" --list 2>/dev/null | sed 's/^/    /'
            msg "    Main_Domain = 证书主名，Renew = 下次自动续期时间"
        else
            warn "未检测到 acme.sh"
        fi
    fi
}

do_check() {
    local i=0 g main cdir c key _ _o state name
    eline
    info "环境自检"
    eline
    kv "系统" "$(uname -srm 2>/dev/null)"
    kv "Bash" "${BASH_VERSION}"
    kv "运行用户" "$(id -un) (uid=$(id -u))"
    kv "配置目录" "$CONF_DIR$([ -d "$CONF_DIR" ] && echo '（存在）' || echo '（不存在）')"

    eline
    printf '  %s\n' "${BOLD}依赖${NC}"
    for c in curl openssl crontab socat dig; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '    %-10s %s\n' "$c" "✓ $(command -v "$c")"
        else
            case "$c" in
                socat)   printf '    %-10s %s\n' "$c" "- 未安装（仅 standalone 模式需要）" ;;
                crontab) printf '    %-10s %s\n' "$c" "✗ 未安装（无法自动续期）" ;;
                dig)     printf '    %-10s %s\n' "$c" "- 未安装（可选）" ;;
                *)       printf '    %-10s %s\n' "$c" "✗ 未安装（必需）" ;;
            esac
        fi
    done

    eline
    printf '  %s\n' "${BOLD}acme.sh${NC}"
    if detect_acme; then
        kv4 "路径" "$ACME"
        kv4 "版本" "$("$ACME" --version 2>/dev/null | tail -1)"
        kv4 "HOME" "$ACME_HOME"
        if [ "$PROVIDER" != "manual" ] && [ -n "$PROVIDER" ]; then
            name="$(provider_dnsapi "$PROVIDER")"
            if [ -f "$ACME_HOME/dnsapi/$name.sh" ]; then
                kv4 "dnsapi" "✓ $name"
            else
                kv4 "dnsapi" "✗ 缺少 $name（请 --update-acme）"
            fi
        fi
    else
        printf '    %s\n' "✗ 未安装（首次签发时会自动安装）"
    fi

    eline
    printf '  %s\n' "${BOLD}配置${NC}"
    kv4 "服务商" "${PROVIDER:-未配置}"
    kv4 "邮箱" "${EMAIL:-未配置}"
    kv4 "证书目录" "${CERT_DIR:-未配置}"
    if [ -n "$PROVIDER" ] && [ "$PROVIDER" != "manual" ]; then
        while IFS='|' read -r key _ _ _o; do
            [ -z "$key" ] && continue
            if [ -n "$(get_var "$key")" ]; then state="✓ 已设置"; else state="- 未设置"; fi
            [ "$_o" = "1" ] && state="$state（可选）"
            printf '    %-22s %s\n' "$key" "$state"
        done < <(provider_creds "$PROVIDER")
    fi

    eline
    printf '  %s\n' "${BOLD}域名组与证书${NC}"
    load_groups
    if [ ${#DGROUPS[@]} -eq 0 ]; then
        printf '    %s\n' "（无）"
    else
        i=1
        for g in "${DGROUPS[@]}"; do
            main="$(group_main "$g")"
            cdir="$(cert_dir_of "$g")"
            printf '    %d) %s\n' "$i" "$g"
            printf '       %s\n' "全链证书: $cdir/fullchain.pem → $(cert_expiry "$cdir/fullchain.pem")"
            if [ -f "$cdir/key.pem" ]; then
                printf '       %s\n' "私钥: $cdir/key.pem ✓"
            else
                printf '       %s\n' "私钥: $cdir/key.pem ✗ 缺失"
            fi
            i=$((i + 1))
        done
    fi

    eline
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "acme.sh"; then
            printf '  %s %s\n' "${GREEN}✓${NC}" "已存在 acme.sh 续期计划任务"
        else
            printf '  %s %s\n' "${YELLOW}!${NC}" "未发现 acme.sh 续期计划任务（签发时会自动添加）"
        fi
    fi
    eline
}

# ============================ 清理 ============================
clear_key() {
    set_var "$1" ""
    save_conf
}

clean_domains() {
    if [ -f "$DOMAINS_FILE" ]; then
        rm -f "$DOMAINS_FILE" && ok "域名组已清除"
    else
        warn "没有域名组配置文件"
    fi
}

clean_email() {
    if [ -n "$EMAIL" ]; then
        clear_key EMAIL
        ok "邮箱配置已清除"
    else
        warn "没有邮箱配置"
    fi
}

clean_auth() {
    if [ -z "$PROVIDER" ]; then
        warn "没有 DNS 服务商配置"
        return 0
    fi
    local key _ _o n=0
    while IFS='|' read -r key _ _ _o; do
        [ -z "$key" ] && continue
        if [ -n "$(get_var "$key")" ]; then
            set_var "$key" ""
            n=$((n + 1))
        fi
    done < <(provider_creds "$PROVIDER")
    save_conf
    if [ "$n" -gt 0 ]; then
        ok "已清除 $n 项 DNS 凭据（服务商仍为 $(provider_label "$PROVIDER")）"
    else
        warn "没有已保存的凭据"
    fi
}

clean_certdir() {
    if [ -n "$CERT_DIR" ]; then
        clear_key CERT_DIR
        ok "证书目录配置已清除（已生成的证书文件未删除）"
    else
        warn "没有证书目录配置"
    fi
}

clean_all() {
    if [ "$ASSUME_YES" != "1" ] && ! ask_yes "将删除全部配置（凭据/邮箱/域名组/证书目录），已生成的证书保留，确认继续" n; then
        info "已取消"
        return 0
    fi
    rm -f "$CONF_FILE" "$DOMAINS_FILE"
    ok "所有配置已清除（acme.sh 自身的证书与账号信息未删除）"
}

interactive_clean() {
    local choice
    while :; do
        eline
        msg "  ${BOLD}清理配置${NC}  （$CONF_DIR）"
        msg "    1) 清除域名组"
        msg "    2) 清除邮箱"
        msg "    3) 清除 DNS 服务商凭据"
        msg "    4) 清除证书目录设置"
        msg "    5) 清除全部配置"
        msg "    6) 返回"
        ask_value "请选择(1-6)" "6"
        choice="$REPLY_VAL"
        case "$choice" in
            1) clean_domains ;;
            2) clean_email ;;
            3) clean_auth ;;
            4) clean_certdir ;;
            5) clean_all ;;
            6|q|Q) return 0 ;;
            *) err "无效选项: $choice" ;;
        esac
    done
}

# ============================ 自我更新 ============================
fetch_remote_version() {  # 两个源都查，取较大的版本（镜像同步有延迟）
    local a="" b=""
    a="$(curl -fsSL --connect-timeout 8 --max-time 20 "$MIRROR_URL" 2>/dev/null \
        | grep -m1 '^SCRIPT_VERSION=' | sed 's/[^0-9.]//g')"
    b="$(curl -fsSL --connect-timeout 8 --max-time 20 "$SCRIPT_URL" 2>/dev/null \
        | grep -m1 '^SCRIPT_VERSION=' | sed 's/[^0-9.]//g')"
    if [ -n "$a" ] && [ -n "$b" ]; then
        if version_gt "$b" "$a"; then printf '%s' "$b"; else printf '%s' "$a"; fi
    else
        printf '%s' "${a:-$b}"
    fi
}

version_gt() {  # $1 > $2 时返回 0
    local a="$1" b="$2" i x y
    local -a A B
    IFS=. read -ra A <<<"$a"
    IFS=. read -ra B <<<"$b"
    for ((i = 0; i < ${#A[@]} || i < ${#B[@]}; i++)); do
        x="${A[i]:-0}"
        y="${B[i]:-0}"
        x="${x//[!0-9]/}"
        y="${y//[!0-9]/}"
        [ -z "$x" ] && x=0
        [ -z "$y" ] && y=0
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

valid_script() {  # 体积 + shebang + 版本行 + 语法，四道都过才算可用正文
    local f="$1" sz
    [ -s "$f" ] || return 1
    sz=$(wc -c <"$f" 2>/dev/null || echo 0)
    [ "$sz" -ge 20000 ] || return 1
    head -1 "$f" | grep -q '^#!.*bash' || return 1
    grep -q '^SCRIPT_VERSION=' "$f" || return 1
    bash -n "$f" 2>/dev/null
}

update_script() {
    if [ ! -f "$0" ] || [ ! -w "$0" ]; then
        die "当前不是以文件方式运行或文件不可写，无法自我更新。请先把脚本保存到本地再执行 --update"
    fi

    local tmp alt source="" rv="" arv
    tmp="$(mktemp 2>/dev/null)" || die "无法创建临时文件"

    # 先试镜像（境内快）；镜像版本不高于本地时，再取官方源，避免同步延迟把新版判成"已是最新"
    if curl -fsSL --connect-timeout 8 --max-time 30 "$MIRROR_URL" -o "$tmp" 2>/dev/null && valid_script "$tmp"; then
        source="Gitee 镜像"
        rv="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | sed 's/[^0-9.]//g')"
    else
        : >"$tmp"
    fi

    if [ -z "$rv" ] || ! version_gt "$rv" "$SCRIPT_VERSION"; then
        alt="$(mktemp 2>/dev/null)" || alt=""
        if [ -n "$alt" ] && curl -fsSL --connect-timeout 8 --max-time 30 "$SCRIPT_URL" -o "$alt" 2>/dev/null && valid_script "$alt"; then
            arv="$(grep -m1 '^SCRIPT_VERSION=' "$alt" | sed 's/[^0-9.]//g')"
            if [ -z "$rv" ] || version_gt "$arv" "$rv"; then
                cat "$alt" >"$tmp"
                rv="$arv"
                source="GitHub"
            fi
        fi
        [ -n "$alt" ] && rm -f "$alt"
    fi

    if [ -z "$rv" ] || ! [ -s "$tmp" ]; then
        rm -f "$tmp"
        die "脚本下载失败（镜像与官方源均不可用，请检查网络）"
    fi
    if ! version_gt "$rv" "$SCRIPT_VERSION"; then
        rm -f "$tmp"
        ok "当前已是最新版本 v$SCRIPT_VERSION"
        return 0
    fi

    cp -p "$0" "$0.bak" 2>/dev/null || true
    if ! cat "$tmp" >"$0"; then
        rm -f "$tmp"
        die "写入脚本失败: $0"
    fi
    chmod +x "$0" 2>/dev/null || true
    rm -f "$tmp"
    ok "已从 $source 更新到 v$rv（旧版本备份为 $0.bak）"
    msg "  请重新运行: $SCRIPT_NAME"
}

check_update() {
    [ "$NO_UPDATE_CHECK" = "1" ] && return 0
    [ -f "$0" ] || return 0
    [ ! -w "$0" ] && return 0

    local cache="$CONF_DIR/.update_check" now ts rv
    now="$(date +%s)"
    if [ -f "$cache" ]; then
        ts="$(cut -d' ' -f1 "$cache" 2>/dev/null)"
        case "$ts" in
            ''|*[!0-9]*) : ;;
            *) [ $((now - ts)) -lt 86400 ] && return 0 ;;
        esac
    fi

    rv="$(fetch_remote_version)"
    [ -z "$rv" ] && return 0
    mkdir -p "$CONF_DIR" 2>/dev/null && printf '%s %s\n' "$now" "$rv" >"$cache" 2>/dev/null

    if version_gt "$rv" "$SCRIPT_VERSION"; then
        warn "发现新版本 v$rv（当前 v$SCRIPT_VERSION）"
        if ask_yes "是否立即更新脚本" y; then
            update_script
            exit 0
        fi
    fi
    return 0
}

# ============================ 帮助 ============================
show_help() {
    cat <<EOF

${BOLD}${SCRIPT_NAME}${NC} v${SCRIPT_VERSION} —— ACME 证书申请 / 安装 / 自动续期

${BOLD}用法${NC}
  ${SCRIPT_NAME}                     交互式签发（首次运行自动进入配置向导）
  ${SCRIPT_NAME} [命令] [选项]

${BOLD}命令${NC}
  --issue             申请 / 安装证书（默认命令）
  --list              查看配置、域名组、已装证书的到期时间
  --status            同 --list，并显示 acme.sh 内部证书清单
  --renew             续期所有域名组（默认只续快到期的，-f 强制续期）
  --config            重新进入配置向导（修改服务商/凭据/邮箱/目录/密钥/CA）
  --check             环境自检（依赖、acme.sh、dnsapi、配置、证书到期）
  --update-acme       升级 acme.sh 客户端
  --update            更新本脚本
  --clean             交互式清理配置
  --clean-all         清除全部配置（-y 时不再确认）
  --clean-auth        仅清除 DNS 服务商凭据（--clean-token 为别名）
  --clean-domains     仅清除域名组
  --clean-email       仅清除邮箱
  --clean-certdir     仅清除证书目录设置
  -h, --help          显示本帮助
  -V, --version       显示版本号

${BOLD}选项${NC}
  -d, --domain LIST     域名组，逗号或空格分隔，第一个为主域名
                        例: -d "example.com,*.example.com"
  -p, --provider NAME   DNS 服务商:
                        cloudflare aliyun dnspod tencent huaweicloud aws
                        digitalocean vultr linode godaddy namecheap namesilo
                        cloudns porkbun manual
  -e, --email ADDR      管理员邮箱
  -o, --cert-dir DIR    证书输出目录（默认 /root/cert，非 root 为 \$HOME/cert）
  -k, --keylength LEN   密钥类型: ec-256(默认) / ec-384 / 2048 / 4096
  -c, --reload-cmd CMD  证书更新后执行的命令，如 "nginx -s reload"
      --ca NAME         CA: letsencrypt(默认) / zerossl / sslcom / google
  -s, --staging         使用 Let's Encrypt 测试环境（不计入限额，证书不受信任）
  -f, --force           强制重新签发（会消耗 Let's Encrypt 限额，慎用）
  -y, --yes             非交互模式：全部使用参数与已保存配置，缺项直接报错
      --cred KEY=VALUE  指定 DNS 凭据，可重复:
                          --cred Ali_Key=xxx --cred Ali_Secret=yyy
      --no-update-check 跳过脚本版本检查
      --dry-run         只打印将要执行的 acme.sh 命令，不实际执行

${BOLD}配置文件${NC}
  $CONF_FILE  （权限 600，含凭据，请勿分享）
  $DOMAINS_FILE  （每行一个域名组，主域名在前，重复的不会重复写入）

${BOLD}示例${NC}
  # 首次运行：交互填写服务商、凭据、邮箱、证书目录、续期命令与域名
  ${SCRIPT_NAME}

  # 阿里云 DNS 签发通配符证书（凭据用参数传入）
  ${SCRIPT_NAME} -p aliyun -d "example.com,*.example.com" \\
      --cred Ali_Key=xxx --cred Ali_Secret=yyy -e me@example.com -y

  # Cloudflare Token（环境变量）非交互签发
  CF_Token=xxxx ${SCRIPT_NAME} -p cloudflare -d "example.com" -e me@example.com -y

  # 先在测试环境验证流程，确认无误后去掉 -s
  ${SCRIPT_NAME} -d "example.com" -s

${BOLD}说明${NC}
  · 凭据只在申请/续期时通过环境变量传给 acme.sh，脚本另存于 600 权限配置文件中
  · 证书目录结构: <证书目录>/<主域名>/{cert.pem,key.pem,ca.pem,fullchain.pem}
  · 自动续期由 acme.sh 的计划任务完成，续期后按 --reload-cmd 执行命令
  · manual（手动 DNS）模式无法自动续期，到期需人工重新签发

EOF
}

# ============================ 参数解析 ============================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
        esac
        case "$1" in
            -h|--help|help)       ACTION="help" ;;
            -V|--version|version) ACTION="version" ;;
            --issue|issue)        ACTION="issue" ;;
            --list|list)          ACTION="list" ;;
            --status|status)      ACTION="status" ;;
            --renew|renew)        ACTION="renew" ;;
            --config|config)      ACTION="config" ;;
            --check|check)        ACTION="check" ;;
            --update-acme)        ACTION="update-acme" ;;
            --update)             ACTION="update" ;;
            --clean)              ACTION="clean" ;;
            --clean-all)          ACTION="clean-all" ;;
            --clean-auth|--clean-token) ACTION="clean-auth" ;;
            --clean-domains)      ACTION="clean-domains" ;;
            --clean-email)        ACTION="clean-email" ;;
            --clean-certdir)      ACTION="clean-certdir" ;;

            -d|--domain)
                [ $# -ge 2 ] || die "$1 缺少参数"
                OPT_DOMAIN="$2"
                shift ;;
            -p|--provider)
                [ $# -ge 2 ] || die "$1 缺少参数"
                OPT_PROVIDER="$2"
                shift ;;
            -e|--email)
                [ $# -ge 2 ] || die "$1 缺少参数"
                OPT_EMAIL="$2"
                shift ;;
            -o|--cert-dir)
                [ $# -ge 2 ] || die "$1 缺少参数"
                OPT_CERT_DIR="$2"
                shift ;;
            -k|--keylength)
                [ $# -ge 2 ] || die "$1 缺少参数"
                case "$2" in
                    ec-256|ec-384|2048|4096) OPT_KEYLEN="$2" ;;
                    *) die "不支持的密钥类型: $2（可选 ec-256/ec-384/2048/4096）" ;;
                esac
                shift ;;
            -c|--reload-cmd)
                [ $# -ge 2 ] || die "$1 缺少参数"
                OPT_RELOAD_CMD="$2"
                shift ;;
            --ca)
                [ $# -ge 2 ] || die "$1 缺少参数"
                case "$2" in
                    letsencrypt|zerossl|sslcom|google) OPT_CA="$2" ;;
                    *) die "不支持的 CA: $2" ;;
                esac
                shift ;;
            -s|--staging)      OPT_STAGING="1" ;;
            -f|--force)        FORCE="1" ;;
            -y|--yes)          ASSUME_YES="1" ;;
            --no-update-check) NO_UPDATE_CHECK="1" ;;
            --dry-run)         DRY_RUN="1" ;;
            --cred)
                [ $# -ge 2 ] || die "$1 缺少参数（格式 KEY=VALUE）"
                CRED_PAIRS+=("$2")
                shift ;;
            *)
                err "未知参数: $1"
                msg "  使用 $SCRIPT_NAME --help 查看用法"
                exit 2 ;;
        esac
        shift
    done
}

# ============================ 主流程 ============================
show_summary() {
    local group="$1" cdir
    cdir="$(cert_dir_of "$group")"
    eline
    kv "DNS 服务商" "$(provider_label "$PROVIDER")"
    kv "域名组" "$group"
    kv "证书目录" "$cdir"
    kv "密钥类型" "$KEYLEN"
    kv "ACME 服务" "$(acme_server)$([ "$STAGING" = "1" ] && echo '（测试环境）')"
    kv "更新后命令" "${RELOAD_CMD:-未设置}"
    kv "管理员邮箱" "$EMAIL"
    eline
}

print_result() {
    local group="$1" cdir
    cdir="$(cert_dir_of "$group")"
    eline
    ok "操作完成"
    msg "  域名组   : $group"
    msg "  全链证书 : $cdir/fullchain.pem"
    msg "  证书     : $cdir/cert.pem"
    msg "  私钥     : $cdir/key.pem"
    msg "  CA 链    : $cdir/ca.pem"
    msg "  到期时间 : $(cert_expiry "$cdir/fullchain.pem")"
    eline
    msg "  查看配置 : $SCRIPT_NAME --list"
    msg "  环境自检 : $SCRIPT_NAME --check"
    msg "  手动续期 : $SCRIPT_NAME --renew"
}

run_issue() {
    ensure_config
    choose_group
    check_update
    check_dependencies
    install_acme
    check_dnsapi || exit 1

    show_summary "$GROUP"
    if [ "$ASSUME_YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
        if ! ask_yes "确认开始申请" y; then
            info "已取消"
            exit 0
        fi
    fi

    issue_group "$GROUP" || die "证书申请失败，请按上方 acme.sh 输出排查（可先用 --staging 在测试环境验证）"
    install_cert_group "$GROUP" || die "证书安装失败"
    if [ "$DRY_RUN" = "1" ]; then
        info "预览结束：以上命令均未实际执行"
        exit 0
    fi
    ensure_cronjob
    print_result "$GROUP"
}

run_renew() {
    ensure_config
    detect_acme || die "未检测到 acme.sh，请先执行一次签发"
    check_dnsapi || exit 1
    load_groups
    [ ${#DGROUPS[@]} -eq 0 ] && die "还没有配置任何域名组"

    local g failed=0
    for g in "${DGROUPS[@]}"; do
        msg ""
        info "处理域名组: $g"
        renew_group "$g" || failed=1
    done
    if [ "$failed" -eq 1 ]; then
        warn "部分域名组续期失败，请查看上方输出"
        exit 1
    fi
    ok "全部域名组处理完成"
}

main() {
    parse_args "$@"

    case "$ACTION" in
        help)    show_help; exit 0 ;;
        version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    esac

    mkdir -p "$CONF_DIR" 2>/dev/null || die "无法创建配置目录: $CONF_DIR"
    chmod 700 "$CONF_DIR" 2>/dev/null || true

    migrate_legacy
    load_conf
    apply_overrides
    resolve_creds_from_env

    case "$ACTION" in
        list|status)   show_overview "$ACTION"; exit 0 ;;
        check)         do_check; exit 0 ;;
        clean)         interactive_clean; exit 0 ;;
        clean-all)     clean_all; exit 0 ;;
        clean-auth)    clean_auth; exit 0 ;;
        clean-domains) clean_domains; exit 0 ;;
        clean-email)   clean_email; exit 0 ;;
        clean-certdir) clean_certdir; exit 0 ;;
        config)        wizard edit; exit 0 ;;
        update)        update_script; exit 0 ;;
        update-acme)   install_acme force; exit 0 ;;
        renew)         run_renew ;;
        issue)         run_issue ;;
        *)             die "未知命令: $ACTION" ;;
    esac
}

main "$@"
