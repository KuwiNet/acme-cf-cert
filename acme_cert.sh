#!/bin/bash
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 配置存储目录
ACME_DIR="$HOME/.acme.sh"
TOKEN_FILE="$ACME_DIR/token.cfg"
EMAIL_FILE="$ACME_DIR/email.cfg"
DOMAINS_FILE="$ACME_DIR/domains.cfg"
CONFIG_DIR_FILE="$ACME_DIR/configdir.cfg"

# 增强版域名验证函数
validate_domain() {
    local domain="$1"
    # 支持格式：
    # example.com
    # *.example.com
    # *.sub.example.com
    if [[ "$domain" =~ ^(\*\.)?([a-zA-Z0-9-]+\.)*[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 显示帮助信息
show_help() {
    echo -e "\n${GREEN}SSL证书自动化管理脚本${NC}"
    echo -e "版本: 1.0"
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
    echo -e "\n${GREEN}证书存储:${NC}"
    echo "  - 所有域名证书统一安装在主域名目录下"
    echo "  - 示例: /etc/ssl/maindomain.com/{cert.pem,key.pem,fullchain.pem}"
}

# 初始化存储目录
init_acme_dir() {
    if ! mkdir -p "$ACME_DIR"; then
        echo -e "${RED}[x] 无法创建配置目录: $ACME_DIR${NC}"
        exit 1
    fi
    chmod 700 "$ACME_DIR"
}

# 交互式清理配置
interactive_clean() {
    while true; do
        echo -e "\n${YELLOW}=== 选择要清理的配置项 ===${NC}"
        echo "1. 清除域名配置"
        echo "2. 清除邮箱配置"
        echo "3. 清除Token配置"
        echo "4. 清除所有配置"
        echo "5. 返回主菜单"
        
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

# 清理域名配置
clean_domains() {
    if [[ -f "$DOMAINS_FILE" ]]; then
        if rm -f "$DOMAINS_FILE"; then
            echo -e "${GREEN}[√] 域名配置已清除${NC}"
        else
            echo -e "${RED}[x] 域名配置清除失败${NC}"
        fi
    else
        echo -e "${YELLOW}[!] 未找到域名配置文件${NC}"
    fi
}

# 清理邮箱配置
clean_email() {
    if [[ -f "$EMAIL_FILE" ]]; then
        if rm -f "$EMAIL_FILE"; then
            echo -e "${GREEN}[√] 邮箱配置已清除${NC}"
        else
            echo -e "${RED}[x] 邮箱配置清除失败${NC}"
        fi
    else
        echo -e "${YELLOW}[!] 未找到邮箱配置文件${NC}"
    fi
}

# 清理Token配置
clean_token() {
    if [[ -f "$TOKEN_FILE" ]]; then
        if rm -f "$TOKEN_FILE"; then
            echo -e "${GREEN}[√] Token配置已清除${NC}"
        else
            echo -e "${RED}[x] Token配置清除失败${NC}"
        fi
    else
        echo -e "${YELLOW}[!] 未找到Token配置文件${NC}"
    fi
}

# 清理所有配置
clean_all() {
    echo -e "\n${YELLOW}[!] 正在清理所有配置...${NC}"
    clean_domains
    clean_email
    clean_token
    if [[ -f "$CONFIG_DIR_FILE" ]]; then
        rm -f "$CONFIG_DIR_FILE"
    fi
    echo -e "${GREEN}[√] 所有配置清理完成${NC}"
}

# 检查必要配置是否存在
check_required_config() {
    [[ -f "$TOKEN_FILE" && -f "$EMAIL_FILE" ]]
}

# 依赖检查
check_dependencies() {
    local deps=("curl" "socat" "openssl" "crontab")
    local missing=()
    
    echo -e "\n${YELLOW}[1/6] 检查系统依赖...${NC}"
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
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

# 获取当前域名配置
get_current_domains() {
    echo -e "\n${YELLOW}══════════════ 域名配置 ══════════════${NC}"
    
    # 获取主域名
    while true; do
        read -p "请输入主域名（如：example.com 或 *.example.com）: " MAIN_DOMAIN
        if validate_domain "$MAIN_DOMAIN"; then
            break
        else
            echo -e "${RED}[x] 域名格式无效，请使用类似：example.com 或 *.example.com 的格式${NC}"
        fi
    done
    
    # 获取其他域名
    while true; do
        read -p "请输入其他域名（空格分隔，如：*.example.com test.com）: " OTHER_DOMAINS
        
        # 检查是否输入了其他域名
        if [[ -z "$OTHER_DOMAINS" ]]; then
            read -p "未输入其他域名，确认继续？(y/n) " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && break
            continue
        fi
        
        # 验证所有其他域名
        local invalid=0
        for domain in $OTHER_DOMAINS; do
            if ! validate_domain "$domain"; then
                echo -e "${RED}[x] 无效域名格式: $domain${NC}"
                invalid=1
            fi
        done
        [ $invalid -eq 0 ] && break
    done
    
    # 将整组域名写入文件（一行）
    echo "$MAIN_DOMAIN $OTHER_DOMAINS" >> "$DOMAINS_FILE"
    
    # 构建acme.sh参数
    DOMAINS="-d $MAIN_DOMAIN"
    for domain in $OTHER_DOMAINS; do
        DOMAINS="$DOMAINS -d $domain"
    done
    
    echo -e "${GREEN}[√] 域名组已保存: ${YELLOW}$MAIN_DOMAIN $OTHER_DOMAINS${NC}"
}

# 交互式初始配置
get_initial_config() {
    echo -e "\n${YELLOW}[!] 开始初始配置向导${NC}"
    
    # 获取Cloudflare Token
    while true; do
        read -s -p "请输入Cloudflare API Token: " CF_Token
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
    
    # 获取管理员邮箱
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

# 加载现有配置
load_config() {
    if ! CF_Token=$(cat "$TOKEN_FILE" 2>/dev/null); then
        echo -e "${RED}[x] 无法读取Token文件${NC}"
        exit 1
    fi
    
    if ! EMAIL=$(cat "$EMAIL_FILE" 2>/dev/null); then
        echo -e "${RED}[x] 无法读取邮箱文件${NC}"
        exit 1
    fi
    
    TARGET_DIR=$(cat "$CONFIG_DIR_FILE" 2>/dev/null || echo "/etc/ssl")
    
    # 获取本次要处理的域名
    get_current_domains
}

# 安装acme.sh
install_acme() {
    echo -e "\n${YELLOW}[2/6] 检查acme.sh安装...${NC}"
    
    if ! command -v acme.sh &>/dev/null; then
        echo -e "${YELLOW}[!] 正在安装acme.sh客户端...${NC}"
        if ! curl -sL https://get.acme.sh | sh -s email="$EMAIL"; then
            echo -e "${RED}[x] acme.sh安装失败${NC}"
            exit 1
        fi
        
        source ~/.bashrc 2>/dev/null || source ~/.profile 2>/dev/null
        
        if ! ~/.acme.sh/acme.sh --version &>/dev/null; then
            echo -e "${RED}[x] acme.sh验证失败${NC}"
            exit 1
        fi
        
        if ! ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt; then
            echo -e "${RED}[x] 无法设置默认CA${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}[√] acme.sh安装成功${NC}"
    else
        echo -e "${GREEN}[√] acme.sh已安装${NC}"
        
        if ~/.acme.sh/acme.sh --upgrade; then
            echo -e "${GREEN}[√] acme.sh已更新到最新版本${NC}"
        else
            echo -e "${YELLOW}[!] acme.sh更新失败（继续使用当前版本）${NC}"
        fi
    fi
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

# 修改后的证书安装函数（关键修改）
install_certificate() {
    echo -e "\n${YELLOW}[4/6] 安装证书到指定目录...${NC}"
    
    # 只为主域名创建证书目录
    CERT_DIR="$TARGET_DIR/${MAIN_DOMAIN#\*\.}"  # 去除泛域名前缀（如果有）
    mkdir -p "$CERT_DIR"
    
    # 安装主域名证书（包含所有其他域名）
    if ~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --cert-file "$CERT_DIR/cert.pem" \
        --key-file "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "echo '证书 [$MAIN_DOMAIN] 已更新！'"; then
        chmod 600 "$CERT_DIR"/*.pem
        echo -e "${GREEN}[√] 证书已安装到: ${YELLOW}$CERT_DIR${NC}"
        echo -e "${GREEN}[√] 该证书包含以下域名: ${YELLOW}$MAIN_DOMAIN $OTHER_DOMAINS${NC}"
    else
        echo -e "${RED}[x] 证书安装失败: $MAIN_DOMAIN${NC}"
        exit 1
    fi
}

# 为所有域名设置续期
setup_renewal() {
    echo -e "\n${YELLOW}[5/6] 设置自动续期...${NC}"
    
    # 只需要为主域名设置续期（其他域名包含在同一个证书中）
    if ~/.acme.sh/acme.sh --install-cronjob -d "$MAIN_DOMAIN"; then
        echo -e "${GREEN}[√] 续期任务已设置: ${YELLOW}$MAIN_DOMAIN${NC}"
        echo -e "${GREEN}[√] 该续期任务包含所有关联域名${NC}"
    else
        echo -e "${YELLOW}[!] 续期任务设置失败: $MAIN_DOMAIN（可能已存在）${NC}"
    fi
    
    echo -e "${GREEN}[√] 续期设置完成${NC}"
    echo -e "续期日志: ${YELLOW}/var/log/acme_renew.log${NC}"
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
    # 参数处理
    case "${1:-}" in
        --clean) 
            interactive_clean
            exit 0
            ;;
        --clean-all)
            clean_all
            exit 0
            ;;
        --clean-domains)
            clean_domains
            exit 0
            ;;
        --clean-email)
            clean_email
            exit 0
            ;;
        --clean-token)
            clean_token
            exit 0
            ;;
        --list)
            list_all_domains
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            ;;
    esac

    # 初始化目录
    init_acme_dir
    
    # 配置检查
    if ! check_required_config; then
        echo -e "${YELLOW}[!] 检测到需要初始配置${NC}"
        get_initial_config
    else
        echo -e "${GREEN}[√] 使用现有配置${NC}"
        load_config
    fi
    
    # 证书管理流程
    check_dependencies
    install_acme
    issue_certificate
    install_certificate
    setup_renewal
    
    # 完成提示
    echo -e "\n${GREEN}════════════ 操作完成 ════════════${NC}"
    echo -e "证书存储位置:"
    echo -e "  ${YELLOW}$TARGET_DIR/${MAIN_DOMAIN#\*\.}/{cert.pem,key.pem,fullchain.pem}${NC}"
    echo -e "包含的域名:"
    echo -e "  ${YELLOW}$MAIN_DOMAIN $OTHER_DOMAINS${NC}"
    echo -e "\n管理操作:"
    echo -e "  - 查看所有域名组: ${YELLOW}$0 --list${NC}"
    echo -e "  - 清理配置: ${YELLOW}$0 --clean${NC}"
    echo -e "  - 显示帮助信息: ${YELLOW}$0 --help${NC}"
}

# 执行入口
main "$@"
