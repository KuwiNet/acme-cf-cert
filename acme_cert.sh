#!/bin/bash

# 脚本信息
SCRIPT_NAME="acme_cert.sh"
SCRIPT_VERSION="1.2.2"
SCRIPT_URL="https://github.com/KuwiNet/acme-cf-cert/raw/main/acme_cert.sh"
MIRROR_URL="https://gitee.com/kuwinet/acme-cf-cert/raw/main/acme_cert.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置存储目录
ACME_DIR="$HOME/.acme.sh/config"
TOKEN_FILE="$ACME_DIR/token.cfg"
EMAIL_FILE="$ACME_DIR/email.cfg"
DOMAINS_FILE="$ACME_DIR/domains.cfg"
CONFIG_DIR_FILE="$ACME_DIR/configdir.cfg"

# 检查更新函数
check_update() {
    echo -e "${YELLOW}[!] 检查脚本更新...${NC}"
    remote_version=$(curl -sL "$SCRIPT_URL" | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)
    [ -z "$remote_version" ] && remote_version=$(curl -sL "$MIRROR_URL" | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)

    if [ -z "$remote_version" ]; then
        echo -e "${RED}[!] 无法获取远程版本信息${NC}"
        return 1
    fi

    if [ "$remote_version" != "$SCRIPT_VERSION" ]; then
        echo -e "${YELLOW}[!] 发现新版本: $remote_version${NC}"
        read -p "是否更新脚本? [Y/n] " answer
        [[ "$answer" =~ ^[Yy]?$ ]] && update_script
    else
        echo -e "${GREEN}[√] 当前已是最新版本${NC}"
    fi
}

# 更新脚本函数
update_script() {
    echo -e "${YELLOW}[!] 正在更新脚本...${NC}"
    if curl -sL "$SCRIPT_URL" -o "$0.tmp"; then
        mv "$0.tmp" "$0"
        chmod +x "$0"
        echo -e "${GREEN}[√] 脚本更新成功，请重新运行${NC}"
        exit 0
    elif curl -sL "$MIRROR_URL" -o "$0.tmp"; then
        mv "$0.tmp" "$0"
        chmod +x "$0"
        echo -e "${GREEN}[√] 使用镜像源更新成功，请重新运行${NC}"
        exit 0
    else
        rm -f "$0.tmp"
        echo -e "${RED}[!] 脚本更新失败${NC}"
        return 1
    fi
}

# 域名验证函数
validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^(\*\.)?([a-zA-Z0-9-]+\.)*[a-zA-Z]{2,}$ ]]
}

# 核心域名输入函数
input_domains() {
    echo -e "\n${YELLOW}══════════════ 域名配置 ══════════════${NC}"
    
    while true; do
        read -p "请输入主域名（如：example.com 或 *.example.com）: " MAIN_DOMAIN
        if validate_domain "$MAIN_DOMAIN"; then
            break
        else
            echo -e "${RED}[x] 域名格式无效，请使用类似：example.com 或 *.example.com 的格式${NC}"
        fi
    done
    
    while true; do
        read -p "请输入其他域名（空格分隔，如：*.example.com test.com）: " OTHER_DOMAINS
        
        if [[ -z "$OTHER_DOMAINS" ]]; then
            read -p "未输入其他域名，确认继续？(y/n) " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && break
            continue
        fi
        
        local invalid=0
        for domain in $OTHER_DOMAINS; do
            if ! validate_domain "$domain"; then
                echo -e "${RED}[x] 无效域名格式: $domain${NC}"
                invalid=1
            fi
        done
        [ $invalid -eq 0 ] && break
    done
    
    DOMAINS="-d $MAIN_DOMAIN"
    for domain in $OTHER_DOMAINS; do
        DOMAINS="$DOMAINS -d $domain"
    done
    
    echo -e "${GREEN}[√] 使用域名组: ${YELLOW}$MAIN_DOMAIN $OTHER_DOMAINS${NC}"
}

# 域名配置函数
get_current_domains() {
    input_domains
    
    local domain_group="$MAIN_DOMAIN $OTHER_DOMAINS"
    local exists=0
    
    if [[ -f "$DOMAINS_FILE" ]]; then
        while read -r line; do
            if [[ "$line" == "$domain_group" ]]; then
                exists=1
                echo -e "${YELLOW}[!] 该域名组已存在，不会重复添加${NC}"
                break
            fi
        done < "$DOMAINS_FILE"
    fi
    
    if [[ $exists -eq 0 ]]; then
        echo "$domain_group" >> "$DOMAINS_FILE"
        echo -e "${GREEN}[√] 域名组已保存: ${YELLOW}$domain_group${NC}"
    fi
}

# 配置检查函数（新增智能检查）
check_required_config() {
    local missing=0
    
    if [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}[x] 缺少Cloudflare Token配置${NC}"
        missing=1
    fi
    
    if [ ! -f "$EMAIL_FILE" ]; then
        echo -e "${RED}[x] 缺少管理员邮箱配置${NC}"
        missing=1
    fi
    
    return $missing
}

# 初始配置向导（增强版）
get_initial_config() {
    echo -e "\n${YELLOW}[!] 开始初始配置向导${NC}"
    
    # 只在Token不存在时获取
    if [ ! -f "$TOKEN_FILE" ]; then
        while true; do
            read -s -p "请输入Cloudflare API Token（输入时不可见）: " CF_Token
            echo
            if [[ -n "$CF_Token" ]]; then
                if echo "$CF_Token" > "$TOKEN_FILE" && chmod 600 "$TOKEN_FILE"; then
                    break
                else
                    echo -e "${RED}[x] Token保存失败${NC}"
                fi
            else
                echo -e "${RED}[x] Token不能为空${NC}"
            fi
        done
    fi
    
    # 只在邮箱不存在时获取
    if [ ! -f "$EMAIL_FILE" ]; then
        while true; do
            read -p "请输入管理员邮箱: " EMAIL
            if [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                if echo "$EMAIL" > "$EMAIL_FILE" && chmod 600 "$EMAIL_FILE"; then
                    break
                else
                    echo -e "${RED}[x] 邮箱保存失败${NC}"
                fi
            else
                echo -e "${RED}[x] 邮箱格式无效${NC}"
            fi
        done
    fi
    
    # 获取证书目录
    read -p "请输入证书保存目录（默认：/etc/ssl）: " TARGET_DIR
    TARGET_DIR=${TARGET_DIR:-"/etc/ssl"}
    mkdir -p "$TARGET_DIR"
    echo "$TARGET_DIR" > "$CONFIG_DIR_FILE"
    chmod 600 "$CONFIG_DIR_FILE"
    
    # 获取域名配置
    get_current_domains
    
    echo -e "${GREEN}[√] 初始配置完成${NC}"
}

# 配置加载函数（增强版）
load_config() {
    # 动态加载现有配置
    [ -f "$TOKEN_FILE" ] && CF_Token=$(cat "$TOKEN_FILE")
    [ -f "$EMAIL_FILE" ] && EMAIL=$(cat "$EMAIL_FILE")
    TARGET_DIR=$(cat "$CONFIG_DIR_FILE" 2>/dev/null || echo "/etc/ssl")
    
    # 检查并补充缺失的配置
    if [ ! -f "$TOKEN_FILE" ] || [ ! -f "$EMAIL_FILE" ]; then
        echo -e "${YELLOW}[!] 检测到不完整配置，需要补充信息${NC}"
        get_initial_config
    else
        input_domains
    fi
}

# 显示帮助信息
show_help() {
    echo -e "\n${GREEN}SSL证书自动化管理脚本${NC} v$SCRIPT_VERSION"
    echo -e "\n${YELLOW}使用方法:${NC}"
    echo "  $0                   # 申请新证书"
    echo "  $0 --list            # 查看所有域名组"
    echo "  $0 --clean           # 交互式清理配置"
    echo "  $0 --clean-all       # 清除所有配置"
    echo "  $0 --clean-domains   # 仅清除域名配置"
    echo "  $0 --clean-email     # 仅清除邮箱配置"
    echo "  $0 --clean-token     # 仅清除Token配置"
    echo "  $0 --help            # 显示帮助信息"
    echo -e "\n${GREEN}配置文件保存在: ${YELLOW}$ACME_DIR/${NC}"
}

# 初始化存储目录
init_acme_dir() {
    mkdir -p "$ACME_DIR" || {
        echo -e "${RED}[x] 无法创建配置目录: $ACME_DIR${NC}"
        exit 1
    }
    chmod 700 "$ACME_DIR"
}

# 清理函数
clean_domains() { [ -f "$DOMAINS_FILE" ] && rm -f "$DOMAINS_FILE" && echo -e "${GREEN}[√] 域名配置已清除${NC}" || echo -e "${YELLOW}[!] 未找到域名配置文件${NC}"; }
clean_email() { [ -f "$EMAIL_FILE" ] && rm -f "$EMAIL_FILE" && echo -e "${GREEN}[√] 邮箱配置已清除${NC}" || echo -e "${YELLOW}[!] 未找到邮箱配置文件${NC}"; }
clean_token() { [ -f "$TOKEN_FILE" ] && rm -f "$TOKEN_FILE" && echo -e "${GREEN}[√] Token配置已清除${NC}" || echo -e "${YELLOW}[!] 未找到Token配置文件${NC}"; }

clean_all() {
    clean_domains
    clean_email
    clean_token
    [ -f "$CONFIG_DIR_FILE" ] && rm -f "$CONFIG_DIR_FILE"
    echo -e "${GREEN}[√] 所有配置清理完成${NC}"
}

# 交互式清理
interactive_clean() {
    while true; do
        echo -e "\n${YELLOW}=== 选择要清理的配置项 ===${NC}"
        echo "1. 清除域名配置"
        echo "2. 清除邮箱配置"
        echo "3. 清除Token配置"
        echo "4. 清除所有配置"
        echo "5. 退出"
        
        read -p "请输入选择(1-5): " choice
        case $choice in
            1) clean_domains ;;
            2) clean_email ;;
            3) clean_token ;;
            4) clean_all ;;
            5) break ;;
            *) echo -e "${RED}[x] 无效选项，请重新输入${NC}" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# 依赖检查
check_dependencies() {
    local deps=("curl" "socat" "openssl" "crontab")
    local missing=()
    
    echo -e "\n${YELLOW}[1/6] 检查系统依赖...${NC}"
    
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[x] 缺少依赖: ${missing[*]}${NC}"
        echo -e "${YELLOW}[!] 正在尝试安装...${NC}"
        
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y "${missing[@]}" || {
                echo -e "${RED}[x] 依赖安装失败${NC}";
                exit 1;
            }
        elif command -v yum &>/dev/null; then
            sudo yum install -y "${missing[@]}" || {
                echo -e "${RED}[x] 依赖安装失败${NC}";
                exit 1;
            }
        else
            echo -e "${RED}[x] 不支持的包管理器，请手动安装: ${missing[*]}${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}[√] 所有依赖已满足${NC}"
}

# 证书申请
issue_certificate() {
    echo -e "\n${YELLOW}[3/6] 申请SSL证书...${NC}"
    export CF_Token="$CF_Token"
    
    if ! ~/.acme.sh/acme.sh --issue --dns dns_cf $DOMAINS --force; then
        echo -e "\n${RED}[x] 证书申请失败！可能原因：${NC}"
        echo "1. Token权限不足（需要DNS编辑权限）"
        echo "2. 域名未托管在Cloudflare"
        echo "3. 域名解析未生效"
        echo "4. Let's Encrypt速率限制"
        echo "5. 网络连接问题"
        exit 1
    fi
    
    echo -e "${GREEN}[√] 证书申请成功${NC}"
}

# 证书安装
install_certificate() {
    echo -e "\n${YELLOW}[4/6] 安装证书到指定目录...${NC}"
    
    CERT_DIR="$TARGET_DIR/${MAIN_DOMAIN#\*\.}"
    mkdir -p "$CERT_DIR"
    
    if ~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --cert-file "$CERT_DIR/cert.pem" \
        --key-file "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "echo '证书 [$MAIN_DOMAIN] 已更新！'"; then
        chmod 600 "$CERT_DIR"/*.pem
        echo -e "${GREEN}[√] 证书已安装到: ${YELLOW}$CERT_DIR${NC}"
    else
        echo -e "${RED}[x] 证书安装失败: $MAIN_DOMAIN${NC}"
        exit 1
    fi
}

# 设置续期
setup_renewal() {
    echo -e "\n${YELLOW}[5/6] 设置自动续期...${NC}"
    
    if ~/.acme.sh/acme.sh --install-cronjob -d "$MAIN_DOMAIN"; then
        echo -e "${GREEN}[√] 续期任务已设置${NC}"
    else
        echo -e "${YELLOW}[!] 续期任务设置失败（可能已存在）${NC}"
    fi
}

# 显示所有域名组
list_all_domains() {
    echo -e "\n${YELLOW}所有已配置域名组:${NC}"
    if [[ -f "$DOMAINS_FILE" ]]; then
        local counter=1
        while read -r line; do
            echo -e "  ${GREEN}$counter. ${YELLOW}$line${NC}"
            ((counter++))
        done < "$DOMAINS_FILE"
    else
        echo -e "${RED}未找到域名配置文件${NC}"
    fi
}

# 主流程
main() {
    case "${1:-}" in
        --clean) interactive_clean; exit 0 ;;
        --clean-all) clean_all; exit 0 ;;
        --clean-domains) clean_domains; exit 0 ;;
        --clean-email) clean_email; exit 0 ;;
        --clean-token) clean_token; exit 0 ;;
        --list) list_all_domains; exit 0 ;;
        --update) update_script; exit 0 ;;
        -h|--help) show_help; exit 0 ;;
        *) check_update ;;
    esac

    init_acme_dir
    
    # 智能配置检查
    if ! check_required_config; then
        echo -e "${YELLOW}[!] 检测到需要初始配置${NC}"
        get_initial_config
    else
        echo -e "${GREEN}[√] 使用现有配置${NC}"
        load_config
    fi
    
    check_dependencies
    install_acme
    issue_certificate
    install_certificate
    setup_renewal
    
    echo -e "\n${GREEN}════════════ 操作完成 ════════════${NC}"
    echo -e "证书存储位置: ${YELLOW}$TARGET_DIR/${MAIN_DOMAIN#\*\.}/{cert.pem,key.pem,fullchain.pem}${NC}"
    echo -e "\n管理操作:"
    echo -e "  - 查看所有域名组: ${YELLOW}$0 --list${NC}"
    echo -e "  - 清理配置: ${YELLOW}$0 --clean${NC}"
}

# 执行入口
main "$@"
