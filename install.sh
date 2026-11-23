#!/usr/bin/env bash
#
# install.sh —— acme_cert.sh 安装引导脚本
#
#   curl -fsSL https://acme.kuwi.net/install.sh | bash
#
# 它自己不需要保存：探速选出最快的下载源 → 拉取 acme_cert.sh → 校验正文 →
# 落盘到当前目录（或 --dir 指定目录）→ chmod +x → 立即执行。
#
# 为什么要引导脚本而不是直接 curl -O acme_cert.sh：
#   · 正文只有校验通过才会落盘，CDN 返回 5xx/错误页不会变成可执行脚本
#   · GitHub 慢或被墙时自动切 Gitee，国内/海外都不用记两条命令
#   · 文件名、可执行位、备份都由脚本处理，用户不用记 -O 的规则
#
# 用法:
#   curl -fsSL https://acme.kuwi.net/install.sh | bash
#   curl -fsSL https://acme.kuwi.net/install.sh | bash -s -- --no-run
#   curl -fsSL https://acme.kuwi.net/install.sh | bash -s -- -d /usr/local/bin
#   curl -fsSL https://acme.kuwi.net/install.sh | bash -s -- -- --dry-run
#
# 仓库: https://github.com/KuwiNet/acme-cf-cert

INSTALL_VERSION="1.0.2"
TARGET_NAME="acme_cert.sh"
MIN_SIZE=15000

set -o pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m' DIM=$'\033[2m' NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' DIM='' NC=''
fi
info() { printf '%s\n' "${BLUE}[*]${NC} $*"; }
ok()   { printf '%s\n' "${GREEN}[✓]${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
die()  { printf '%s\n' "${RED}[✗]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
$TARGET_NAME 安装引导 v$INSTALL_VERSION

用法:
  install.sh [选项] [-- 传给 acme_cert.sh 的参数]

选项:
  -d, --dir DIR        保存目录（默认当前目录）
  -n, --no-run         只下载保存，不立即执行
  -r, --run            即使没有交互终端也执行（默认会自动跳过）
  -m, --mirror MODE    下载源：auto（默认，测速选择）| github | gitee | cdn（需 ACME_SRC_CDN）
  -f, --force          忽略测速结果，强行重试全部源直到成功
      --min-version V  拒绝低于该版本的正文（默认 2.0.0）
  -h, --help           显示帮助
  -V, --version        显示引导脚本版本

示例:
  curl -fsSL https://acme.kuwi.net/install.sh | bash
  curl -fsSL https://acme.kuwi.net/install.sh | bash -s -- --no-run -d /usr/local/bin
  curl -fsSL https://acme.kuwi.net/install.sh | bash -s -- -- -p cloudflare -e me@x.com
EOF
}

DEST_DIR=""
RUN=1
RUN_FORCE=0
MIRROR="auto"
FORCE=0
MIN_VERSION="2.0.0"
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)          DEST_DIR="${2:-}"; shift 2 ;;
        --dir=*)           DEST_DIR="${1#*=}"; shift ;;
        -n|--no-run)       RUN=0; shift ;;
        -r|--run)          RUN=1; RUN_FORCE=1; shift ;;
        -m|--mirror)       MIRROR="${2:-auto}"; shift 2 ;;
        --mirror=*)        MIRROR="${1#*=}"; shift ;;
        -f|--force)        FORCE=1; shift ;;
        --min-version)     MIN_VERSION="${2:-}"; shift 2 ;;
        --min-version=*)   MIN_VERSION="${1#*=}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        -V|--version)      printf '%s %s\n' "$INSTALL_VERSION" "$TARGET_NAME 安装引导"; exit 0 ;;
        --)                shift; EXTRA_ARGS=("$@"); break ;;
        *)                 die "未知参数: $1（--help 查看用法）" ;;
    esac
done

case "$MIRROR" in
    auto|github|gitee|cdn) ;;
    *) die "无效的 --mirror: $MIRROR（可选 auto|github|gitee|cdn）" ;;
esac

if [ -z "$MIN_VERSION" ] || ! printf '%s' "$MIN_VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
    die "无效的 --min-version: $MIN_VERSION"
fi

# ============================ 下载器与源 ============================
# 允许用环境变量替换源（自建镜像 / 内网测试时可覆盖）
SRC_GITHUB="${ACME_SRC_GITHUB:-https://raw.githubusercontent.com/KuwiNet/acme-cf-cert/main/$TARGET_NAME}"
SRC_GITEE="${ACME_SRC_GITEE:-https://gitee.com/kuwinet/acme-cf-cert/raw/main/$TARGET_NAME}"
# acme.kuwi.net 现在托管的是本引导脚本，不再是 acme_cert.sh 的下载地址；
# 需要第三源（自建镜像/内网）时用 ACME_SRC_CDN=<url> 指定，留空则只用 GitHub + Gitee。
SRC_CDN="${ACME_SRC_CDN:-}"

UA="acme-cert-install/$INSTALL_VERSION"

have() { command -v "$1" >/dev/null 2>&1; }
# 有控制终端才把 stdin 接到 tty；某些无会话环境 /dev/tty 存在但打开会失败
tty_ok() { ( : </dev/tty ) 2>/dev/null; }
if have curl; then DOWNLOADER=curl
elif have wget; then DOWNLOADER=wget
else die "需要 curl 或 wget 才能下载（Debian/Ubuntu: apt install curl；CentOS: yum install curl）"
fi

# 用 curl 探速：输出 "ok <字节> <秒>"，失败输出 "fail"
probe() {
    local url="$1" out rc
    if [ "$DOWNLOADER" = curl ]; then
        out="$(curl -fsSL -A "$UA" --connect-timeout 5 --max-time 10 \
                    -o /dev/null -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null)" || return 1
        # shellcheck disable=SC2086  # 此处就是要按空格拆分
        set -- $out
        [ "${1:-}" = "200" ] && [ "${2:-0}" -ge "$MIN_SIZE" ] || return 1
        printf 'ok %s %s\n' "$2" "$3"
        return 0
    else
        rc=0
        out="$(wget -q -U "$UA" --tries=1 --timeout=10 --server-response --spider "$url" 2>&1)" || rc=$?
        [ "$rc" = 0 ] || return 1
        printf 'ok - -\n'
        return 0
    fi
}

# 下载到指定文件，成功返回 0
fetch() {
    local url="$1" out="$2"
    if [ "$DOWNLOADER" = curl ]; then
        curl -fsSL -A "$UA" --connect-timeout 8 --max-time 90 \
             --retry 3 --retry-delay 2 -o "$out" "$url" 2>/dev/null
    else
        wget -q -U "$UA" --tries=3 --timeout=20 -O "$out" "$url" 2>/dev/null
    fi
}

# ============================ 校验 ============================
version_of() {
    grep -m1 '^SCRIPT_VERSION=' "$1" 2>/dev/null | sed 's/[^0-9.]//g'
}

ver_ge() {  # $1 >= $2
    local a="$1" b="$2"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

valid_body() {  # 正文字节流校验，防止把错误页/半截文件当成脚本
    local f="$1" sz ver
    [ -f "$f" ] || return 1
    sz=$(wc -c <"$f" 2>/dev/null || echo 0)
    [ "$sz" -ge "$MIN_SIZE" ] || { warn "正文过小（${sz}B），疑似错误页，丢弃"; return 1; }
    head -1 "$f" | grep -q '^#!.*bash' || { warn "正文不是 bash 脚本（首行不是 shebang），丢弃"; return 1; }
    grep -q '^SCRIPT_VERSION=' "$f" || { warn "正文缺少 SCRIPT_VERSION，丢弃"; return 1; }
    ver=$(version_of "$f")
    ver_ge "$ver" "$MIN_VERSION" || { warn "正文版本 v$ver 低于要求的 v$MIN_VERSION，丢弃"; return 1; }
    if have bash; then
        bash -n "$f" 2>/dev/null || { warn "正文 bash 语法检查失败，丢弃"; return 1; }
    fi
    return 0
}

# ============================ 选源 ============================
# 输出可用源，每行一个（空值跳过）
emit_srcs() {
    local u
    for u in "$@"; do
        [ -n "$u" ] || continue
        printf '%s\n' "$u"
    done
}

# 依据实测结果挑选：优先最快且能通过探测的源；--mirror 可强制指定
pick_sources() {
    local gh="$1" gt="$2" cdn="$3" mode="$4"
    case "$mode" in
        github) emit_srcs "$gh" "$gt" "$cdn" ;;
        gitee)  emit_srcs "$gt" "$gh" "$cdn" ;;
        cdn)    emit_srcs "$cdn" "$gh" "$gt" ;;
        auto)
            # 两边都探，按耗时升序；CDN 作为最后兜底
            local gh_t gt_t
            gh_t="$(probe "$gh")" && :
            gt_t="$(probe "$gt")" && :
            if [ -n "${gh_t:-}" ] && [ -n "${gt_t:-}" ]; then
                local gh_sec gt_sec
                gh_sec="${gh_t##* }"
                gt_sec="${gt_t##* }"
                if awk -v a="$gh_sec" -v b="$gt_sec" 'BEGIN{exit !(a<=b)}'; then
                    emit_srcs "$gh" "$gt" "$cdn"
                else
                    emit_srcs "$gt" "$gh" "$cdn"
                fi
            elif [ -n "${gh_t:-}" ]; then
                emit_srcs "$gh" "$gt" "$cdn"
            elif [ -n "${gt_t:-}" ]; then
                emit_srcs "$gt" "$gh" "$cdn"
            else
                emit_srcs "$gh" "$gt" "$cdn"
            fi
            ;;
    esac
}

detect_summary() {
    case "$MIRROR" in
        github) printf 'GitHub（--mirror 指定）' ;;
        gitee)  printf 'Gitee（--mirror 指定）' ;;
        cdn)    printf '自定义 CDN 源（--mirror 指定）' ;;
        auto)
            if [ "$CHOSEN" = "$SRC_GITHUB" ]; then printf 'GitHub（测速较快）'
            elif [ "$CHOSEN" = "$SRC_GITEE" ]; then printf 'Gitee（GitHub 不可用或较慢）'
            else printf 'acme.kuwi.net（GitHub/Gitee 均不可用，走自有 CDN）'
            fi
            ;;
    esac
}

# ============================ 主流程 ============================
[ -n "$DEST_DIR" ] || DEST_DIR="$PWD"
[ -d "$DEST_DIR" ] || mkdir -p "$DEST_DIR" 2>/dev/null || die "无法创建目录: $DEST_DIR"

TMP_FILE="$DEST_DIR/.${TARGET_NAME}.part.$$"
trap 'rm -f "$TMP_FILE"' EXIT INT TERM

# -m cdn 必须显式给源：内置的 acme.kuwi.net 地址已不再提供 acme_cert.sh
[ "$MIRROR" = cdn ] && [ -z "$SRC_CDN" ] \
    && die "未配置 CDN 源：请用 ACME_SRC_CDN=<url> 指定（本引导不再内置 CDN 地址）"

read -r -a CANDIDATES <<<"$(pick_sources "$SRC_GITHUB" "$SRC_GITEE" "$SRC_CDN" "$MIRROR")"
CHOSEN=""
ATTEMPTS=0

info "探测下载源（curl/wget: $DOWNLOADER）"
for src in "${CANDIDATES[@]}"; do
    ATTEMPTS=$((ATTEMPTS + 1))
    host="${src#*://}"; host="${host%%/*}"
    if [ "$FORCE" = 0 ] && [ "$MIRROR" = auto ] && ! probe "$src" >/dev/null 2>&1; then
        warn "$host 探测失败，跳过"
        continue
    fi
    info "从 $host 下载 $TARGET_NAME …"
    if fetch "$src" "$TMP_FILE" && valid_body "$TMP_FILE"; then
        CHOSEN="$src"
        break
    fi
    warn "$host 下载或校验失败，换下一个源"
    rm -f "$TMP_FILE"
done

[ -n "$CHOSEN" ] || die "全部下载源失败（已尝试 ${ATTEMPTS} 个）。可检查网络，或手动下载:
  $SRC_GITEE"

VER="$(version_of "$TMP_FILE")"
TARGET_PATH="$DEST_DIR/$TARGET_NAME"
if [ -f "$TARGET_PATH" ]; then
    OLD_VER="$(version_of "$TARGET_PATH")"
    if [ -z "$OLD_VER" ]; then
        info "已存在同名文件（非 $TARGET_NAME 或版本未知），将被覆盖"
    elif [ "$OLD_VER" = "$VER" ]; then
        info "已存在同版本 v$VER，重新写入"
    else
        info "已存在 v$OLD_VER，将被覆盖为 v$VER"
    fi
fi
mv -f "$TMP_FILE" "$TARGET_PATH" || die "写入 $TARGET_PATH 失败"
chmod +x "$TARGET_PATH" 2>/dev/null || warn "chmod +x 失败，请手动执行 chmod +x \"$TARGET_PATH\""

ok "已保存: $TARGET_PATH (v$VER)"
info "来源: $(detect_summary)"

if [ "$RUN" = 0 ]; then
    info "已跳过执行（--no-run）。后续可运行: $TARGET_PATH --help"
    exit 0
fi

# 交给正文自己接管终端输入：curl | bash 场景下 stdin 是管道，
# 正文需要 /dev/tty 才能交互，这里直接把 tty 接过来
# 交互终端存在才自动运行：没有终端时（ssh 非交互、CI、cron）向导必然读到 EOF，
# 与其报错退出，不如把已下载的文件和后续命令告诉用户
if [ "$RUN" = 1 ]; then
    if tty_ok || [ -t 0 ] || [ "$RUN_FORCE" = 1 ]; then
        info "启动 $TARGET_NAME …"
        printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${NC}"
        if tty_ok; then
            exec bash "$TARGET_PATH" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} </dev/tty
        else
            exec bash "$TARGET_PATH" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        fi
    fi
    warn "当前没有交互终端，未自动运行（首次配置向导需要终端输入）"
    info "手动运行: $TARGET_PATH"
    info "要跳过下载直接跑后续命令，可用 -r/--run 强制执行"
    exit 0
fi
