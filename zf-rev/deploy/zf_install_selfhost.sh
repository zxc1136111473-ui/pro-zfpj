#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ──────────────────────────────────────────────────────────────────────────
# Agent / 非交互运行时全局开关与状态
# 这些变量构成「agent 模式」运行时。完整契约见仓库根 AGENT_INSTALL.md
# 与 https://www.zeroforwarder.com/llms-install.txt
# ──────────────────────────────────────────────────────────────────────────

# 选定动作: install|update|uninstall|show-token|refresh-token|pack|restore|check|menu
ZFC_ACTION=""

# 非交互模式: 1 = 不再向 /dev/tty 提问, 缺必填值即按契约 die。
# 由 --non-interactive / -y / --yes / ZFC_NONINTERACTIVE 触发,
# 或在无 tty 且必填 env 齐全时由 parse_args 自动开启。
ZFC_NONINTERACTIVE="${ZFC_NONINTERACTIVE:-0}"

# 机器可读 JSON 输出: 1 = 成功末尾输出一行 JSON, 失败经 die 输出 JSON error。
ZFC_OUTPUT_JSON="${ZFC_OUTPUT_JSON:-0}"

# 非交互确认的总开关: 1 = 对「proceed 类」确认自动取肯定值(不阻塞)。
ZFC_ASSUME_YES="${ZFC_ASSUME_YES:-1}"

# 自动安装缺失依赖(docker / compose 插件 / openssl / curl)。
ZFC_AUTO_INSTALL_DOCKER="${ZFC_AUTO_INSTALL_DOCKER:-1}"

# 安装前在线校验 license。
ZFC_VALIDATE_LICENSE="${ZFC_VALIDATE_LICENSE:-1}"

# 自动设置时间同步。
ZFC_SETUP_TIME_SYNC="${ZFC_SETUP_TIME_SYNC:-1}"

# 卸载方式(1=容器与镜像,2=含数据卷,3=完全清理)。非交互卸载必须显式提供。
ZFC_UNINSTALL_MODE="${ZFC_UNINSTALL_MODE:-}"

# 恢复时的迁移包路径。非交互恢复必须显式提供。
ZFC_RESTORE_PACKAGE="${ZFC_RESTORE_PACKAGE:-}"

# --update 的一次性目标版本(--to)。覆盖 .env 的 ZFC_UPDATE_CHANNEL 但**不写回**:
# --to 是一次性动作, channel 是长期意图, 混淆会让下次 --update 意外停在旧版本。
# 低于当前版本即为回滚 —— 镜像可回退, 但 schema 不可自动降级(见 ZFC_ALLOW_SCHEMA_DOWNGRADE)。
ZFC_UPDATE_TO="${ZFC_UPDATE_TO:-}"

# resolve_deploy_version 的输出: 本次部署解析出的 release 版本(空 = legacy 镜像无法钉版本)。
ZFC_RESOLVED_VERSION=""
# 解析出的钉死引用。**必须存在这组专用全局里**: 因为 .env 文件的改写被推迟到
# update_schema 成功之后, 而 update_schema 自己会 `source .env`(见其开头) —— 那会把
# resolve 阶段 export 的新引用冲回文件里的旧值。被冲掉的后果是 update_schema 用**旧**
# 镜像抽 schema bundle → 把库迁到旧 schema, 而随后 commit_pinned_env 却写入新版本 →
# 起新镜像配旧库 → crash-loop, 正是本设计要防的那个 bug。
ZFC_PINNED_WEB_IMAGE=""; ZFC_PINNED_CTL_IMAGE=""; ZFC_PINNED_RRD_IMAGE=""
ZFC_PINNED_UTIL_IMAGE=""; ZFC_PINNED_ADMIN_IMAGE=""

# restore 版本仲裁的输出(restore_resolve_target / restore_pull_and_verify)。
ZFC_RESTORE_VERSION=""; ZFC_RESTORE_SHA=""; ZFC_RESTORE_SOURCE=""
ZFC_RESTORE_WEB_RD=""; ZFC_RESTORE_CTL_RD=""
ZFC_RESTORE_WEB_IMAGE=""; ZFC_RESTORE_CTL_IMAGE=""
ZFC_RESTORE_ENV_BACKUP=""
# 目标机器需从其它 registry 拉镜像时覆盖包内前缀(隔离网络 + 本地 mirror)。
ZFC_RESTORE_REGISTRY="${ZFC_RESTORE_REGISTRY:-}"
# restore 解包临时目录, 由 zfc_on_exit 兜底清理(每个都含全量数据 dump)。
ZFC_RESTORE_TEMP_DIR=""

# 覆盖已存在安装(危险, 默认关)。--force = 重建内置库(不保数据), 疑似完整安装会被守卫挡下。
ZFC_FORCE="${ZFC_FORCE:-0}"

# 一键清空重装(危险): down -v + 清本机配置/卷, 隐含 --force 且绕过健康安装守卫。
# 注意: 只清本机 compose 卷与本地配置, 不会自动清外部 PostgreSQL/Redis。
ZFC_CLEAN_INSTALL="${ZFC_CLEAN_INSTALL:-0}"

# 自我后台化: 用 setsid/nohup 把长动作(install/update/restore)放后台并立即返回 pid/log。
ZFC_DETACH="${ZFC_DETACH:-0}"
# 内部守卫: 后台子进程置 1, 防 re-exec 死循环 + 避免重复 tee。
ZFC_DETACHED="${ZFC_DETACHED:-0}"
# 内部: detach 时若把脚本固化到临时文件, 路径经此 env 传给后台子进程, 由其 EXIT 时自清。
ZFC_DETACH_CLEANUP="${ZFC_DETACH_CLEANUP:-}"

# 安装/更新日志文件(agent/非交互运行始终落盘, 便于断连后 tail 排查)。
ZFC_LOG_FILE="${ZFC_LOG_FILE:-./zfc-install.log}"

# schema_backup/ 历史备份自动清理(每次升级后执行)。
#   AUTOCLEAN=0 关闭; RETAIN_COUNT 始终保留最近 N 份(下限); RETAIN_DAYS 超出 N 份且超过 D 天才删。
#   软清理两个维度同时生效: 文件必须「超出最近 N 份」AND「超过 D 天」才会被删, 避免误删近期备份。
#   注意 RETAIN_COUNT 是下限不是上限: 30 天内即使攒了很多份也不会被软清理删掉。
#   若需硬性封顶磁盘占用, 用 MAX_COUNT(>0): 超过该份数的旧备份无视年龄直接删(硬上限优先)。
ZFC_BACKUP_AUTOCLEAN="${ZFC_BACKUP_AUTOCLEAN:-1}"
ZFC_BACKUP_RETAIN_COUNT="${ZFC_BACKUP_RETAIN_COUNT:-5}"
ZFC_BACKUP_RETAIN_DAYS="${ZFC_BACKUP_RETAIN_DAYS:-30}"
ZFC_BACKUP_MAX_COUNT="${ZFC_BACKUP_MAX_COUNT:-0}"

# 通过 --config 加载的配置文件路径。
ZFC_CONFIG_FILE=""

# 由 CLI flag 显式设定、加载文件时需保护的模式键(空格分隔, 首尾空格便于匹配)。
ZFC_FLAG_LOCKED_KEYS=""

# 结果文件 & 是否已输出过结构化结果(供 EXIT trap 兜底)。
ZFC_RESULT_FILE="${ZFC_RESULT_FILE:-.zfc_install_result.json}"
ZFC_RESULT_EMITTED=0

# 累积的非致命告警(JSON 数组内容, 逗号分隔的带引号字符串)。
ZFC_WARNINGS_JSON=""

# 下一条 die/emit_json_error 的 actionable 修复建议(供 agent 自愈)。调用方在 die 前设置,
# emit_json_error 输出后由其自身清空。
ZFC_HINT=""

# check_ports_available 写入: 最近一次检测到的被占用端口(空格分隔), 供端口冲突归因。
LAST_OCCUPIED_PORTS=""

# Schema bundle protocol state. New images carry /app/schema-bundle; legacy
# images continue through the old CDN path during the transition window.
readonly ZFC_INSTALLER_FORMAT=1
SCHEMA_BUNDLE_ROOT=""
SCHEMA_SOURCE="legacy"
EXPECTED_SCHEMA_SHA256=""
TARGET_SCHEMA_RELEASE=""
ZF_WEB_IMAGE_ID=""
ZF_CONTROLER_IMAGE_ID=""

# 管理员 token(create_admin_user 写入, 供成功 JSON 输出)。
ADMIN_TOKEN=""

# detect_compose_cmd 缓存。
DOCKER_COMPOSE_CMD=""

# 退出码契约(die 调用 & AGENT_INSTALL.md 同源):
#   0  成功 / 10 缺必填输入 / 11 端口冲突 / 12 依赖不可用
#   13 license 无效 / 14 DB 连接失败 / 15 admin 创建失败
#   16 已存在安装(需 --force) / 17 配置文件非法
#   18 schema 迁移失败/未完成 / 19 更新后启动门禁失败 / 20 镜像拉取失败
readonly EXIT_OK=0
readonly EXIT_MISSING_INPUT=10
readonly EXIT_PORT_CONFLICT=11
readonly EXIT_DEP_UNAVAILABLE=12
readonly EXIT_LICENSE_INVALID=13
readonly EXIT_DB_CONNECT=14
readonly EXIT_ADMIN_CREATE=15
readonly EXIT_ALREADY_INSTALLED=16
readonly EXIT_BAD_CONFIG=17
readonly EXIT_SCHEMA_MIGRATION=18
readonly EXIT_UPDATE_HEALTH=19
readonly EXIT_IMAGE_PULL=20

# Logo
show_logo() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     ZFC 一键安装脚本                           ║"
    echo "║                  Zero Forward Control                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Show main menu
show_menu() {
    show_logo
    echo
    echo -e "${GREEN}请选择操作:${NC}"
    echo "1. 全新安装"
    echo "2. 更新镜像（保留数据）"
    echo "3. 卸载系统"
    echo "4. 查看管理员密码"
    echo "5. 刷新管理员 Token"
    echo "6. 一键打包迁移文件"
    echo "7. 一键恢复迁移文件"
    echo "8. 设置 Docker 日志自动清理"
    echo "9. 退出"
    echo
}

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# ──────────────────────────────────────────────────────────────────────────
# Agent / 非交互运行时 helpers
# ──────────────────────────────────────────────────────────────────────────

# 转义为 JSON 字符串字面量内容(不含外层引号)。
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 记录一条非致命告警(同时打印 + 累积进 JSON 数组)。
add_warning() {
    log_warning "$1"
    local q
    q="\"$(json_escape "$1")\""
    if [[ -z "$ZFC_WARNINGS_JSON" ]]; then
        ZFC_WARNINGS_JSON="$q"
    else
        ZFC_WARNINGS_JSON="${ZFC_WARNINGS_JSON},${q}"
    fi
}

# 输出结构化错误 JSON(stdout + 结果文件), 标记已输出。
# 若全局 ZFC_HINT 非空, 追加 "hint" 字段(agent 自愈用), 输出后清空。
emit_json_error() {
    local code="$1"; shift
    local reason="$*"
    ZFC_RESULT_EMITTED=1
    local json hint_json=""
    if [[ -n "$ZFC_HINT" ]]; then
        hint_json=$(printf ',"hint":"%s"' "$(json_escape "$ZFC_HINT")")
    fi
    json=$(printf '{"status":"error","action":"%s","code":%s,"reason":"%s"%s}' \
        "$(json_escape "${ZFC_ACTION:-unknown}")" "$code" "$(json_escape "$reason")" "$hint_json")
    ( umask 077; printf '%s\n' "$json" > "$ZFC_RESULT_FILE" 2>/dev/null ) || true
    chmod 600 "$ZFC_RESULT_FILE" 2>/dev/null || true
    printf '%s\n' "$json"
    ZFC_HINT=""
}

# 输出成功结果 JSON。依赖全局: ZFC_ACTION/WEB_DOMAIN/CONTROLER_DOMAIN/CADDY_ENABLED/ADMIN_TOKEN。
emit_json_result() {
    ZFC_RESULT_EMITTED=1
    local web_url controller_url caddy_bool
    if [[ "${CADDY_ENABLED:-false}" == "true" ]]; then
        web_url="https://${WEB_DOMAIN}"
        controller_url="https://${CONTROLER_DOMAIN}"
        caddy_bool="true"
    else
        web_url="http://<server-ip>:8080"
        controller_url="http://<server-ip>:3100"
        caddy_bool="false"
    fi
    local json
    json=$(printf '{"status":"success","action":"%s","web_url":"%s","controller_url":"%s","admin_address":"%s","admin_token":"%s","caddy_enabled":%s,"warnings":[%s],"errors":[]}' \
        "$(json_escape "${ZFC_ACTION}")" \
        "$(json_escape "$web_url")" \
        "$(json_escape "$controller_url")" \
        "admin@zfc.local" \
        "$(json_escape "${ADMIN_TOKEN:-}")" \
        "$caddy_bool" \
        "$ZFC_WARNINGS_JSON")
    ( umask 077; printf '%s\n' "$json" > "$ZFC_RESULT_FILE" 2>/dev/null ) || true
    chmod 600 "$ZFC_RESULT_FILE" 2>/dev/null || true
    printf '%s\n' "$json"
}

# 统一致命出口: 打印错误, agent 模式输出 JSON error, 按 code 退出。
die() {
    local code="${1:-1}"; shift || true
    local reason="$*"
    log_error "$reason"
    if [[ "$ZFC_OUTPUT_JSON" == "1" ]]; then
        emit_json_error "$code" "$reason"
    fi
    exit "$code"
}

# agent 模式(非交互/JSON) → die 带契约退出码; 交互菜单 → 打印并 return 1(回菜单)。
# 用法: die_or_return <code> <reason> || return 1
die_or_return() {
    local code="$1"; shift
    if [[ "$ZFC_NONINTERACTIVE" == "1" || "$ZFC_OUTPUT_JSON" == "1" ]]; then
        die "$code" "$*"
    fi
    log_error "$*"
    return 1
}

# EXIT trap 兜底: agent 模式下若 set -e 中断且尚未输出结果, 补一条 JSON error。
zfc_on_exit() {
    local rc=$?
    if [[ -n "${SCHEMA_BUNDLE_ROOT:-}" && -d "$SCHEMA_BUNDLE_ROOT" ]]; then
        rm -rf "$SCHEMA_BUNDLE_ROOT"
    fi
    # restore 解包目录: 各失败分支手工 rm 覆盖不到 Ctrl-C, 反复重试会在安装目录
    # 堆一串 zfc_restore_temp_*, 每个都含全量数据 dump。
    if [[ -n "${ZFC_RESTORE_TEMP_DIR:-}" && -d "$ZFC_RESTORE_TEMP_DIR" ]]; then
        rm -rf "$ZFC_RESTORE_TEMP_DIR"
    fi
    # detach 后台子进程退出时清掉固化的临时脚本(如有)。
    if [[ -n "${ZFC_DETACH_CLEANUP:-}" && -f "$ZFC_DETACH_CLEANUP" ]]; then
        rm -f "$ZFC_DETACH_CLEANUP"
    fi
    if [[ "$ZFC_OUTPUT_JSON" == "1" && "$ZFC_RESULT_EMITTED" == "0" && $rc -ne 0 ]]; then
        emit_json_error "$rc" "脚本异常退出 (exit ${rc}); 详见上方日志"
    fi
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

schema_manifest_value() {
    local manifest="$1" key="$2"
    sed -n "s/^${key}=//p" "$manifest" | head -1
}

extract_schema_bundle_from_image() {
    local image="$1" dest="$2" cid
    cid=$(docker create "$image" 2>/dev/null) || return 1
    mkdir -p "$dest"
    if ! docker cp "$cid:/app/schema-bundle/." "$dest/" >/dev/null 2>&1; then
        docker rm -f "$cid" >/dev/null 2>&1 || true
        return 1
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
}

validate_schema_bundle() {
    local dir="$1" prefix="$2"
    local manifest="$dir/manifest.env" schema="$dir/schema.prisma"
    local format min_installer release expected actual commit

    [[ -s "$manifest" && -s "$schema" ]] || {
        log_error "镜像 schema bundle 缺少 manifest.env 或 schema.prisma"
        return 1
    }

    format=$(schema_manifest_value "$manifest" BUNDLE_FORMAT)
    min_installer=$(schema_manifest_value "$manifest" MIN_INSTALLER_FORMAT)
    release=$(schema_manifest_value "$manifest" RELEASE_VERSION)
    expected=$(schema_manifest_value "$manifest" SCHEMA_ARTIFACT_SHA256)
    commit=$(schema_manifest_value "$manifest" GIT_COMMIT)

    [[ "$format" =~ ^[0-9]+$ && "$format" -eq 1 ]] || {
        log_error "不支持的 schema bundle format: ${format:-missing}"
        return 1
    }
    [[ "$min_installer" =~ ^[0-9]+$ && "$min_installer" -le "$ZFC_INSTALLER_FORMAT" ]] || {
        log_error "当前 install.sh 过旧，目标镜像要求 installer format ${min_installer:-unknown}"
        return 1
    }
    [[ "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+._-][A-Za-z0-9.-]+)?$ ]] || {
        log_error "schema bundle release version 非法: ${release:-missing}"
        return 1
    }
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        log_error "schema bundle SHA-256 非法"
        return 1
    }
    [[ "$commit" == "unknown" || "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        log_error "schema bundle git commit 非法: ${commit:-missing}"
        return 1
    }

    actual=$(sha256_file "$schema")
    [[ "$actual" == "$expected" ]] || {
        log_error "schema bundle 校验失败: manifest=$expected actual=$actual"
        return 1
    }

    printf -v "${prefix}_RELEASE" '%s' "$release"
    printf -v "${prefix}_SHA" '%s' "$expected"
}

# Return codes: 0=new bundle ready, 2=both images are legacy, 1=invalid/partial release.
prepare_schema_bundle() {
    local web_image="$1" controler_image="$2"
    local root web_dir controler_dir web_ok=0 controler_ok=0
    local WEB_RELEASE WEB_SHA CONTROLER_RELEASE CONTROLER_SHA

    root=$(mktemp -d)
    web_dir="$root/zf-web"
    controler_dir="$root/zf-controler"

    extract_schema_bundle_from_image "$web_image" "$web_dir" && web_ok=1
    extract_schema_bundle_from_image "$controler_image" "$controler_dir" && controler_ok=1

    if [[ "$web_ok" -eq 0 && "$controler_ok" -eq 0 ]]; then
        rm -rf "$root"
        return 2
    fi
    if [[ "$web_ok" -ne 1 || "$controler_ok" -ne 1 ]]; then
        rm -rf "$root"
        log_error "检测到不完整发布：zf-web/zf-controler 只有一个镜像包含 schema bundle"
        return 1
    fi

    validate_schema_bundle "$web_dir" WEB || { rm -rf "$root"; return 1; }
    validate_schema_bundle "$controler_dir" CONTROLER || { rm -rf "$root"; return 1; }

    if [[ "$WEB_RELEASE" != "$CONTROLER_RELEASE" || "$WEB_SHA" != "$CONTROLER_SHA" ]]; then
        rm -rf "$root"
        log_error "zf-web 与 zf-controler 的 release/schema 指纹不一致，拒绝迁移"
        return 1
    fi

    SCHEMA_BUNDLE_ROOT="$root"
    SCHEMA_SOURCE="image-bundle"
    EXPECTED_SCHEMA_SHA256="$WEB_SHA"
    TARGET_SCHEMA_RELEASE="$WEB_RELEASE"
    ZF_WEB_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$web_image" 2>/dev/null)
    ZF_CONTROLER_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$controler_image" 2>/dev/null)

    [[ "$ZF_WEB_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "$ZF_CONTROLER_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1

    log_success "目标 schema bundle 已验证: release=$TARGET_SCHEMA_RELEASE sha=${EXPECTED_SCHEMA_SHA256:0:12}..."
}

install_verified_schema_bundle() {
    local source="$SCHEMA_BUNDLE_ROOT/zf-web/schema.prisma"
    local temp="prisma/schema.prisma.bundle-new"
    mkdir -p prisma
    cp "$source" "$temp"
    [[ "$(sha256_file "$temp")" == "$EXPECTED_SCHEMA_SHA256" ]] || {
        rm -f "$temp"
        log_error "复制 schema bundle 后校验失败"
        return 1
    }
    mv "$temp" prisma/schema.prisma
    rm -rf prisma/migrate-hooks
    rm -rf prisma/migrate-hooks-applied
    mkdir -p prisma/migrate-hooks
    if [[ -d "$SCHEMA_BUNDLE_ROOT/zf-web/hooks" ]]; then
        cp -a "$SCHEMA_BUNDLE_ROOT/zf-web/hooks/." prisma/migrate-hooks/
    fi
}

prepare_schema_state_sql() {
    local sql_file="prisma/.zfc_schema_state.sql" hook hook_id hook_sha
    [[ "$SCHEMA_SOURCE" == "image-bundle" ]] || {
        rm -f "$sql_file"
        return 0
    }

    [[ "$TARGET_SCHEMA_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+._-][A-Za-z0-9.-]+)?$ ]]
    [[ "$EXPECTED_SCHEMA_SHA256" =~ ^[0-9a-f]{64}$ ]]
    [[ "$ZF_WEB_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]
    [[ "$ZF_CONTROLER_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]

    cat > "$sql_file" <<SQL
INSERT INTO "ZfcSchemaState" (
  "id", "status", "releaseVersion", "schemaArtifactSha256",
  "zfWebImageDigest", "zfControlerImageDigest", "operationId",
  "appliedAt", "updatedAt"
) VALUES (
  1, 'stable', '$TARGET_SCHEMA_RELEASE', '$EXPECTED_SCHEMA_SHA256',
  '$ZF_WEB_IMAGE_ID', '$ZF_CONTROLER_IMAGE_ID', NULL,
  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
)
ON CONFLICT ("id") DO UPDATE SET
  "status" = EXCLUDED."status",
  "releaseVersion" = EXCLUDED."releaseVersion",
  "schemaArtifactSha256" = EXCLUDED."schemaArtifactSha256",
  "zfWebImageDigest" = EXCLUDED."zfWebImageDigest",
  "zfControlerImageDigest" = EXCLUDED."zfControlerImageDigest",
  "operationId" = NULL,
  "appliedAt" = EXCLUDED."appliedAt",
  "updatedAt" = CURRENT_TIMESTAMP;
SQL

    for hook in prisma/migrate-hooks/*.sql; do
        [[ -f "$hook" ]] || continue
        hook_id=$(basename "$hook")
        [[ "$hook_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        hook_sha=$(sha256_file "$hook")
        [[ "$hook_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
        cat >> "$sql_file" <<SQL
INSERT INTO "ZfcSchemaHook" ("id", "checksum", "appliedAt")
VALUES ('$hook_id', '$hook_sha', CURRENT_TIMESTAMP)
ON CONFLICT ("id") DO UPDATE SET "checksum" = EXCLUDED."checksum"
WHERE "ZfcSchemaHook"."checksum" = EXCLUDED."checksum";
SQL
    done
}

# 已祝福的「被取代」hook checksum 白名单。某个 migrate-hook 在发布并被存量库应用后,如确有必要
# 对它做 *语义等价* 的内容微调(对存量库的作用完全一致、且幂等),把它**此前**的 checksum 列在
# 对应 hook 名下。preflight 见到账本里记的是这些旧 checksum、而目标镜像带的是不同的新内容时,
# 不按「篡改历史 hook」拒绝,而是把账本就地校准到新 checksum 并跳过重跑。其余 checksum 不一致
# 仍视为篡改拒绝。新增等价修订时,在对应 hook 名下追加被取代的旧 sha(每行一个)。
hook_superseded_checksums() {
    case "$1" in
        0002_prune_legacy_forwarder_task.sql)
            # f059935e…: 初版(EXISTS "ForwarderTask" 子句写在外层 IF 条件里,全新安装时
            #            PL/pgSQL 一次性 plan 整个条件 → 42P01 → P1014;存量库已正常应用)。
            # bbf0efc6…: 旧 install.sh [临时规避] 去注释覆盖版。
            # 二者对存量库的作用与当前「内层 IF 才引用表」版完全等价、幂等。
            printf '%s\n' \
                f059935e268787afd80a90a01e27f98923ff21551d29faff419d9c22414127ab \
                bbf0efc60152b5f27e5b0cb70113f41bfb7d76d5c51513056850731dbeafe152
            ;;
    esac
}

preflight_current_schema_state() {
    local db_url="$1" network_arg="$2"
    [[ "$SCHEMA_SOURCE" == "image-bundle" ]] || return 0

    local psql_url="${db_url%%\?*}"
    local row current_status current_release current_sha newest hook hook_id hook_sha recorded_sha
    row=$(docker run --rm $network_arg postgres:15-alpine \
        psql "$psql_url" -At -F '|' -c \
        'SELECT "status", "releaseVersion", "schemaArtifactSha256" FROM "ZfcSchemaState" WHERE "id" = 1' \
        2>/dev/null) || {
        log_info "未检测到 schema 账本，将按 legacy 数据库自动接管"
        return 0
    }
    [[ -n "$row" ]] || {
        log_info "schema 账本为空，将按 legacy 数据库自动接管"
        return 0
    }

    IFS='|' read -r current_status current_release current_sha <<< "$row"
    [[ "$current_status" == "stable" ]] || {
        log_error "数据库 schema 状态为 $current_status，上一次迁移可能未完成"
        return 1
    }
    [[ "$current_sha" =~ ^[0-9a-f]{64}$ ]] || {
        log_error "数据库中的 schema fingerprint 非法"
        return 1
    }

    if [[ "$current_release" == "$TARGET_SCHEMA_RELEASE" && "$current_sha" != "$EXPECTED_SCHEMA_SHA256" ]]; then
        log_error "相同 release version 对应不同 schema，疑似覆盖了已发布 tag，拒绝迁移"
        return 1
    fi

    if [[ "$current_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$TARGET_SCHEMA_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        newest=$(printf '%s\n%s\n' "$current_release" "$TARGET_SCHEMA_RELEASE" | sort -V | tail -1)
        if [[ "$newest" == "$current_release" && "$current_release" != "$TARGET_SCHEMA_RELEASE" ]]; then
            if [[ "${ZFC_ALLOW_SCHEMA_DOWNGRADE:-0}" != "1" ]]; then
                log_error "检测到 schema 降级 $current_release -> $TARGET_SCHEMA_RELEASE，默认拒绝"
                log_error "确认已备份且接受数据风险后，设置 ZFC_ALLOW_SCHEMA_DOWNGRADE=1 重试"
                return 1
            fi
            log_warning "已显式允许 schema 降级 $current_release -> $TARGET_SCHEMA_RELEASE"
        fi
    fi

    for hook in prisma/migrate-hooks/*.sql; do
        [[ -f "$hook" ]] || continue
        hook_id=$(basename "$hook")
        hook_sha=$(sha256_file "$hook")
        recorded_sha=$(docker run --rm $network_arg postgres:15-alpine \
            psql "$psql_url" -At -c \
            "SELECT \"checksum\" FROM \"ZfcSchemaHook\" WHERE \"id\" = '$hook_id'" \
            2>/dev/null) || recorded_sha=""
        if [[ -n "$recorded_sha" && "$recorded_sha" != "$hook_sha" ]]; then
            # 账本里记的旧 checksum 若是该 hook 的「已祝福被取代版本」(语义等价、幂等),
            # 不按篡改拒绝:就地把账本校准到目标 checksum 并跳过重跑(内容等价,无需再执行)。
            if hook_superseded_checksums "$hook_id" | grep -qxF "$recorded_sha"; then
                log_warning "hook $hook_id 内容已升级为语义等价新版本(账本 ${recorded_sha:0:12}… → 目标 ${hook_sha:0:12}…)，校准账本后跳过重跑"
                if ! docker run --rm $network_arg postgres:15-alpine \
                    psql "$psql_url" -v ON_ERROR_STOP=1 -At -c \
                    "UPDATE \"ZfcSchemaHook\" SET \"checksum\" = '$hook_sha', \"appliedAt\" = CURRENT_TIMESTAMP WHERE \"id\" = '$hook_id'" \
                    >/dev/null 2>&1; then
                    log_error "校准已应用 hook $hook_id 的账本 checksum 失败"
                    return 1
                fi
                mkdir -p prisma/migrate-hooks-applied
                mv "$hook" prisma/migrate-hooks-applied/
                continue
            fi
            log_error "已应用 hook $hook_id 的 checksum 与目标镜像不同，拒绝篡改历史 hook"
            return 1
        fi
        if [[ "$recorded_sha" == "$hook_sha" ]]; then
            mkdir -p prisma/migrate-hooks-applied
            mv "$hook" prisma/migrate-hooks-applied/
            log_info "跳过已应用 schema hook: $hook_id"
        fi
    done
}

# zfc-admin 直连数据库(Prisma client)。当镜像里编译进的 schema 比数据库实际已应用的 schema 新
# (例如只换了镜像没跑迁移, 或 zfc-admin 与 zf-web/zf-controler 版本不一致)时, 任意整行 SELECT
# 都会触发晦涩的 Prisma P2022(列不存在)。本函数比较 zfc-admin 镜像的 schema 指纹标签
# (com.zeroforwarder.schema-sha256, 由 build-images.sh 打入) 与数据库 ZfcSchemaState 账本里
# 已应用的 schema 指纹, 不一致时给出可执行的修复指引。
# Fail-safe: 任何"无法确证不一致"的情况(legacy zfc-admin 无标签 / 账本缺失为空 / 查询失败)
# 一律 return 0 放行, 绝不挡正常环境。
verify_zfc_admin_schema_matches_db() {
    local db_url="$1" network_args="$2"
    local admin_sha ledger_sha psql_url

    # 镜像尚未拉到本地(inspect 只看本地镜像仓库): 无从比较, 放行但留下线索,
    # 以便随后 docker run 隐式拉取后若真出现 P2022 时能定位。
    if ! docker image inspect "$ZFC_ADMIN_IMAGE" >/dev/null 2>&1; then
        log_info "zfc-admin 镜像($ZFC_ADMIN_IMAGE)尚未拉到本地, 跳过 schema 一致性预检"
        return 0
    fi
    admin_sha=$(docker image inspect \
        --format '{{ index .Config.Labels "com.zeroforwarder.schema-sha256" }}' \
        "$ZFC_ADMIN_IMAGE" 2>/dev/null) || admin_sha=""
    # Legacy zfc-admin(未 schema 版本化, 无指纹标签): 无从比较, 放行。
    [[ "$admin_sha" =~ ^[0-9a-f]{64}$ ]] || return 0

    psql_url="${db_url%%\?*}"
    ledger_sha=$(docker run --rm $network_args postgres:15-alpine \
        psql "$psql_url" -At -c \
        'SELECT "schemaArtifactSha256" FROM "ZfcSchemaState" WHERE "id" = 1' \
        2>/dev/null) || return 0
    # 账本缺失/为空(legacy 数据库): 无从比较, 放行。
    [[ "$ledger_sha" =~ ^[0-9a-f]{64}$ ]] || return 0

    if [[ "$admin_sha" != "$ledger_sha" ]]; then
        log_error "zfc-admin 镜像的 schema 与数据库已应用的 schema 不一致:"
        log_error "  zfc-admin 期望 schema: ${admin_sha:0:12}..."
        log_error "  数据库已应用 schema:   ${ledger_sha:0:12}..."
        log_error "直接执行会触发 Prisma P2022(列不存在)。"
        log_error "请确保 zf-web / zf-controler / zfc-admin 为同一版本, 并执行 更新镜像(保留数据) 同步数据库 schema 后重试。"
        return 1
    fi
    return 0
}

verify_target_image_ids() {
    [[ "$SCHEMA_SOURCE" == "image-bundle" ]] || return 0
    local web_now controler_now
    web_now=$(docker image inspect --format '{{.Id}}' "$ZF_WEB_IMAGE" 2>/dev/null)
    controler_now=$(docker image inspect --format '{{.Id}}' "$ZF_CONTROLER_IMAGE" 2>/dev/null)
    if [[ "$web_now" != "$ZF_WEB_IMAGE_ID" || "$controler_now" != "$ZF_CONTROLER_IMAGE_ID" ]]; then
        log_error "迁移期间目标镜像 tag 发生变化，拒绝启动未验证的镜像"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 版本钉死 (design: docs/design/install-migration-version-pinning.md)
#
# 背景: .env 里的 ZF_WEB_IMAGE=...:latest 一个字段同时表达「跟随最新」(意图) 与
# 「现在跑什么」(事实)。迁移/重启时后者丢失 → 老库配新镜像 → 启动门禁拦下。
# 修法: ZFC_UPDATE_CHANNEL 存意图, 镜像引用钉死存事实。
# ─────────────────────────────────────────────────────────────────────────────

# 从镜像引用剥出 repo 前缀(去掉 tag / digest)。
# 必须处理带端口的 registry: host:5000/zf-web:tag → host:5000/zf-web
# (只有当最后一个路径段里含 ':' 时才是 tag, 否则那个 ':' 属于 registry 端口)
image_repo_prefix() {
    local ref="${1%%@*}"          # 先去掉 @sha256:... digest 部分
    local last="${ref##*/}"       # 最后一个路径段
    [[ "$last" == *:* ]] && ref="${ref%:*}"
    printf '%s' "$ref"
}

# 取 digest 的 manifest 部分(@sha256: 之后的 64 hex)。
# 跨 registry mirror 时 repo 前缀不同但 manifest 相同, 比整串会恒不等。
digest_manifest_part() {
    local d="$1"
    printf '%s' "${d##*@}"
}

# 原子地 upsert 若干 .env 键。用法: write_env_keys_atomic "KEY=VAL" ...
#
# 为什么不用 sed_inplace: `sed 's/^KEY=.*/KEY=new/'` 对**不存在的键是 no-op**,
# 不会新增行。存量 .env 没有 ZFC_UPDATE_CHANNEL, 纯 sed 会把镜像键改对而该键
# 永远加不进去 (且「缺省兜底 latest」会掩盖这个 bug, 只有用户显式钉版本时才暴露)。
# 这里一次性构造完整内容 → 临时文件 → 单次 mv, 兼顾原子性与「存在则替换/不存在则追加」。
write_env_keys_atomic() {
    local file=".env"
    local -a pairs=("$@")
    local -a out=() handled=()
    local line key i replaced tmp

    [[ ${#pairs[@]} -gt 0 ]] || return 0
    if [[ ! -f "$file" ]]; then
        log_error "write_env_keys_atomic: $file 不存在"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        replaced=0
        for i in "${!pairs[@]}"; do
            key="${pairs[$i]%%=*}"
            if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
                out+=("${pairs[$i]}")
                handled[$i]=1
                replaced=1
                break
            fi
        done
        (( replaced )) || out+=("$line")
    done < "$file"

    # 未命中的键追加到末尾
    for i in "${!pairs[@]}"; do
        [[ "${handled[$i]:-0}" == "1" ]] && continue
        out+=("${pairs[$i]}")
    done

    tmp="${file}.tmp.$$"
    if ! printf '%s\n' "${out[@]}" > "$tmp"; then
        rm -f "$tmp"
        log_error "write_env_keys_atomic: 写临时文件失败(磁盘空间?)"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        log_error "write_env_keys_atomic: 替换 $file 失败"
        return 1
    fi
    chmod 600 "$file" 2>/dev/null || true
}

# 清理 .env.pre-update-* / .env.pre-restore-* 备份(含明文密钥, 不能无限堆积)。
# 注意: 不能复用 cleanup_old_backups —— 它硬编码 backup_dir="schema_backup" 且目录
# 不存在就 return 0, 扫不到工作目录根下的 .env.pre-*。
cleanup_env_backups() {
    [[ "${ZFC_BACKUP_AUTOCLEAN:-1}" == "1" ]] || return 0
    local keep_count="${ZFC_BACKUP_RETAIN_COUNT:-5}"
    [[ "$keep_count" =~ ^[0-9]+$ ]] || keep_count=5
    (( keep_count >= 1 )) || keep_count=1   # 0 会删光, 至少留最近一份
    local pattern f idx
    for pattern in ".env.pre-update-*" ".env.pre-restore-*"; do
        idx=0
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            idx=$((idx + 1))
            if (( idx > keep_count )); then
                rm -f "$f" 2>/dev/null || true
            fi
        done < <(ls -t $pattern 2>/dev/null)
    done
    return 0
}

# prepare_schema_bundle 会写一批全局变量, 且 zfc_on_exit 只清「当前」SCHEMA_BUNDLE_ROOT
# 指针。本设计在 update/restore 两条路径新增了调用点, 而 update_schema 内部还会再调
# 一次 —— 不复位会导致 mktemp 目录泄漏, 交互菜单里还会串味到下一个动作。
# 用法: snapshot=$(schema_bundle_globals_save); ...; schema_bundle_globals_restore "$snapshot"
schema_bundle_globals_save() {
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
        "${SCHEMA_SOURCE:-}" "${EXPECTED_SCHEMA_SHA256:-}" "${TARGET_SCHEMA_RELEASE:-}" \
        "${ZF_WEB_IMAGE_ID:-}" "${ZF_CONTROLER_IMAGE_ID:-}" "${SCHEMA_BUNDLE_ROOT:-}"
}

schema_bundle_globals_restore() {
    local IFS=$'\x1f'
    local -a s=()
    read -r -a s <<< "$1"
    # 只清「本次调用新建的」目录: 与快照不同才是新的。
    # prepare_schema_bundle 的失败分支自己已 rm -rf 并且不改全局, 此时 SCHEMA_BUNDLE_ROOT
    # 仍是上一次的值 —— 不做这个比较会把别人还在用的目录删掉。
    if [[ -n "${SCHEMA_BUNDLE_ROOT:-}" && "${SCHEMA_BUNDLE_ROOT}" != "${s[5]:-}" && -d "${SCHEMA_BUNDLE_ROOT}" ]]; then
        rm -rf "$SCHEMA_BUNDLE_ROOT"
    fi
    SCHEMA_SOURCE="${s[0]:-}"
    EXPECTED_SCHEMA_SHA256="${s[1]:-}"
    TARGET_SCHEMA_RELEASE="${s[2]:-}"
    ZF_WEB_IMAGE_ID="${s[3]:-}"
    ZF_CONTROLER_IMAGE_ID="${s[4]:-}"
    SCHEMA_BUNDLE_ROOT="${s[5]:-}"
}

# 从运行中的库读 schema 账本(id=1)。输出 \x1f 分隔的五字段, 读不到返回 1。
# 账本是「这份数据属于哪个 release」的权威来源 —— 比 .env 可靠, 因为 .env 里
# 常年写着 :latest 这种活动指针。psql -At 下 NULL 直接渲染成空串, 无需 coalesce。
read_schema_ledger_from_db() {
    local sql out
    sql='SELECT "status","releaseVersion","schemaArtifactSha256","zfWebImageDigest","zfControlerImageDigest" FROM "ZfcSchemaState" WHERE "id"=1'
    out=$($DOCKER_COMPOSE_CMD exec -T postgres psql -U postgres -d zfc -At -F $'\x1f' -c "$sql" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# 取镜像的 registry digest(repo@sha256:...) —— 跨机器可 pull 的引用。
# 注意 .Id 是本地 config digest, 不能用来 pull; 本地 build 从未 push 的镜像
# RepoDigests 为空, 属正常情况(开发环境), 调用方须容忍缺省。
image_repo_digest() {
    local d
    d=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null) || return 1
    [[ -n "$d" ]] || return 1
    printf '%s' "$d"
}

# 从 pg_dump 文本反解 schema 账本。输出 "status\x1fversion\x1fsha", 解不出返回 1。
#
# 为什么必须按列名定位而不是固定列号: pg_dump 默认输出 COPY 格式(见 pack 未带
# --inserts), 列序由建表时的 attnum 决定。将来任何一次在 releaseVersion **之前**
# 插入新列的迁移, 都会让同一个解析器对老 dump 解出 1.1.67、对新 dump 解出 "stable"
# (把 status 当版本号) —— 且不报错。静默解错版本比解析失败危险得多。
#
# COPY 数据行的字面规则: 分隔符是 tab, 空值是 \N, 字段内 tab/换行/反斜杠被转义为
# \t/\n/\\。真实 dump 里 appliedAt 值形如 "2026-08-05 16:14:57.445" —— 含空格,
# 所以绝不能用空格切分(现在只取两个字段碰巧能用, 一扩展就错)。
parse_ledger_from_dump() {
    local dump="$1"
    local header cols line i
    local idx_status=-1 idx_ver=-1 idx_sha=-1
    local status ver sha

    [[ -s "$dump" ]] || return 1

    # ── COPY 格式 ──
    header=$(grep -m1 -E '^COPY[[:space:]]+(public\.)?"ZfcSchemaState"[[:space:]]*\(' "$dump" 2>/dev/null || true)
    if [[ -n "$header" ]]; then
        cols="${header#*\(}"; cols="${cols%%)*}"
        cols="${cols//\"/}"; cols="${cols// /}"
        local IFS=','
        local -a carr=($cols)
        unset IFS
        for i in "${!carr[@]}"; do
            case "${carr[$i]}" in
                status)               idx_status=$i ;;
                releaseVersion)       idx_ver=$i ;;
                schemaArtifactSha256) idx_sha=$i ;;
            esac
        done
        (( idx_status >= 0 && idx_ver >= 0 && idx_sha >= 0 )) || return 1
        # 头之后第一行就是数据行(账本恒 id=1 单行, 见 prepare_schema_state_sql 的
        # ON CONFLICT ("id") DO UPDATE)。遇到 \. 说明该表无数据。
        line=$(grep -A1 -m1 -F "$header" "$dump" | tail -1)
        [[ -n "$line" && "$line" != '\.' ]] || return 1
        local IFS=$'\t'
        local -a farr=($line)
        unset IFS
        status="${farr[$idx_status]:-}"; ver="${farr[$idx_ver]:-}"; sha="${farr[$idx_sha]:-}"
    else
        # ── INSERT 格式(ZFC_BACKUP_FULL 或将来改用 --inserts) ──
        header=$(grep -m1 -E '^INSERT INTO[[:space:]]+(public\.)?"ZfcSchemaState"[[:space:]]*\(' "$dump" 2>/dev/null || true)
        [[ -n "$header" ]] || return 1
        cols="${header#*\(}"; cols="${cols%%)*}"
        cols="${cols//\"/}"; cols="${cols// /}"
        local IFS=','
        local -a carr=($cols)
        unset IFS
        for i in "${!carr[@]}"; do
            case "${carr[$i]}" in
                status)               idx_status=$i ;;
                releaseVersion)       idx_ver=$i ;;
                schemaArtifactSha256) idx_sha=$i ;;
            esac
        done
        (( idx_status >= 0 && idx_ver >= 0 && idx_sha >= 0 )) || return 1
        local vals="${header#*VALUES}"; vals="${vals#*\(}"; vals="${vals%%);*}"
        local -a varr=()
        local cur="" inq=0 ch
        for (( i=0; i<${#vals}; i++ )); do
            ch="${vals:$i:1}"
            if [[ "$ch" == "'" ]]; then inq=$((1-inq)); cur+="$ch"; continue; fi
            if [[ "$ch" == "," && $inq -eq 0 ]]; then varr+=("$cur"); cur=""; continue; fi
            cur+="$ch"
        done
        varr+=("$cur")
        strip_sql(){ local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"; }
        status=$(strip_sql "${varr[$idx_status]:-}")
        ver=$(strip_sql "${varr[$idx_ver]:-}")
        sha=$(strip_sql "${varr[$idx_sha]:-}")
        unset -f strip_sql
    fi

    # 格式校验: 不符即判定反解失败, 绝不静默采用。正则与 validate_schema_bundle 同源。
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+._-][A-Za-z0-9.-]+)?$ ]] || return 1
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\x1f%s\x1f%s' "$status" "$ver" "$sha"
}

# 解析本次部署的目标版本, 并把钉死的镜像引用 export 到 shell —— **不写 .env 文件**。
#
# 为什么不在这里落盘: install.sh 的 INT trap 只有 `echo; exit 1`, 不恢复备份; zfc_on_exit
# 也只清 SCHEMA_BUNDLE_ROOT。若 resolve 阶段就把 .env 改成新版本, 之后 Ctrl-C 或
# update_schema 失败, 就留下「配置已是新版、库还是老的」的半升级态 —— 任何人一句
# docker compose up -d 就会用新镜像打老库(钉版本后这个状态比 :latest 更隐蔽, 配置看起来
# 「已经是目标版本了」)。所以这里只 export: compose 变量插值中 shell env 优先于 .env 文件,
# 中间步骤照常工作; 文件改写推迟到 update_schema + verify 成功后由 commit_pinned_env 完成。
#
# 用法: resolve_deploy_version <channel> [explicit_version]
# 成功后设置 ZFC_RESOLVED_VERSION(空 = legacy 镜像, 无法钉版本, 沿用 channel 引用)。
resolve_deploy_version() {
    local channel="$1" explicit="${2:-}"
    local pull_tag="${explicit:-$channel}"
    local web_repo ctl_repo snapshot rc version channel_web_id pinned_web_id
    local name repo ref missing=()

    ZFC_RESOLVED_VERSION=""

    if [[ -z "${ZF_WEB_IMAGE:-}" || -z "${ZF_CONTROLER_IMAGE:-}" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "无法解析升级目标: .env 缺少 ZF_WEB_IMAGE / ZF_CONTROLER_IMAGE" || return 1
    fi
    web_repo=$(image_repo_prefix "$ZF_WEB_IMAGE")
    ctl_repo=$(image_repo_prefix "$ZF_CONTROLER_IMAGE")

    # 1) 拉目标引用的 web/controler。直接 docker pull(不是 compose pull): 此刻 .env 未动,
    #    compose 读到的还会是旧引用。
    log_info "解析升级目标: ${pull_tag}${explicit:+ (--to 指定)}"
    if ! docker pull "${web_repo}:${pull_tag}" >/dev/null; then
        die_or_return "$EXIT_IMAGE_PULL" "拉取失败: ${web_repo}:${pull_tag} (tag 不存在? 检查 DOCKER_REGISTRY/网络/凭据)" || return 1
    fi
    if ! docker pull "${ctl_repo}:${pull_tag}" >/dev/null; then
        die_or_return "$EXIT_IMAGE_PULL" "拉取失败: ${ctl_repo}:${pull_tag} (tag 不存在? 检查 DOCKER_REGISTRY/网络/凭据)" || return 1
    fi

    # 2) 从镜像的 schema bundle 解出真实 release 版本(顺带校验 web/controler 指纹一致)
    snapshot=$(schema_bundle_globals_save)
    rc=0
    prepare_schema_bundle "${web_repo}:${pull_tag}" "${ctl_repo}:${pull_tag}" || rc=$?
    if (( rc == 2 )); then
        schema_bundle_globals_restore "$snapshot"
        log_warning "目标镜像不含 schema bundle(legacy 发布)，无法钉版本；沿用 ${pull_tag} 引用"
        ZF_WEB_IMAGE="${web_repo}:${pull_tag}"
        ZF_CONTROLER_IMAGE="${ctl_repo}:${pull_tag}"
        export ZF_WEB_IMAGE ZF_CONTROLER_IMAGE
        # legacy 也要记进专用全局: 否则 update_schema 的 source .env 会把这里解析出的
        # channel/--to 引用冲回 .env 旧值。channel==latest 时冲回是无害的(值相同), 但
        # `--to 1.1.83` 打在 legacy 镜像上就会真的用错镜像去抽 schema。
        ZFC_PINNED_WEB_IMAGE="$ZF_WEB_IMAGE"
        ZFC_PINNED_CTL_IMAGE="$ZF_CONTROLER_IMAGE"
        return 0
    fi
    if (( rc != 0 )); then
        schema_bundle_globals_restore "$snapshot"
        die_or_return "$EXIT_SCHEMA_MIGRATION" "目标镜像 schema bundle 校验失败(不完整发布或指纹不一致)" || return 1
    fi
    version="$TARGET_SCHEMA_RELEASE"
    channel_web_id="$ZF_WEB_IMAGE_ID"
    schema_bundle_globals_restore "$snapshot"

    # 3) 存在性预检: 五个业务镜像的版本 tag 必须齐。
    #    用 docker pull 而不是 docker manifest inspect —— 私有 registry 允许 pull 却可能
    #    对 manifest API 支持不稳, 那样会「镜像明明在却被整体拦死」。
    #    zfc-prisma 不参与: 它不在 release-all.sh 的版本化发布列表, 恒 latest。
    for name in zf-web zf-controler rrd-service zfc-util zfc-admin; do
        case "$name" in
            zf-web)       ref="${ZF_WEB_IMAGE:-}" ;;
            zf-controler) ref="${ZF_CONTROLER_IMAGE:-}" ;;
            rrd-service)  ref="${RRD_SERVICE_IMAGE:-}" ;;
            zfc-util)     ref="${ZFC_UTIL_IMAGE:-}" ;;
            zfc-admin)    ref="${ZFC_ADMIN_IMAGE:-}" ;;
        esac
        [[ -n "$ref" ]] || continue          # .env 未配置该镜像 → 本就不部署, 跳过
        repo=$(image_repo_prefix "$ref")
        if ! docker pull "${repo}:${version}" >/dev/null 2>&1; then
            missing+=("${repo}:${version}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "以下镜像缺少 ${version} 版本 tag:"
        for ref in "${missing[@]}"; do log_error "  - $ref"; done
        log_error "拒绝「部分钉版本」: 若只钉一部分, 版本错配会被 verify_zfc_admin_schema_matches_db"
        log_error "(fail-safe 设计, 无标签/账本空/查询失败一律放行) 放过, 最终在运行时报 Prisma P2022。"
        # 逃生开关只对着屏幕前的人开, 不对自动化开 —— 否则无人值守升级会静默放行错配。
        if [[ "${ZFC_ALLOW_PARTIAL_VERSION_PIN:-0}" == "1" && "$ZFC_NONINTERACTIVE" != "1" ]]; then
            log_warning "ZFC_ALLOW_PARTIAL_VERSION_PIN=1: 放行, 上述镜像将保留原引用"
            log_warning "升级后请手工确认 zfc-admin 可用(查看管理员 Token 不报 P2022)"
        else
            [[ "${ZFC_ALLOW_PARTIAL_VERSION_PIN:-0}" == "1" ]] && \
                log_error "(非交互模式下 ZFC_ALLOW_PARTIAL_VERSION_PIN 不生效)"
            die_or_return "$EXIT_IMAGE_PULL" "目标版本 ${version} 的镜像不齐, 拒绝升级" || return 1
        fi
    fi

    # 4) latest 自洽性: latest 与它应指向的版本 tag 必须是同一 manifest。
    #    只在「跟随 latest」时有意义 —— --to 回滚时 latest 本就不等于目标版本,
    #    此处若不跳过会把合法回滚当成发布事故拦下。
    if [[ -z "$explicit" && "$channel" == "latest" ]]; then
        pinned_web_id=$(docker image inspect --format '{{.Id}}' "${web_repo}:${version}" 2>/dev/null || true)
        if [[ -n "$channel_web_id" && -n "$pinned_web_id" && "$channel_web_id" != "$pinned_web_id" ]]; then
            die_or_return "$EXIT_IMAGE_PULL" "registry 上 latest 与 ${version} 指向不同镜像(疑似发布事故), 拒绝升级" || return 1
        fi
    fi

    # 5) 只 export, 不落盘。
    #    逃生开关放行时, 缺版本 tag 的那几个必须**真的**保留原引用 —— 否则会钉到一个
    #    registry 上不存在的 tag, 下次 compose pull 直接 404, 比不钉更糟。
    local missing_list=" ${missing[*]:-} "
    pin_one() {                      # pin_one <varname>
        # 注意: 不能写 ${!var:-} —— bash 3.2 报 invalid indirect expansion
        local var="$1" pinned cur
        cur="${!var}"
        [[ -n "$cur" ]] || return 0
        pinned="$(image_repo_prefix "$cur"):${version}"
        if [[ "$missing_list" == *" $pinned "* ]]; then
            log_warning "保留原引用(该版本 tag 不存在): $cur"
            return 0
        fi
        printf -v "$var" '%s' "$pinned"
    }
    pin_one ZF_WEB_IMAGE
    pin_one ZF_CONTROLER_IMAGE
    pin_one RRD_SERVICE_IMAGE
    pin_one ZFC_UTIL_IMAGE
    pin_one ZFC_ADMIN_IMAGE
    unset -f pin_one
    export ZF_WEB_IMAGE ZF_CONTROLER_IMAGE RRD_SERVICE_IMAGE ZFC_UTIL_IMAGE ZFC_ADMIN_IMAGE

    # 记进专用全局: source .env 会冲掉上面的 export, 这组不会(见其声明处的说明)。
    ZFC_PINNED_WEB_IMAGE="$ZF_WEB_IMAGE";       ZFC_PINNED_CTL_IMAGE="$ZF_CONTROLER_IMAGE"
    ZFC_PINNED_RRD_IMAGE="${RRD_SERVICE_IMAGE:-}"; ZFC_PINNED_UTIL_IMAGE="${ZFC_UTIL_IMAGE:-}"
    ZFC_PINNED_ADMIN_IMAGE="${ZFC_ADMIN_IMAGE:-}"

    ZFC_RESOLVED_VERSION="$version"
    return 0
}

# 从镜像引用取出 tag(去掉 digest / 处理 host:port registry)。
# 无 tag 或仅 digest → 输出空串。
image_ref_tag() {
    local ref="${1%%@*}"
    local last="${ref##*/}"
    if [[ "$last" == *:* ]]; then
        printf '%s' "${last##*:}"
    else
        printf '%s' ""
    fi
}

# --to / 手动输入共用的版本号形态(与 parse_args 校验一致)。
# 例: 1.1.70 / 1.1.70-rc1 / 1.1.70+build
ZFC_VERSION_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+([+._-][A-Za-z0-9.-]+)?$'

# 交互选择升级目标, 写入 channel_var / explicit_var。
#
# 语义(对齐 issue #74 + 版本钉死设计 + 双席评审):
#   默认(回车) / 无 tty  → 沿用 ZFC_UPDATE_CHANNEL(与 -y 非交互一致, 不强制 latest)
#   1) latest          → channel=latest,  explicit=空  → 跟随最新; 成功后写回 channel=latest
#   2) .env 中的版本
#        - ZFC_UPDATE_CHANNEL 为具体版本 → 作为 channel(长期意图, 成功后写回)
#        - channel 仍是 latest 且镜像 tag 为具体版本 → 作为 explicit 一次性目标
#          (恢复「改 .env 镜像 tag 再 --update」; **不**把 fact 提升为长期 channel)
#        - 两者都是 latest → 等同选项 1
#   3) 手动输入        → channel 保持 .env 原值, explicit=用户输入
#                       (等价 --to: 一次性, 不写回 channel)
#
# 非交互 / 已有 ZFC_UPDATE_TO: 不提问, 沿用 ZFC_UPDATE_CHANNEL + ZFC_UPDATE_TO。
# 用法: select_update_target_version <channel_var> <explicit_var>
# 失败(交互读失败等) return 1。
select_update_target_version() {
    local __ch_var="$1" __ex_var="$2"
    local env_channel="${ZFC_UPDATE_CHANNEL:-latest}"
    local current_tag
    current_tag=$(image_ref_tag "${ZF_WEB_IMAGE:-}")

    # 选项 2 的「.env 版本」分解:
    # - channel_pin: 长期通道里写死的具体版本(非 latest)
    # - image_pin:   镜像键上的具体 tag(S1 钉死后常见; 或用户手改 tag)
    local channel_pin="" image_pin=""
    if [[ -n "$env_channel" && "$env_channel" != "latest" ]]; then
        channel_pin="$env_channel"
    fi
    if [[ -n "$current_tag" && "$current_tag" != "latest" ]]; then
        image_pin="$current_tag"
    fi

    # 非交互: 不提问(agent / -y / --detach 路径保持契约不变)。
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        printf -v "$__ch_var" '%s' "$env_channel"
        printf -v "$__ex_var" '%s' "${ZFC_UPDATE_TO:-}"
        return 0
    fi

    # 已通过 --to / 环境变量指定一次性目标: 跳过菜单, 仍打印说明。
    if [[ -n "${ZFC_UPDATE_TO:-}" ]]; then
        log_info "已指定一次性目标版本(--to): ${ZFC_UPDATE_TO} (不写回 ZFC_UPDATE_CHANNEL=${env_channel})"
        printf -v "$__ch_var" '%s' "$env_channel"
        printf -v "$__ex_var" '%s' "$ZFC_UPDATE_TO"
        return 0
    fi

    # 默认=沿用当前通道(与 -y 一致); 不是无脑 latest。
    local default_label="当前通道 ${env_channel}"
    local choice="" manual=""
    echo
    log_info "选择升级目标版本:"
    echo "  当前部署: ${current_tag:-unknown}    升级通道: ${env_channel}"
    echo "  1) latest          — 跟随 registry 最新发布(成功后写回通道=latest)"
    if [[ -n "$channel_pin" ]]; then
        echo "  2) .env 中的版本   — ${channel_pin} (ZFC_UPDATE_CHANNEL; 成功后写回为长期通道)"
    elif [[ -n "$image_pin" ]]; then
        echo "  2) .env 中的版本   — ${image_pin} (ZF_WEB_IMAGE tag; 一次性, 通道仍为 ${env_channel})"
    else
        echo "  2) .env 中的版本   — latest(与选项 1 相同)"
    fi
    echo "  3) 手动输入        — 一次性目标(等价 --to, 不写回 ZFC_UPDATE_CHANNEL)"
    echo "  回车默认: ${default_label} (与非交互 -y 一致)"
    echo

    while true; do
        # 同 ask/confirm: 提示写 /dev/tty, 避免 2>/dev/null 吞提示导致界面像卡死。
        printf '请选择 [1-3, 默认=当前通道]: ' >/dev/tty 2>/dev/null
        if ! read choice </dev/tty 2>/dev/null; then
            # 无 tty 的交互态(极少): 沿用通道, 与 -y / 回车默认一致; 禁止 fail-open 到 latest。
            log_warning "无法读取终端输入, 沿用 ZFC_UPDATE_CHANNEL=${env_channel}"
            printf -v "$__ch_var" '%s' "$env_channel"
            printf -v "$__ex_var" '%s' ""
            return 0
        fi
        # 回车 → 沿用当前通道(改造前与 -y 语义); 不是强制选项 1 latest。
        if [[ -z "$choice" ]]; then
            printf -v "$__ch_var" '%s' "$env_channel"
            printf -v "$__ex_var" '%s' ""
            log_info "升级目标: ${env_channel} (默认=沿用 ZFC_UPDATE_CHANNEL, 与 -y 一致)"
            return 0
        fi
        case "$choice" in
            1)
                printf -v "$__ch_var" '%s' "latest"
                printf -v "$__ex_var" '%s' ""
                log_info "升级目标: latest (长期通道将写为 latest)"
                return 0
                ;;
            2)
                if [[ -n "$channel_pin" ]]; then
                    # 长期意图: 写回 channel。
                    printf -v "$__ch_var" '%s' "$channel_pin"
                    printf -v "$__ex_var" '%s' ""
                    log_info "升级目标: ${channel_pin} (ZFC_UPDATE_CHANNEL, 成功后写回)"
                elif [[ -n "$image_pin" ]]; then
                    # 镜像 tag 是 fact 不是 intent: 一次性 explicit, 通道保持 latest(或原值)。
                    printf -v "$__ch_var" '%s' "$env_channel"
                    printf -v "$__ex_var" '%s' "$image_pin"
                    log_info "升级目标: ${image_pin} (来自 ZF_WEB_IMAGE tag, 一次性, 不写回通道=${env_channel})"
                else
                    printf -v "$__ch_var" '%s' "latest"
                    printf -v "$__ex_var" '%s' ""
                    log_info "升级目标: latest (.env 中亦为 latest)"
                fi
                return 0
                ;;
            3)
                while true; do
                    printf '请输入目标版本 (如 1.1.70): ' >/dev/tty 2>/dev/null
                    if ! read manual </dev/tty 2>/dev/null; then
                        die_or_return "$EXIT_MISSING_INPUT" "无终端可输入目标版本; 请用 --to <version> 或 -y + ZFC_UPDATE_TO" || return 1
                    fi
                    manual="${manual//[[:space:]]/}"
                    if [[ -z "$manual" ]]; then
                        log_error "版本号不能为空"
                        continue
                    fi
                    if [[ "$manual" =~ $ZFC_VERSION_TAG_RE ]]; then
                        break
                    fi
                    log_error "版本号非法: ${manual} (需形如 1.1.70)"
                done
                # 长期通道保持 .env 原值; 仅本次用 explicit(同 --to 契约)。
                printf -v "$__ch_var" '%s' "$env_channel"
                printf -v "$__ex_var" '%s' "$manual"
                log_info "升级目标: ${manual} (一次性, 不写回 ZFC_UPDATE_CHANNEL=${env_channel})"
                return 0
                ;;
            *)
                log_error "请输入 1、2 或 3"
                ;;
        esac
    done
}

# 取 migration_info.json 里 release.<key> 的值(标量字段)。
migration_info_release_value() {
    local file="$1" key="$2"
    sed -n '/"release"[[:space:]]*:/,/^  }/p' "$file" 2>/dev/null \
        | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# restore 的版本仲裁 —— **纯读包内文件, 零副作用**, 必须在任何破坏性操作之前跑完。
# 成功后设置: ZFC_RESTORE_VERSION / ZFC_RESTORE_SHA / ZFC_RESTORE_SOURCE
#             ZFC_RESTORE_WEB_RD / ZFC_RESTORE_CTL_RD (包里记的 repo digest, 可空)
restore_resolve_target() {
    local migration_dir="$1"
    local info="$migration_dir/migration_info.json"
    local dump="$migration_dir/postgres_dump.sql"
    local meta_ver="" meta_sha="" meta_status=""
    local dump_ledger="" dump_status="" dump_ver="" dump_sha=""

    # 全部清空 —— 交互菜单里可以连续跑两次 restore, 上一次的残留会串味
    ZFC_RESTORE_VERSION=""; ZFC_RESTORE_SHA=""; ZFC_RESTORE_SOURCE=""
    ZFC_RESTORE_WEB_RD=""; ZFC_RESTORE_CTL_RD=""
    ZFC_RESTORE_WEB_IMAGE=""; ZFC_RESTORE_CTL_IMAGE=""

    if [[ -f "$info" ]]; then
        meta_ver=$(migration_info_release_value "$info" version)
        meta_sha=$(migration_info_release_value "$info" schema_artifact_sha256)
        meta_status=$(migration_info_release_value "$info" status)
        ZFC_RESTORE_WEB_RD=$(migration_info_release_value "$info" zf_web_repo_digest)
        ZFC_RESTORE_CTL_RD=$(migration_info_release_value "$info" zf_controler_repo_digest)
    fi

    # 老包(1.0.0 无 release 块)兜底: 从 dump 反解。dump 就是数据本身, 天然自洽。
    if dump_ledger=$(parse_ledger_from_dump "$dump"); then
        IFS=$'\x1f' read -r dump_status dump_ver dump_sha <<< "$dump_ledger"
    fi

    # ── 元数据 ↔ dump 强制交叉校验 ────────────────────────────────────────
    # 新包反而比老包更脆: 老包只能从 dump 反解(数据本身), 新包多了一份可以和数据
    # 脱节的 migration_info.json。手改它「恢复顺便升级」→ 拉新镜像 → 后续校验全绿
    # → 起服务 → 门禁挂 → crash-loop, 与本设计要修的原始 bug 完全同形。
    # 冲突时不自动挑一边 —— 元数据与数据打架说明包不可信, 直接拒绝让人来看。
    if [[ -n "$meta_ver" && -n "$dump_ver" ]]; then
        if [[ "$meta_ver" != "$dump_ver" ]]; then
            log_error "迁移包元数据与数据库内容不一致(版本):"
            log_error "  migration_info.json: $meta_ver"
            log_error "  postgres_dump.sql  : $dump_ver"
            die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝恢复来源不可信的迁移包" || return 1
        fi
        if [[ -n "$meta_sha" && "$meta_sha" != "$dump_sha" ]]; then
            log_error "迁移包元数据与数据库内容不一致(schema 指纹):"
            log_error "  migration_info.json: ${meta_sha:0:12}..."
            log_error "  postgres_dump.sql  : ${dump_sha:0:12}..."
            die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝恢复来源不可信的迁移包" || return 1
        fi
    fi

    # ── 优先级 ──
    if [[ -n "$meta_ver" ]]; then
        ZFC_RESTORE_VERSION="$meta_ver"; ZFC_RESTORE_SHA="${meta_sha:-$dump_sha}"
        ZFC_RESTORE_SOURCE="migration_info"
    elif [[ -n "$dump_ver" ]]; then
        ZFC_RESTORE_VERSION="$dump_ver"; ZFC_RESTORE_SHA="$dump_sha"
        ZFC_RESTORE_SOURCE="dump"       # 老包(1.0.0)走这条 —— 用户无需重新打包
        log_info "迁移包无 release 元数据(老格式), 已从数据库内容反解版本"
    fi

    # 源库半迁移: 按该账本恢复会在启动门禁 validate_state 挂掉(非 stable 直接 bail)
    local eff_status="${meta_status:-$dump_status}"
    if [[ -n "$ZFC_RESTORE_VERSION" && -n "$eff_status" && "$eff_status" != "stable" ]]; then
        log_error "迁移包的 schema 状态为 '${eff_status}'(非 stable), 源库上次迁移未完成"
        log_error "按此包恢复后会被启动门禁拒绝; 请在源机器执行 --update 修好账本后重新打包"
        die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝恢复半迁移状态的迁移包" || return 1
    fi

    if [[ -n "$ZFC_RESTORE_VERSION" ]]; then
        log_success "迁移包锁定版本: $ZFC_RESTORE_VERSION (来源: $ZFC_RESTORE_SOURCE)"
        return 0
    fi

    # ── 全都拿不到: 显式确认 ──
    # 这里**必须**硬编码 "no", 不能用 $(assume_default): ZFC_ASSUME_YES 默认是 1,
    # assume_default 会返回 yes, confirm 在非交互下 return 0 即同意 —— 照抄仓库里
    # 其它确认点的惯用法, 默认非交互环境就会静默放行版本不明的恢复, 正是本设计
    # 要消灭的行为。逃生通道只对着屏幕前的人开, 不对自动化开。
    log_warning "无法确定迁移包的版本身份(无 release 元数据, 且数据库内容中无 schema 账本)"
    log_warning "将沿用包内 .env 的镜像引用 —— 若那是 :latest, 恢复后可能起到与数据不匹配的版本"
    if confirm "仍要继续恢复(不推荐)？" "no"; then
        log_warning "用户确认: 以版本不确定的方式继续"
        return 0
    fi
    die_or_return "$EXIT_MISSING_INPUT" "已取消: 迁移包版本身份不明" || return 1
}

# 拉取目标版本镜像并做 fail-closed 校验。只 docker pull, 不改任何本地状态。
# 成功后把钉死的引用 export 到 shell(供后续改写 .env 用)。
restore_pull_and_verify() {
    local migration_dir="$1"
    local version="$ZFC_RESTORE_VERSION"
    local pkg_env="$migration_dir/.env"
    local web_repo ctl_repo repo name var ref snapshot rc
    local pkg_web pkg_ctl

    [[ -n "$version" ]] || return 0    # 版本不明: 用户已显式确认, 沿用包内引用

    # repo 前缀取自**包内 .env** —— restore 的仲裁发生在 cp 覆盖之前, 本机 .env
    # 还是目标机器的旧配置(甚至不存在)。包里的引用才代表「这份数据配套的镜像在哪」。
    pkg_web=$(grep -E '^[[:space:]]*ZF_WEB_IMAGE=' "$pkg_env" 2>/dev/null | head -1 | cut -d= -f2-)
    pkg_ctl=$(grep -E '^[[:space:]]*ZF_CONTROLER_IMAGE=' "$pkg_env" 2>/dev/null | head -1 | cut -d= -f2-)
    pkg_web="${pkg_web%\"}"; pkg_web="${pkg_web#\"}"
    pkg_ctl="${pkg_ctl%\"}"; pkg_ctl="${pkg_ctl#\"}"
    if [[ -z "$pkg_web" || -z "$pkg_ctl" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "迁移包 .env 缺少 ZF_WEB_IMAGE / ZF_CONTROLER_IMAGE" || return 1
    fi
    web_repo=$(image_repo_prefix "$pkg_web")
    ctl_repo=$(image_repo_prefix "$pkg_ctl")

    # 目标机器要走别的 registry(隔离网络 + 本地 mirror)时显式覆盖, 不让用户手改包内文件
    if [[ -n "${ZFC_RESTORE_REGISTRY:-}" ]]; then
        log_info "ZFC_RESTORE_REGISTRY: 覆盖 registry 前缀为 ${ZFC_RESTORE_REGISTRY}"
        web_repo="${ZFC_RESTORE_REGISTRY%/}/${web_repo##*/}"
        ctl_repo="${ZFC_RESTORE_REGISTRY%/}/${ctl_repo##*/}"
    fi

    log_info "拉取 ${version} 版本镜像..."
    for repo in "$web_repo" "$ctl_repo"; do
        if ! docker pull "${repo}:${version}" >/dev/null; then
            log_error "拉取失败: ${repo}:${version}"
            log_error "  · 若为 404/tag 不存在: 该版本可能已从 registry 清理; 检查 registry 上是否仍有此 tag"
            log_error "  · 若为网络不可达: 若已在源机器 docker save 过镜像, 可在本机 docker load 后重跑 restore"
            [[ -n "${ZFC_RESTORE_REGISTRY:-}" ]] || \
                log_error "  · 目标机器需用其它 registry 时, 设 ZFC_RESTORE_REGISTRY=<mirror> 后重试"
            die_or_return "$EXIT_IMAGE_PULL" "无法获取迁移包锁定的版本 ${version}" || return 1
        fi
    done

    # ── fail-closed 校验 ──
    snapshot=$(schema_bundle_globals_save)
    rc=0
    prepare_schema_bundle "${web_repo}:${version}" "${ctl_repo}:${version}" || rc=$?

    if (( rc == 0 )); then
        # image-bundle 路径
        local got_ver="$TARGET_SCHEMA_RELEASE" got_sha="$EXPECTED_SCHEMA_SHA256"
        schema_bundle_globals_restore "$snapshot"
        if [[ "$got_ver" != "$version" ]]; then
            log_error "镜像内 release 与迁移包不符: 镜像=$got_ver 包=$version"
            die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝启动与数据不匹配的镜像" || return 1
        fi
        # 这一条对齐的正是启动门禁 validate_state 真正校验的字段(schemaArtifactSha256),
        # 不是 image digest —— 后者在 schema_version.rs 里只读出返回, 从不参与校验。
        if [[ -n "$ZFC_RESTORE_SHA" && "$got_sha" != "$ZFC_RESTORE_SHA" ]]; then
            log_error "镜像 schema 指纹与迁移包不符:"
            log_error "  镜像: ${got_sha:0:12}...   包: ${ZFC_RESTORE_SHA:0:12}..."
            die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝启动与数据不匹配的镜像" || return 1
        fi
        log_success "镜像校验通过: release=$got_ver sha=${got_sha:0:12}..."
    else
        schema_bundle_globals_restore "$snapshot"
        if (( rc != 2 )); then
            die_or_return "$EXIT_SCHEMA_MIGRATION" "目标镜像 schema bundle 校验失败" || return 1
        fi
        # legacy 路径: 镜像无 schema bundle。**legacy ≠ 免校验** —— 上面三条在此
        # 全部落空(SCHEMA_SOURCE=legacy 时 EXPECTED_SCHEMA_SHA256 为空,
        # verify_target_image_ids 首行直接 return 0), 必须换一套线索。
        log_warning "目标镜像不含 schema bundle(legacy), 改用 repo digest 校验"
        local checked=0 got_rd
        for var in ZFC_RESTORE_WEB_RD:$web_repo ZFC_RESTORE_CTL_RD:$ctl_repo; do
            name="${var%%:*}"; repo="${var#*:}"
            ref="${!name}"
            # 「包里没记」≠「不一致」: 源机器镜像若是本地 build 从未 push, RepoDigests
            # 就是空的(正常的开发环境迁移)。只有「包里有但对不上」才 fail-closed,
            # 否则非交互下开发环境的自动化 restore 会全部失败。
            [[ -n "$ref" ]] || continue
            got_rd=$(image_repo_digest "${repo}:${version}" 2>/dev/null || true)
            if [[ -n "$got_rd" ]]; then
                # 只比 @ 之后的 manifest digest: 跨 registry mirror 时 repo 前缀不同
                # 但 manifest 相同, 比整串会恒不等, 把合法 restore 拦死。
                if [[ "$(digest_manifest_part "$got_rd")" != "$(digest_manifest_part "$ref")" ]]; then
                    log_error "镜像 digest 与迁移包不符: 本地=$(digest_manifest_part "$got_rd") 包=$(digest_manifest_part "$ref")"
                    die_or_return "$EXIT_SCHEMA_MIGRATION" "拒绝启动与数据不匹配的镜像" || return 1
                fi
                checked=$((checked + 1))
            fi
        done
        if (( checked > 0 )); then
            log_success "legacy 路径 digest 校验通过 (${checked} 项)"
        else
            log_warning "包内无 repo digest 记录, 跳过 digest 校验(源镜像可能从未 push)"
        fi
    fi

    # 把钉死的引用 export, 供 §9.3 改写 .env
    ZFC_RESTORE_WEB_IMAGE="${web_repo}:${version}"
    ZFC_RESTORE_CTL_IMAGE="${ctl_repo}:${version}"
    return 0
}

# 在任何 `source .env` 之后重新施加 resolve 解析出的钉死引用。
# 必须在 resolve_deploy_version 与 commit_pinned_env 之间的每一个 source .env 后调用 ——
# 目前只有 update_schema 开头那一处(update_images 自己的几处 source 都在 resolve 之前)。
apply_resolved_image_pins() {
    # 用「有没有 pin」判断而不是「有没有解析出版本」—— legacy 路径解不出版本(
    # ZFC_RESOLVED_VERSION 为空)但仍有 channel/--to 引用需要保住。
    [[ -n "$ZFC_PINNED_WEB_IMAGE" || -n "$ZFC_PINNED_CTL_IMAGE" ]] || return 0
    [[ -n "$ZFC_PINNED_WEB_IMAGE" ]]   && ZF_WEB_IMAGE="$ZFC_PINNED_WEB_IMAGE"
    [[ -n "$ZFC_PINNED_CTL_IMAGE" ]]   && ZF_CONTROLER_IMAGE="$ZFC_PINNED_CTL_IMAGE"
    [[ -n "$ZFC_PINNED_RRD_IMAGE" ]]   && RRD_SERVICE_IMAGE="$ZFC_PINNED_RRD_IMAGE"
    [[ -n "$ZFC_PINNED_UTIL_IMAGE" ]]  && ZFC_UTIL_IMAGE="$ZFC_PINNED_UTIL_IMAGE"
    [[ -n "$ZFC_PINNED_ADMIN_IMAGE" ]] && ZFC_ADMIN_IMAGE="$ZFC_PINNED_ADMIN_IMAGE"
    export ZF_WEB_IMAGE ZF_CONTROLER_IMAGE RRD_SERVICE_IMAGE ZFC_UTIL_IMAGE ZFC_ADMIN_IMAGE
    return 0
}

# 把已验证的钉版本引用写进 .env。只能在 update_schema + verify_target_image_ids
# 都成功之后、起服务之前调用(见 resolve_deploy_version 的说明)。
commit_pinned_env() {
    local channel="$1" prefix="${2:-.env.pre-update}"
    local ts backup
    [[ -n "${ZFC_RESOLVED_VERSION:-}" ]] || return 0   # legacy: 无版本可钉

    ts=$(date +%Y%m%d_%H%M%S)
    backup="${prefix}-${ts}"
    if ! cp .env "$backup"; then
        log_error "备份 .env 失败, 拒绝改写"
        return 1
    fi
    chmod 600 "$backup" 2>/dev/null || true

    # 用 ZFC_PINNED_*(source .env 冲不掉)而非当前 shell 值 —— 后者可能已被中途某个
    # source .env 冲回旧引用, 那样会「日志打已钉到新版本、文件里写的却是旧的」。
    local -a pairs=("ZFC_UPDATE_CHANNEL=$(quote_env_value "$channel")")
    pairs+=("ZF_WEB_IMAGE=$(quote_env_value "$ZFC_PINNED_WEB_IMAGE")")
    pairs+=("ZF_CONTROLER_IMAGE=$(quote_env_value "$ZFC_PINNED_CTL_IMAGE")")
    [[ -n "$ZFC_PINNED_RRD_IMAGE" ]]   && pairs+=("RRD_SERVICE_IMAGE=$(quote_env_value "$ZFC_PINNED_RRD_IMAGE")")
    [[ -n "$ZFC_PINNED_UTIL_IMAGE" ]]  && pairs+=("ZFC_UTIL_IMAGE=$(quote_env_value "$ZFC_PINNED_UTIL_IMAGE")")
    [[ -n "$ZFC_PINNED_ADMIN_IMAGE" ]] && pairs+=("ZFC_ADMIN_IMAGE=$(quote_env_value "$ZFC_PINNED_ADMIN_IMAGE")")
    if ! write_env_keys_atomic "${pairs[@]}"; then
        log_error "改写 .env 失败, 回滚到 $backup"
        cp "$backup" .env 2>/dev/null || true
        return 1
    fi

    # compose 插值中 shell 环境**优先于** .env 文件: 文件写对了但 shell 还是旧值的话,
    # 随后的 compose up 会忽略文件、起旧镜像, 而用户 cat .env 以为已升级。
    apply_resolved_image_pins

    log_success ".env 已钉到 ${ZFC_RESOLVED_VERSION} (备份: $backup)"
    cleanup_env_backups
    return 0
}

# 升级时强制刷新一次性工具镜像（不依赖 compose 服务列表）。
# - zfc-admin：show-token / refresh-token / 创建管理员，schema 必须与 DB 账本一致
# - zfc-util：密钥生成等运维命令
# 调用方须已 source .env。拉取失败按镜像拉取错误返回，避免「业务已升、工具还旧」。
pull_utility_tool_images() {
    if [[ -n "${ZFC_ADMIN_IMAGE:-}" ]]; then
        log_info "拉取工具镜像 zfc-admin: $ZFC_ADMIN_IMAGE"
        if ! docker pull "$ZFC_ADMIN_IMAGE"; then
            die_or_return "$EXIT_IMAGE_PULL" "无法拉取 zfc-admin 镜像: $ZFC_ADMIN_IMAGE (检查 DOCKER_REGISTRY/网络/凭据; 工具镜像不在 compose 内也必须与 web 同版本)" || return 1
        fi
        log_success "zfc-admin 已更新到本地"
    else
        log_warning "ZFC_ADMIN_IMAGE 未配置，跳过 zfc-admin 拉取（查看管理员密码可能因旧镜像 schema 不一致失败）"
    fi

    if [[ -n "${ZFC_UTIL_IMAGE:-}" ]]; then
        log_info "拉取工具镜像 zfc-util: $ZFC_UTIL_IMAGE"
        if ! docker pull "$ZFC_UTIL_IMAGE"; then
            die_or_return "$EXIT_IMAGE_PULL" "无法拉取 zfc-util 镜像: $ZFC_UTIL_IMAGE (检查 DOCKER_REGISTRY/网络/凭据)" || return 1
        fi
        log_success "zfc-util 已更新到本地"
    fi
    return 0
}

# show-token / refresh-token 共用: 指纹不一致时先 docker pull 同 tag 再验一次。
# 覆盖「compose 升级未刷工具镜像」的常见现场; 拉齐后仍不一致才 fail。
ensure_zfc_admin_schema_for_ops() {
    local db_url="$1" network_args="$2"
    if verify_zfc_admin_schema_matches_db "$db_url" "$network_args"; then
        return 0
    fi
    if [[ -z "${ZFC_ADMIN_IMAGE:-}" ]]; then
        die_or_return "$EXIT_SCHEMA_MIGRATION" "zfc-admin 与数据库 schema 不一致; 请各镜像同版本并执行 更新镜像(--update) 同步后重试" || return 1
    fi
    log_warning "zfc-admin 与 DB schema 不一致，尝试重新拉取 $ZFC_ADMIN_IMAGE ..."
    if ! docker pull "$ZFC_ADMIN_IMAGE"; then
        die_or_return "$EXIT_IMAGE_PULL" "无法拉取 zfc-admin: $ZFC_ADMIN_IMAGE; schema 不一致且无法自动修复" || return 1
    fi
    if verify_zfc_admin_schema_matches_db "$db_url" "$network_args"; then
        log_success "重新拉取后 zfc-admin 与数据库 schema 已对齐"
        return 0
    fi
    die_or_return "$EXIT_SCHEMA_MIGRATION" "重新拉取后 zfc-admin 仍与数据库 schema 不一致; 请确认 registry 上该 tag 与 zf-web/zf-controler 同版本, 或执行 更新镜像(--update)" || return 1
}

# 取一个值: 非交互优先 env(校验/默认/必填 die), 交互沿用 read 循环(读 /dev/tty, 无 tty 不死循环)。
# 用法: ask VAR "label" [default] [regex] [required(0/1)]
ask() {
    local __var="$1" __label="$2" __default="${3:-}" __regex="${4:-}" __required="${5:-0}"
    local __cur="${!__var:-}"

    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        [[ -z "$__cur" && -n "$__default" ]] && __cur="$__default"
        if [[ -z "$__cur" ]]; then
            if [[ "$__required" == "1" ]]; then
                die "$EXIT_MISSING_INPUT" "缺少必填项: ${__var} (${__label}); 请用环境变量或 --config 传入"
            fi
            printf -v "$__var" '%s' ""
            return 0
        fi
        if [[ -n "$__regex" && ! "$__cur" =~ $__regex ]]; then
            die "$EXIT_MISSING_INPUT" "环境变量 ${__var} 值非法: [${__cur}] (${__label})"
        fi
        printf -v "$__var" '%s' "$__cur"
        return 0
    fi

    local __input __prompt="$__label"
    [[ -n "$__default" ]] && __prompt="${__label} [默认: ${__default}]"
    while true; do
        # 提示文案直接写到 /dev/tty(可见); read 本身不带 -p, 故 2>/dev/null 只吞
        # 「无 tty 时打不开 /dev/tty」的错误。历史 bug: read -p 的提示走 stderr,
        # 被 2>/dev/null 一并丢弃 → 交互时界面像卡死, 用户只能狂按回车。
        printf '%s: ' "${__prompt}" >/dev/tty 2>/dev/null
        if ! read __input </dev/tty 2>/dev/null; then
            if [[ "$__required" == "1" && -z "$__default" ]]; then
                die "$EXIT_MISSING_INPUT" "无终端可交互且未提供 ${__var} (${__label}); 请用环境变量或 --config 传入"
            fi
            printf -v "$__var" '%s' "$__default"
            return 0
        fi
        [[ -z "$__input" && -n "$__default" ]] && __input="$__default"
        if [[ -z "$__input" ]]; then
            [[ "$__required" == "1" ]] && { log_error "${__label} 不能为空"; continue; }
            printf -v "$__var" '%s' ""
            return 0
        fi
        if [[ -n "$__regex" && ! "$__input" =~ $__regex ]]; then
            log_error "${__label} 格式不正确，请重新输入"
            continue
        fi
        printf -v "$__var" '%s' "$__input"
        return 0
    done
}

# 取一个保密值(交互 read -s)。非交互同 ask。用法: ask_secret VAR "label" [required]
ask_secret() {
    local __var="$1" __label="$2" __required="${3:-0}"
    local __cur="${!__var:-}"

    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        if [[ -z "$__cur" && "$__required" == "1" ]]; then
            die "$EXIT_MISSING_INPUT" "缺少必填项: ${__var} (${__label}); 请用环境变量或 --config 传入"
        fi
        printf -v "$__var" '%s' "$__cur"
        return 0
    fi

    local __input
    while true; do
        # 同 ask: 提示直接写 /dev/tty, read -s 不带 -p, 避免 2>/dev/null 吞掉提示。
        printf '%s: ' "${__label}" >/dev/tty 2>/dev/null
        if ! read -s __input </dev/tty 2>/dev/null; then
            echo
            [[ "$__required" == "1" ]] && die "$EXIT_MISSING_INPUT" "无终端可交互且未提供 ${__var} (${__label})"
            printf -v "$__var" '%s' ""
            return 0
        fi
        echo
        if [[ -z "$__input" && "$__required" == "1" ]]; then
            log_error "${__label} 不能为空"
            continue
        fi
        printf -v "$__var" '%s' "$__input"
        return 0
    done
}

# 是非确认。非交互返回 default(yes→0/no→1)。用法: confirm "question" [yes|no]
confirm() {
    local __q="$1" __default="${2:-yes}" __ans
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        [[ "$__default" == "yes" ]] && return 0 || return 1
    fi
    local __hint="[Y/n]"; [[ "$__default" == "no" ]] && __hint="[y/N]"
    # 提示直接写 /dev/tty(可见); 否则 read -p 的提示被 2>/dev/null 吞掉 → 像卡死。
    printf '%s %s: ' "${__q}" "${__hint}" >/dev/tty 2>/dev/null
    if ! read __ans </dev/tty 2>/dev/null; then
        [[ "$__default" == "yes" ]] && return 0 || return 1
    fi
    __ans="${__ans,,}"
    [[ -z "$__ans" ]] && __ans="$__default"
    case "$__ans" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        *)     [[ "$__default" == "yes" ]] && return 0 || return 1 ;;
    esac
}

# 非交互下「proceed 类」确认的默认值: ZFC_ASSUME_YES=1 → yes, 否则 no。
assume_default() {
    [[ "$ZFC_ASSUME_YES" == "1" ]] && echo "yes" || echo "no"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 探测并缓存可用的 compose 命令(优先 docker compose 插件, 回退 docker-compose 独立二进制)。
# 修正历史 bug: `command_exists "docker compose"` 实际只查 `docker`。
# 成功设置全局 DOCKER_COMPOSE_CMD 并返回 0; 都不可用返回 1。
detect_compose_cmd() {
    if [[ -n "$DOCKER_COMPOSE_CMD" ]]; then
        return 0
    fi
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
        return 0
    fi
    if command_exists docker-compose && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
        return 0
    fi
    return 1
}

# 探测 docker 引擎版本(返回 "major.minor" 或空)。
docker_server_version() {
    docker version --format '{{.Server.Version}}' 2>/dev/null \
        | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
}

# docker / compose 版本过旧时 add_warning(非致命)。更新失败常因 docker 太旧 / 仍用 v1 compose。
# DOCKER_VERSION_FINDINGS 累积供 --doctor 复用(每行一条 "id|severity|detail|hint")。
DOCKER_VERSION_FINDINGS=""
check_docker_versions() {
    DOCKER_VERSION_FINDINGS=""
    local ver major minor
    ver="$(docker_server_version)"
    if [[ -n "$ver" ]]; then
        major="${ver%%.*}"; minor="${ver#*.}"
        # 已知良好下限: 20.10(compose v2 插件 + 现代 compose 文件特性)。
        if [[ "$major" -lt 20 || ( "$major" -eq 20 && "$minor" -lt 10 ) ]]; then
            add_warning "Docker 引擎版本偏旧 (${ver}); 建议升级到 ≥20.10(可 root 下 curl -fsSL https://get.docker.com | sh)。"
            DOCKER_VERSION_FINDINGS="${DOCKER_VERSION_FINDINGS}docker_old|warning|Docker engine ${ver} < 20.10|升级 Docker 到 >=20.10\n"
        fi
    fi
    detect_compose_cmd || return 0
    if [[ "$DOCKER_COMPOSE_CMD" == "docker-compose" ]]; then
        add_warning "正在使用 docker-compose v1(独立二进制, 已停止维护); 建议改用 docker compose v2 插件以避免更新兼容问题。"
        DOCKER_VERSION_FINDINGS="${DOCKER_VERSION_FINDINGS}compose_v1|warning|using docker-compose v1 standalone|安装 docker-compose-plugin 改用 docker compose v2\n"
    fi
}

# 内存/磁盘预检(只 warning, 不阻断安装; 避免误伤边缘机器)。设置全局 RES_MEM_MB / RES_DISK_MB。
RES_MEM_MB=0
RES_DISK_MB=0
check_system_resources() {
    RES_MEM_MB=0; RES_DISK_MB=0
    if [[ -r /proc/meminfo ]]; then
        local kb
        kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
        [[ -n "$kb" ]] && RES_MEM_MB=$(( kb / 1024 ))
    fi
    # 当前目录所在分区可用空间(MB)
    RES_DISK_MB=$(df -Pm . 2>/dev/null | awk 'NR==2{print $4}')
    [[ -n "$RES_DISK_MB" ]] || RES_DISK_MB=0
    if [[ "$RES_MEM_MB" -gt 0 && "$RES_MEM_MB" -lt 1800 ]]; then
        add_warning "内存偏低 (~${RES_MEM_MB}MB); 建议 ≥2GB(TDengine 可设 TDENGINE_TYPE=disabled 省 ~500MB)。"
    fi
    if [[ "$RES_DISK_MB" -gt 0 && "$RES_DISK_MB" -lt 40000 ]]; then
        add_warning "磁盘可用空间偏低 (~$((RES_DISK_MB/1024))GB); 建议 ≥40GB(镜像+数据库+备份)。"
    fi
}

# 检测「自家残留安装」(同 guard_fresh_install 的检测口径): cwd 有 .env/docker-compose.yml,
# 或本项目名下有运行中容器。返回 0=有残留, 1=无。
detect_residual_install() {
    [[ -f docker-compose.yml || -f .env ]] && return 0
    local proj
    proj="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
    if [[ -n "$proj" ]] && docker ps --filter "label=com.docker.compose.project=${proj}" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

wait_for_compose_services() {
    local timeout="${1:-60}"
    shift
    local elapsed=0 service cid running all_running

    while [[ "$elapsed" -lt "$timeout" ]]; do
        all_running=1
        for service in "$@"; do
            cid=$($DOCKER_COMPOSE_CMD ps -q "$service" 2>/dev/null | head -1)
            running=""
            [[ -n "$cid" ]] && running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null || true)
            if [[ "$running" != "true" ]]; then
                all_running=0
                break
            fi
        done
        [[ "$all_running" -eq 1 ]] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

# 受限 dotenv 加载器: 仅接受 KEY=VALUE(KEY 为大写白名单形态), 不执行任意 shell。
# 优先级: 真实环境变量(用户 export 的) > 文件 > 脚本内置默认。
# 关键: 用 ENVIRON 快照只认「用户真正导出的 env」, 脚本内部 `VAR="${VAR:-默认}"`
# 不会进入 ENVIRON(未 export), 因此文件值能正确覆盖内置默认(修复 --config 失效)。
load_config_file() {
    local file="$1"
    [[ -f "$file" ]] || die "$EXIT_BAD_CONFIG" "配置文件不存在: ${file}"
    [[ -r "$file" ]] || die "$EXIT_BAD_CONFIG" "配置文件不可读: ${file}"

    # 仅由用户导出的真实环境变量名(空格分隔, 首尾留空格便于精确匹配)。
    local real_env_keys
    real_env_keys=" $(awk 'BEGIN{for (k in ENVIRON) printf "%s ", k}' </dev/null 2>/dev/null)"

    local line key val
    local -a preset_keys=() preset_vals=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            die "$EXIT_BAD_CONFIG" "配置文件行非法(仅支持 KEY=VALUE): ${line}"
        fi
        key="${line%%=*}"
        val="${line#*=}"
        if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
            val="${val:1:${#val}-2}"
        fi
        # 真实导出的 env, 或被 CLI flag 锁定的模式键 → 记录稍后恢复(优先于文件)。
        if [[ "$real_env_keys" == *" $key "* || " ${ZFC_FLAG_LOCKED_KEYS:-} " == *" $key "* ]]; then
            preset_keys+=("$key")
            preset_vals+=("${!key}")
        fi
        printf -v "$key" '%s' "$val"
        export "$key"
    done < "$file"

    # 恢复真实 env(优先级高于文件)
    local i
    for i in "${!preset_keys[@]}"; do
        printf -v "${preset_keys[$i]}" '%s' "${preset_vals[$i]}"
        export "${preset_keys[$i]}"
    done
}

# Cross-platform sed in-place editing
sed_inplace() {
    local file="$1"
    shift
    # Create backup, apply changes, remove backup
    sed "$@" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Remove a service section from docker-compose.yml by name
# This handles comments above the service (between the previous service and this one)
# Usage: remove_compose_service <file> <service_name>
remove_compose_service() {
    local file="$1"
    local service="$2"

    if ! grep -q "^  ${service}:" "$file" 2>/dev/null; then
        return 0
    fi

    local temp_file
    temp_file=$(mktemp)

    awk -v service="$service" '
    BEGIN { in_service = 0 }
    # Match top-level service definitions (2-space indent)
    /^  [a-zA-Z0-9_-]+:/ {
        if ($0 ~ "^  " service ":" ) {
            in_service = 1
            next
        } else {
            in_service = 0
        }
    }
    # Skip content lines belonging to the service (deeper indent)
    in_service && /^    / { next }
    # Skip blank lines and comments while inside the removed service
    in_service && (/^$/ || /^  #/) { next }
    # Any other line at same or lesser indent ends the service block
    in_service { in_service = 0 }
    # Print non-skipped lines
    { print }
    ' "$file" > "$temp_file"

    mv "$temp_file" "$file"
}

# Generate random password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Safe quoting for environment variables
quote_env_value() {
    local value="$1"
    # If value contains special characters, quote it
    if [[ "$value" =~ [[:space:]#\$\"\'\\] ]]; then
        # Escape any existing quotes and wrap in double quotes
        printf '"%s"' "${value//\"/\\\"}"
    else
        printf '%s' "$value"
    fi
}

# 清洗用户粘贴的凭证(授权ID / API密钥):
#   - 删除回车符 \r (Windows 剪贴板 / CRLF 常见, read 不会自动去除)
#   - 删除换行符 \n
#   - 去除首尾空白(空格 / 制表符等)
# 仅做无损清洗, 不改变中间的有效字符。
sanitize_credential() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    # 去除前导空白
    value="${value#"${value%%[![:space:]]*}"}"
    # 去除尾随空白
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# 交互式读取一个凭证并自动清洗 / 校验后写入指定变量名。
# 用法: prompt_credential <目标变量名> <提示文案>
prompt_credential() {
    local __var="$1"
    local __label="$2"
    local __input __clean __confirm

    # 非交互: 直接清洗 env 值并校验, 不提问。
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        __clean="$(sanitize_credential "${!__var:-}")"
        if [[ -z "$__clean" ]]; then
            die "$EXIT_MISSING_INPUT" "缺少必填项: ${__var} (${__label}); 请用环境变量或 --config 传入"
        fi
        printf -v "$__var" '%s' "$__clean"
        return 0
    fi

    while true; do
        read -p "请输入 ${__label}: " __input </dev/tty
        __clean="$(sanitize_credential "$__input")"

        if [[ -z "$__clean" ]]; then
            log_error "${__label} 不能为空"
            continue
        fi

        # 若清洗掉了任何字符(常见于复制粘贴时多带空格/回车), 明确告知用户
        if [[ "$__clean" != "$__input" ]]; then
            log_warning "已自动移除输入中的空白字符(空格 / 制表符 / 回车)"
        fi

        # cuid / uuid / token 形态应仅含 [A-Za-z0-9._-]
        # 含其它字符(不可见字符 / 全角空格 / 中文等)极可能是复制错误, 二次确认
        if [[ ! "$__clean" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_warning "${__label} 含有非常规字符, 可能复制时多带了不可见字符。"
            log_warning "当前值: [${__clean}] (共 ${#__clean} 个字符)"
            read -p "确认就使用该值吗？[y/N]: " __confirm </dev/tty
            case "${__confirm,,}" in
                y|yes) ;;       # 用户坚持使用
                *) continue ;;  # 重新输入
            esac
        fi

        printf -v "$__var" '%s' "$__clean"
        break
    done
}

# 在线校验授权ID / API密钥是否有效(可选, 失败不阻断安装)。
# 调用授权服务器: GET {auth_url}/instance/{id}/status  -H "X-API-Key: {key}"
#   2xx          -> 凭据有效
#   400/401/403  -> 凭据无效(授权ID不存在 / API密钥不匹配 / 已失效)
#   其它(000/超时/5xx/404) -> 无法验证, 视为通过并给出提示
# 返回 0 = 通过或无法验证, 1 = 服务器明确拒绝
validate_license_online() {
    local instance_id="$1"
    local api_key="$2"
    local auth_url="${ZFC_AUTH_SERVER_URL:-https://zf-license.luny60.top}"
    auth_url="${auth_url%/}"  # 去掉末尾斜杠

    log_info "在线校验授权信息 (${auth_url}) ..."
    local code
    code=$(curl -s -o /dev/null -m 15 -w "%{http_code}" \
        -H "X-API-Key: ${api_key}" \
        "${auth_url}/instance/${instance_id}/status" 2>/dev/null) || code="000"

    case "$code" in
        2*)
            log_success "授权信息校验通过 (HTTP ${code})"
            return 0
            ;;
        400|401|403)
            log_error "授权信息无效！授权服务器拒绝 (HTTP ${code})"
            log_error "  - 401: API密钥与授权ID不匹配"
            log_error "  - 400/403: 授权ID不存在或已失效"
            log_error "请核对 ZFC_INSTANCE_ID 与 ZFC_API_KEY 是否完全一致(注意大小写, 勿多复制空格)"
            return 1
            ;;
        *)
            log_warning "无法连接授权服务器进行校验 (HTTP ${code}), 已跳过在线校验。"
            log_warning "可能原因: 网络不通 / 授权服务器地址非默认(${auth_url})。"
            log_warning "安装将继续, 但请确保授权信息正确, 否则服务启动后会认证失败。"
            return 0
            ;;
    esac
}

# 收集并(可选)在线校验 license。
# 非交互: 取 env(必填), ZFC_VALIDATE_LICENSE=1 时校验, 服务器明确拒绝则 die 13。
# 交互: 沿用 prompt_credential 清洗 + 在线校验 + 重输循环。
collect_license() {
    # 自动清洗粘贴的凭证(去回车/空白), 对非常规字符二次确认(交互)
    prompt_credential ZFC_INSTANCE_ID "ZFC_INSTANCE_ID (授权ID)"
    prompt_credential ZFC_API_KEY "ZFC_API_KEY (API密钥)"

    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        if [[ "$ZFC_VALIDATE_LICENSE" == "1" ]]; then
            if ! validate_license_online "$ZFC_INSTANCE_ID" "$ZFC_API_KEY"; then
                die "$EXIT_LICENSE_INVALID" "授权信息无效(授权服务器明确拒绝); 请核对 ZFC_INSTANCE_ID / ZFC_API_KEY"
            fi
        else
            log_warning "已按 ZFC_VALIDATE_LICENSE=0 跳过在线授权校验"
        fi
        return 0
    fi

    # 交互: 在线校验 + 重输
    while true; do
        if ! confirm "是否在线校验授权信息是否正确？" "yes"; then
            log_warning "已跳过在线授权校验, 请自行确保授权信息正确"
            break
        fi
        if validate_license_online "$ZFC_INSTANCE_ID" "$ZFC_API_KEY"; then
            break
        fi
        if ! confirm "是否重新输入授权信息？" "yes"; then
            log_warning "保留当前(可能无效的)授权信息继续安装"
            break
        fi
        prompt_credential ZFC_INSTANCE_ID "ZFC_INSTANCE_ID (授权ID)"
        prompt_credential ZFC_API_KEY "ZFC_API_KEY (API密钥)"
    done
}

# Generate JWT secret
generate_jwt_secret() {
    openssl rand -hex 32
}

# Get the actual docker-compose network name
get_compose_network() {
    local network_name=""
    local project_name
    project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

    # First: look for postgres container scoped to the current project
    local postgres_container
    postgres_container=$(docker ps \
        --filter "label=com.docker.compose.service=postgres" \
        --filter "label=com.docker.compose.project=${project_name}" \
        --format "{{.Names}}" | head -1)
    if [[ -n "$postgres_container" ]]; then
        network_name=$(docker inspect "$postgres_container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
        if [[ -n "$network_name" && "$network_name" != "bridge" ]]; then
            echo "$network_name"
            return 0
        fi
    fi

    # Second: any compose container scoped to the current project
    local compose_container
    compose_container=$(docker ps \
        --filter "label=com.docker.compose.project=${project_name}" \
        --format "{{.Names}}" | head -1)
    if [[ -n "$compose_container" ]]; then
        network_name=$(docker inspect "$compose_container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
        if [[ -n "$network_name" && "$network_name" != "bridge" ]]; then
            echo "$network_name"
            return 0
        fi
    fi

    # Third: find network by project name pattern
    network_name=$(docker network ls --format "{{.Name}}" | grep -E "(${project_name}_default|${project_name}_)" | head -1)
    if [[ -n "$network_name" ]]; then
        echo "$network_name"
        return 0
    fi

    # Final fallback: use default compose network name
    echo "${project_name}_default"
}

# Database connection validation functions
validate_postgres_connection() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    local database="$5"
    
    log_info "验证 PostgreSQL 连接: $user@$host:$port/$database"
    
    # Test connection using docker with postgres client
    local connection_test_output
    connection_test_output=$(timeout 10 docker run --rm \
        -e PGPASSWORD="$password" \
        postgres:15-alpine \
        psql -h "$host" -p "$port" -U "$user" -d "$database" -c "SELECT 1;" 2>&1) || {
        log_error "PostgreSQL 连接失败"
        log_error "错误信息: $connection_test_output"
        log_error "请检查："
        log_error "  1. 主机地址和端口是否正确"
        log_error "  2. 用户名和密码是否正确"
        log_error "  3. 数据库是否存在"
        log_error "  4. 防火墙设置是否允许连接"
        return 1
    }
    
    log_success "PostgreSQL 连接验证成功"
    return 0
}

validate_redis_connection() {
    local host="$1"
    local port="$2"
    local password="$3"
    
    log_info "验证 Redis 连接: $host:$port"
    
    # Test connection using docker with redis client
    local connection_test_output
    if [[ -n "$password" ]]; then
        connection_test_output=$(timeout 10 docker run --rm \
            redis:7-alpine \
            redis-cli -h "$host" -p "$port" -a "$password" ping 2>&1) || {
            log_error "Redis 连接失败"
            log_error "错误信息: $connection_test_output"
            log_error "请检查："
            log_error "  1. 主机地址和端口是否正确"
            log_error "  2. 密码是否正确"
            log_error "  3. 防火墙设置是否允许连接"
            return 1
        }
    else
        connection_test_output=$(timeout 10 docker run --rm \
            redis:7-alpine \
            redis-cli -h "$host" -p "$port" ping 2>&1) || {
            log_error "Redis 连接失败"
            log_error "错误信息: $connection_test_output"
            log_error "请检查："
            log_error "  1. 主机地址和端口是否正确"
            log_error "  2. 防火墙设置是否允许连接"
            return 1
        }
    fi
    
    if echo "$connection_test_output" | grep -q "PONG"; then
        log_success "Redis 连接验证成功"
        return 0
    else
        log_error "Redis 连接验证失败: $connection_test_output"
        return 1
    fi
}

validate_tdengine_connection() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    
    log_info "验证 TDengine 连接: $user@$host:$port"
    
    # Test connection using curl to TDengine REST API
    local connection_test_output
    connection_test_output=$(timeout 10 curl -s \
        -H "Authorization: Basic $(echo -n "$user:$password" | base64)" \
        "http://$host:$port/rest/sql" \
        -d "SELECT SERVER_VERSION();" 2>&1) || {
        log_error "TDengine 连接失败"
        log_error "错误信息: $connection_test_output"
        log_error "请检查："
        log_error "  1. 主机地址和端口是否正确"
        log_error "  2. 用户名和密码是否正确"
        log_error "  3. TDengine 服务是否运行"
        log_error "  4. 防火墙设置是否允许连接"
        return 1
    }
    
    if echo "$connection_test_output" | grep -q '"code":0'; then
        log_success "TDengine 连接验证成功"
        return 0
    else
        log_error "TDengine 连接验证失败: $connection_test_output"
        return 1
    fi
}

# Check if ports are available
check_ports_available() {
    local ports=("$@")
    local occupied_ports=()
    
    for port in "${ports[@]}"; do
        # Check if port is in use using multiple methods for better compatibility
        local port_in_use=false
        
        # Method 1: netstat (if available)
        if command_exists netstat; then
            if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
                port_in_use=true
            fi
        # Method 2: ss (if available)
        elif command_exists ss; then
            if ss -tuln 2>/dev/null | grep -q ":${port} "; then
                port_in_use=true
            fi
        # Method 3: lsof (if available)
        elif command_exists lsof; then
            if lsof -i ":${port}" 2>/dev/null | grep -q LISTEN; then
                port_in_use=true
            fi
        # Method 4: nc (netcat) test
        elif command_exists nc; then
            if nc -z localhost "$port" 2>/dev/null; then
                port_in_use=true
            fi
        fi
        
        if [ "$port_in_use" = true ]; then
            occupied_ports+=("$port")
        fi
    done
    
    if [ ${#occupied_ports[@]} -gt 0 ]; then
        # 供 preflight_ports 做「自家残留容器」识别(避免泛化报错)
        LAST_OCCUPIED_PORTS="${occupied_ports[*]}"
        log_error "以下端口被占用: ${occupied_ports[*]}"
        log_error "请释放这些端口或停止占用它们的服务"
        return 1
    fi

    LAST_OCCUPIED_PORTS=""
    log_success "端口 ${ports[*]} 可用"
    return 0
}

# 列出本 compose 项目(以 cwd 目录名为项目名)运行中容器对外发布的端口集合(空格分隔)。
# 用于区分「端口被自家上次安装占用」与「第三方占用」。
ports_held_by_self() {
    local proj
    proj="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
    [[ -n "$proj" ]] || return 0
    local cid ports=""
    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        # docker port 输出形如 "443/tcp -> 0.0.0.0:443"; 取冒号后的宿主端口
        ports="$ports $(docker port "$cid" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
    done < <(docker ps -q --filter "label=com.docker.compose.project=${proj}" 2>/dev/null)
    printf '%s' "$ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' '
}

# ── 依赖探测 / 自动安装 ───────────────────────────────────────────────────────
SUDO=""

# 探测能否以 root 执行(或经 sudo)。设置全局 SUDO。
detect_root() {
    if [[ "$(id -u)" == "0" ]]; then SUDO=""; return 0; fi
    if command_exists sudo; then SUDO="sudo"; return 0; fi
    return 1
}

# echo 出系统包管理器的安装命令前缀(不含包名); 未知则 echo 空串。
detect_pkg_install() {
    if command_exists apt-get;   then echo "apt-get install -y"
    elif command_exists dnf;     then echo "dnf install -y"
    elif command_exists yum;     then echo "yum install -y"
    elif command_exists apk;     then echo "apk add --no-cache"
    else echo ""; fi
}

# 确保 docker / compose / openssl / curl 就绪。
# 模式 install(默认): 缺失则在条件满足时自动安装, 不可安装则 die 12。
# 模式 probe: 只报告(加 warning), 不安装, 不 die。
ensure_dependencies() {
    local mode="${1:-install}"
    local missing=()
    command_exists docker  || missing+=("docker")
    command_exists openssl || missing+=("openssl")
    command_exists curl    || missing+=("curl")
    local need_compose=0
    detect_compose_cmd || need_compose=1

    if [[ ${#missing[@]} -eq 0 && $need_compose -eq 0 ]]; then
        log_success "依赖检查通过 (docker / ${DOCKER_COMPOSE_CMD} / openssl / curl)"
        return 0
    fi

    local miss_desc="${missing[*]}"
    [[ $need_compose -eq 1 ]] && miss_desc="${miss_desc} docker-compose"
    log_warning "缺失依赖: ${miss_desc# }"

    if [[ "$mode" == "probe" ]]; then
        if [[ "$ZFC_AUTO_INSTALL_DOCKER" == "1" ]]; then
            if detect_root; then
                add_warning "缺失依赖(${miss_desc# })将在安装时自动安装"
            else
                add_warning "缺失依赖(${miss_desc# })需 root/sudo 安装, 当前无权限; 请用 root 运行或预装依赖"
            fi
        else
            add_warning "缺失依赖(${miss_desc# })且 ZFC_AUTO_INSTALL_DOCKER=0, 请手动安装"
        fi
        return 1
    fi

    # install 模式
    if [[ "$ZFC_AUTO_INSTALL_DOCKER" != "1" ]]; then
        die "$EXIT_DEP_UNAVAILABLE" "缺失依赖且已禁用自动安装(ZFC_AUTO_INSTALL_DOCKER=0): ${miss_desc# }; 请手动安装后重试"
    fi
    if ! detect_root; then
        die "$EXIT_DEP_UNAVAILABLE" "自动安装依赖需要 root 或 sudo, 但当前非 root 且无 sudo: ${miss_desc# }"
    fi

    local pkg_install; pkg_install="$(detect_pkg_install)"

    # openssl / curl 走包管理器
    local need_pkg=()
    local d
    for d in "${missing[@]}"; do
        [[ "$d" == "openssl" || "$d" == "curl" ]] && need_pkg+=("$d")
    done
    if [[ ${#need_pkg[@]} -gt 0 ]]; then
        [[ -n "$pkg_install" ]] || die "$EXIT_DEP_UNAVAILABLE" "无法确定包管理器以安装: ${need_pkg[*]}"
        log_info "安装依赖: ${need_pkg[*]} ..."
        command_exists apt-get && { $SUDO apt-get update -qq || true; }
        $SUDO $pkg_install "${need_pkg[@]}" || die "$EXIT_DEP_UNAVAILABLE" "安装依赖失败: ${need_pkg[*]}"
    fi

    # docker 走官方脚本
    if ! command_exists docker; then
        command_exists curl || die "$EXIT_DEP_UNAVAILABLE" "安装 Docker 需要 curl, 但 curl 不可用"
        log_info "通过 https://get.docker.com 安装 Docker(可能耗时数分钟)..."
        if ! curl -fsSL https://get.docker.com | $SUDO sh; then
            die "$EXIT_DEP_UNAVAILABLE" "Docker 自动安装失败; 请参考 https://docs.docker.com/get-docker/ 手动安装"
        fi
        command_exists systemctl && { $SUDO systemctl enable --now docker 2>/dev/null || true; }
    fi

    # compose 插件
    DOCKER_COMPOSE_CMD=""
    if ! detect_compose_cmd; then
        if [[ -n "$pkg_install" ]]; then
            $SUDO $pkg_install docker-compose-plugin 2>/dev/null \
                || $SUDO $pkg_install docker-compose 2>/dev/null || true
            DOCKER_COMPOSE_CMD=""
        fi
        detect_compose_cmd || die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 不可用且自动安装失败; 请安装 docker compose 插件"
    fi

    for d in docker openssl curl; do
        command_exists "$d" || die "$EXIT_DEP_UNAVAILABLE" "依赖仍缺失: ${d}"
    done
    log_success "依赖已就绪 (docker / ${DOCKER_COMPOSE_CMD} / openssl / curl)"
}

# ── 预检 (ports / DNS) ────────────────────────────────────────────────────────
# enforce: 致命问题 die; report: 致命问题计数并继续(供 --check)。
PREFLIGHT_MODE="enforce"
PREFLIGHT_FATAL=0
PREFLIGHT_FIRST_CODE=0   # report 模式记录首个致命问题的退出码, 供 --check 退出
preflight_fail() {
    local code="$1"; shift
    local reason="$*"
    if [[ "$PREFLIGHT_MODE" == "report" ]]; then
        PREFLIGHT_FATAL=$((PREFLIGHT_FATAL+1))
        [[ "$PREFLIGHT_FIRST_CODE" -eq 0 ]] && PREFLIGHT_FIRST_CODE="$code"
        log_error "$reason"
        add_warning "FATAL: ${reason}"
    else
        die "$code" "$reason"
    fi
}

# 依据已解析的配置计算并检查所需端口(外部库不查本地库端口, Caddy 关不查 80/443)。
preflight_ports() {
    local ports=(8080 3100)
    [[ "${POSTGRES_TYPE:-builtin}" == "builtin" ]] && ports+=(5432)
    [[ "${REDIS_TYPE:-builtin}" == "builtin" ]] && ports+=(6379)
    [[ "${CADDY_ENABLED:-false}" == "true" ]] && ports+=(80 443)
    log_info "检查必要端口可用性: ${ports[*]}"
    if ! check_ports_available "${ports[@]}"; then
        # 归因: 若被占端口全部来自本项目自家残留容器, 给出专门引导(加 --force 接管),
        # 而非误导成第三方占用。
        local self_ports occ p all_self=1
        self_ports=" $(ports_held_by_self) "
        for p in $LAST_OCCUPIED_PORTS; do
            [[ "$self_ports" == *" $p "* ]] || { all_self=0; break; }
        done
        if [[ -n "$LAST_OCCUPIED_PORTS" && "$all_self" == "1" ]]; then
            ZFC_HINT="端口被你上次的 ZFC 安装占用; 重试请加 --force 接管(或 --clean-install 清空)"
            preflight_fail "$EXIT_PORT_CONFLICT" "端口 ${LAST_OCCUPIED_PORTS}被你上次的 ZFC 安装(本项目容器)占用。加 --force 重新接管, 或 --clean-install 清空重装。"
        else
            preflight_fail "$EXIT_PORT_CONFLICT" "必要端口被占用(见上)。请释放后重试, 或调整数据库/Caddy 配置避开占用端口。"
        fi
    fi
}

# 探测本机公网 IPv4。
get_public_ip() {
    local ip
    ip=$(curl -s -m 8 https://api.ipify.org 2>/dev/null) || ip=""
    [[ -z "$ip" ]] && { ip=$(curl -s -m 8 https://ifconfig.me 2>/dev/null) || ip=""; }
    printf '%s' "$ip"
}

# 解析域名 A 记录(尽力而为, 多种工具兜底)。
resolve_ips() {
    local host="$1"
    if command_exists getent; then
        getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
    elif command_exists dig; then
        dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$'
    elif command_exists host; then
        host -t A "$host" 2>/dev/null | awk '/has address/{print $NF}'
    fi
}

# 分级 DNS/HTTPS 预检(仅启用 Caddy 时):
#   fatal  : 域名完全无法解析
#   warning: 解析 IP 与本机公网 IP 不一致(疑似 CF 橙云/CDN/NAT, 仅提示不阻断)
preflight_dns() {
    if [[ "${CADDY_ENABLED:-false}" != "true" ]]; then
        log_info "未启用 Caddy, 跳过 DNS/HTTPS 预检"
        return 0
    fi
    local pub_ip; pub_ip="$(get_public_ip)"
    if [[ -n "$pub_ip" ]]; then
        log_info "本机公网 IP: ${pub_ip}"
    else
        add_warning "无法探测本机公网 IP(网络受限?), DNS 比对降级为仅检查可解析性"
    fi
    local d ips
    for d in "$WEB_DOMAIN" "$CONTROLER_DOMAIN"; do
        ips="$(resolve_ips "$d" 2>/dev/null | tr '\n' ' ')"
        ips="${ips%"${ips##*[![:space:]]}"}"
        if [[ -z "$ips" ]]; then
            preflight_fail "$EXIT_MISSING_INPUT" "域名 ${d} 无法解析(无 A 记录)。启用 Caddy 自动 HTTPS 前, 请先把它解析到本机公网 IP(${pub_ip:-本机IP})。"
            continue
        fi
        log_info "${d} 解析到: ${ips}"
        if [[ -n "$pub_ip" ]] && ! grep -qw "$pub_ip" <<<"$ips"; then
            add_warning "${d} 解析 IP (${ips}) 与本机公网 IP (${pub_ip}) 不一致; 若使用 Cloudflare 橙云/CDN/NAT, Caddy 申请证书会失败 — 请改为灰云(DNS only)或直接解析到本机。"
        fi
    done
}

# 安装路径的运行时预检(在 get_user_input 解析完配置后调用)。
preflight_runtime() {
    PREFLIGHT_MODE="enforce"
    preflight_ports
    preflight_dns
}

# Check prerequisites (仅依赖; 端口/DNS 移至 preflight_runtime, 在配置解析后再查)
check_prerequisites() {
    log_info "检查系统环境..."
    ensure_dependencies install
    check_docker_versions || true
    log_success "系统环境检查通过"
}

# 判断系统时钟是否已通过 NTP 同步
# 返回 0 = 已同步，非 0 = 未同步或无法判定
is_ntp_synced() {
    if command_exists timedatectl; then
        local synced
        synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
        if [[ "$synced" == "yes" ]]; then
            return 0
        fi
        # 回退：较旧 systemd 没有 --property，解析 status 文本
        if timedatectl status 2>/dev/null | grep -qiE "System clock synchronized:[[:space:]]*yes"; then
            return 0
        fi
    fi
    return 1
}

# 等待 NTP 同步完成；超时后尝试强制重同步（chronyc makestep / 重启 timesyncd）再等一次
# 返回 0 = 最终已同步，非 0 = 仍未同步
wait_for_ntp_sync() {
    local max_wait="${1:-30}"
    local waited=0

    # 临时关闭 set -e，NTP 失败不应终止安装
    set +e

    log_info "等待 NTP 时间同步完成（最长 ${max_wait} 秒）..."
    while [[ $waited -lt $max_wait ]]; do
        if is_ntp_synced; then
            log_success "NTP 时间已同步：$(date -u)"
            set -e
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_warning "NTP 在 ${max_wait} 秒内未完成同步，尝试强制重新同步..."

    # chronyd 可用时立刻 makestep（即使偏移较大也会跳步）
    if command_exists chronyc && systemctl is-active --quiet chronyd 2>/dev/null; then
        chronyc -a makestep >/dev/null 2>&1 || true
    fi

    # 重启 systemd-timesyncd 触发再次尝试
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi

    waited=0
    while [[ $waited -lt 20 ]]; do
        if is_ntp_synced; then
            log_success "NTP 时间已同步：$(date -u)"
            set -e
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_warning "NTP 时间仍未同步！"
    log_warning "timedatectl status:"
    timedatectl status 2>/dev/null | sed 's/^/    /' || true
    log_warning "可能原因："
    log_warning "  1) 防火墙阻止 NTP (UDP 123) 出站流量"
    log_warning "  2) 配置的 NTP 服务器不可达"
    log_warning "  3) 虚拟机 / 容器宿主未提供正确时钟"
    log_warning "时间不同步会导致服务间握手失败或数据异常，请修复后重试。"

    set -e
    return 1
}

# Check RTC time drift
# 注意：此函数仅用于告警，任何错误都不会导致脚本退出
check_rtc_time_drift() {
    log_info "检查RTC时间同步状态..."

    # 先报告 NTP 同步状态（RTC 与系统时间可能一起漂，仅比较两者会漏报）
    if is_ntp_synced; then
        log_success "NTP 同步状态：已同步"
    else
        log_warning "NTP 同步状态：未同步（timedatectl 报告 System clock synchronized: no）"
    fi

    # 临时禁用错误退出，确保检查失败不会终止安装
    set +e
    
    # 获取系统UTC时间戳（秒）
    local system_utc_time
    system_utc_time=$(date -u +%s 2>/dev/null)
    if [[ -z "$system_utc_time" ]]; then
        log_warning "无法获取系统时间，跳过RTC时间检查"
        set -e
        return 0
    fi
    
    # 尝试获取RTC时间戳
    local rtc_time=""
    local rtc_datetime=""
    
    if command_exists timedatectl; then
        # 使用timedatectl获取RTC时间（UTC格式）
        rtc_datetime=$(timedatectl status 2>/dev/null | grep "RTC time:" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
        # 检查 RTC 时间是否为 "n/a" 或为空
        if [[ -n "$rtc_datetime" && "$rtc_datetime" != "n/a" ]]; then
            # RTC时间是UTC时间，直接转换为时间戳
            rtc_time=$(date -u -d "$rtc_datetime" +%s 2>/dev/null) || rtc_time=""
        fi
    fi
    
    # 如果timedatectl失败，尝试hwclock（读取UTC时间）
    if [[ -z "$rtc_time" ]] && command_exists hwclock; then
        rtc_datetime=$(hwclock -r --utc 2>/dev/null) || rtc_datetime=""
        if [[ -n "$rtc_datetime" ]]; then
            rtc_time=$(date -u -d "$rtc_datetime" +%s 2>/dev/null) || rtc_time=""
        fi
    fi
    
    if [[ -z "$rtc_time" ]]; then
        log_warning "无法获取RTC时间（可能是虚拟机或容器环境），跳过RTC时间检查"
        log_warning "这通常不影响正常使用，安装将继续..."
        set -e
        return 0
    fi
    
    # 计算时间差（绝对值）
    local time_diff=$((system_utc_time - rtc_time)) 2>/dev/null || time_diff=0
    if [[ $time_diff -lt 0 ]]; then
        time_diff=$((-time_diff))
    fi
    
    log_info "系统UTC时间: $(date -u)"
    log_info "RTC UTC时间: $(date -u -d "@$rtc_time" 2>/dev/null || echo "无法解析")"
    log_info "时间差: ${time_diff}秒"
    
    # 检查是否超过60秒
    if [[ $time_diff -gt 60 ]]; then
        log_warning "RTC时间与系统时间相差超过60秒！"
        log_warning "这可能会导致时间同步问题，建议重启机器确保时间同步正常。"
        log_warning "当前时间差：${time_diff}秒"
        log_warning "如果问题持续，请检查硬件时钟或NTP配置。"
    else
        log_success "RTC时间检查通过，时间差在正常范围内"
    fi
    
    # 恢复错误退出设置
    set -e
}

# Setup time synchronization
setup_time_sync() {
    echo
    log_info "=== 时间同步配置 ==="
    log_info "系统时间同步对于服务正常运行非常重要。"

    # 非交互: 由 ZFC_SETUP_TIME_SYNC 决定(默认开); 交互: 询问。
    local time_sync_default="yes"
    [[ "$ZFC_SETUP_TIME_SYNC" == "1" ]] || time_sync_default="no"

    if ! confirm "是否自动设置时间同步？" "$time_sync_default"; then
        log_warning "您选择了跳过自动时间同步。"
        log_warning "请务必手动配置时间同步（如 NTP/chrony），并确保时间持续保持同步。"
        log_warning "时间不同步可能导致服务连接失败或数据异常。"
        log_warning "建议命令："
        log_warning "  Debian/Ubuntu: apt install -y systemd-timesyncd && systemctl enable --now systemd-timesyncd"
        log_warning "  CentOS/RHEL:   yum install -y chrony && systemctl enable --now chronyd"
        echo
    else
        # 已有同步服务在运行时跳过安装，但不代表"已同步"，后面仍要验证
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null || \
           systemctl is-active --quiet chronyd 2>/dev/null || \
           systemctl is-active --quiet ntpd 2>/dev/null; then
            log_info "时间同步服务已在运行，跳过安装。"
        else
            log_info "设置系统时间同步..."

            # 检测操作系统类型
            if [[ -f /etc/debian_version ]] || [[ -f /etc/ubuntu-release ]]; then
                # Debian/Ubuntu 系统
                log_info "检测到 Debian/Ubuntu 系统，安装 systemd-timesyncd..."
                apt-get update -qq
                apt-get install -y systemd-timesyncd
                systemctl enable systemd-timesyncd
                systemctl start systemd-timesyncd
            elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
                # CentOS/RHEL 系统
                log_info "检测到 CentOS/RHEL 系统，配置 chronyd..."
                if command_exists chronyd; then
                    systemctl enable chronyd
                    systemctl start chronyd
                elif command_exists ntpd; then
                    systemctl enable ntpd
                    systemctl start ntpd
                else
                    log_warning "未找到 chronyd 或 ntpd，尝试安装 chrony..."
                    yum install -y chrony || dnf install -y chrony
                    systemctl enable chronyd
                    systemctl start chronyd
                fi
            else
                # 其他系统，尝试通用方法
                log_info "尝试配置时间同步服务..."
                if command_exists systemctl; then
                    if systemctl list-unit-files | grep -q systemd-timesyncd; then
                        systemctl enable systemd-timesyncd
                        systemctl start systemd-timesyncd
                    elif systemctl list-unit-files | grep -q chronyd; then
                        systemctl enable chronyd
                        systemctl start chronyd
                    elif systemctl list-unit-files | grep -q ntpd; then
                        systemctl enable ntpd
                        systemctl start ntpd
                    else
                        log_warning "未找到时间同步服务，请手动配置 NTP"
                    fi
                else
                    log_warning "未检测到 systemd，请手动配置时间同步"
                fi
            fi
        fi

        # 无论是刚启动还是已在跑，都要等并验证真正的同步状态
        wait_for_ntp_sync 30 || true
    fi

    # 检查RTC时间漂移（无论是否跳过同步都执行）
    check_rtc_time_drift

    log_success "时间同步检查完成"
}

# Database configuration functions
configure_postgres() {
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        POSTGRES_TYPE="${POSTGRES_TYPE:-builtin}"
        case "$POSTGRES_TYPE" in
            builtin) log_info "PostgreSQL: 内置容器" ;;
            external)
                [[ -n "${EXTERNAL_POSTGRES_HOST:-}" ]]     || die "$EXIT_MISSING_INPUT" "POSTGRES_TYPE=external 需要 EXTERNAL_POSTGRES_HOST"
                [[ -n "${EXTERNAL_POSTGRES_USER:-}" ]]     || die "$EXIT_MISSING_INPUT" "POSTGRES_TYPE=external 需要 EXTERNAL_POSTGRES_USER"
                [[ -n "${EXTERNAL_POSTGRES_PASSWORD:-}" ]] || die "$EXIT_MISSING_INPUT" "POSTGRES_TYPE=external 需要 EXTERNAL_POSTGRES_PASSWORD"
                EXTERNAL_POSTGRES_PORT="${EXTERNAL_POSTGRES_PORT:-5432}"
                EXTERNAL_POSTGRES_DB="${EXTERNAL_POSTGRES_DB:-zfc}"
                log_info "PostgreSQL: 外部 ${EXTERNAL_POSTGRES_USER}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}"
                ;;
            *) die "$EXIT_MISSING_INPUT" "POSTGRES_TYPE 非法: ${POSTGRES_TYPE} (应为 builtin|external)" ;;
        esac
        return 0
    fi
    echo
    log_info "配置 PostgreSQL 数据库..."
    echo "1. 使用内置 PostgreSQL 容器（推荐）"
    echo "2. 使用外部 PostgreSQL 数据库"

    while true; do
        read -p "请选择 PostgreSQL 配置 [1-2]: " postgres_choice
        case $postgres_choice in
            1)
                POSTGRES_TYPE="builtin"
                log_info "将使用内置 PostgreSQL 容器"
                break
                ;;
            2)
                POSTGRES_TYPE="external"
                log_info "配置外部 PostgreSQL 连接..."
                
                while true; do
                    read -p "请输入 PostgreSQL 主机地址: " EXTERNAL_POSTGRES_HOST
                    if [[ -n "$EXTERNAL_POSTGRES_HOST" ]]; then
                        break
                    else
                        log_error "主机地址不能为空"
                    fi
                done
                
                read -p "请输入端口 [默认: 5432]: " EXTERNAL_POSTGRES_PORT
                EXTERNAL_POSTGRES_PORT=${EXTERNAL_POSTGRES_PORT:-5432}
                
                while true; do
                    read -p "请输入用户名: " EXTERNAL_POSTGRES_USER
                    if [[ -n "$EXTERNAL_POSTGRES_USER" ]]; then
                        break
                    else
                        log_error "用户名不能为空"
                    fi
                done
                
                while true; do
                    read -s -p "请输入密码: " EXTERNAL_POSTGRES_PASSWORD
                    echo
                    if [[ -n "$EXTERNAL_POSTGRES_PASSWORD" ]]; then
                        break
                    else
                        log_error "密码不能为空"
                    fi
                done
                
                while true; do
                    read -p "请输入数据库名 [默认: zfc]: " EXTERNAL_POSTGRES_DB
                    EXTERNAL_POSTGRES_DB=${EXTERNAL_POSTGRES_DB:-zfc}
                    break
                done
                
                break
                ;;
            *)
                log_error "无效选择，请输入 1 或 2"
                ;;
        esac
    done
}

configure_redis() {
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        REDIS_TYPE="${REDIS_TYPE:-builtin}"
        case "$REDIS_TYPE" in
            builtin) log_info "Redis: 内置容器" ;;
            external)
                [[ -n "${EXTERNAL_REDIS_HOST:-}" ]] || die "$EXIT_MISSING_INPUT" "REDIS_TYPE=external 需要 EXTERNAL_REDIS_HOST"
                EXTERNAL_REDIS_PORT="${EXTERNAL_REDIS_PORT:-6379}"
                EXTERNAL_REDIS_PASSWORD="${EXTERNAL_REDIS_PASSWORD:-}"
                log_info "Redis: 外部 ${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
                ;;
            *) die "$EXIT_MISSING_INPUT" "REDIS_TYPE 非法: ${REDIS_TYPE} (应为 builtin|external)" ;;
        esac
        return 0
    fi
    echo
    log_info "配置 Redis 数据库..."
    echo "1. 使用内置 Redis 容器（推荐）"
    echo "2. 使用外部 Redis 数据库"

    while true; do
        read -p "请选择 Redis 配置 [1-2]: " redis_choice
        case $redis_choice in
            1)
                REDIS_TYPE="builtin"
                log_info "将使用内置 Redis 容器"
                break
                ;;
            2)
                REDIS_TYPE="external"
                log_info "配置外部 Redis 连接..."
                
                while true; do
                    read -p "请输入 Redis 主机地址: " EXTERNAL_REDIS_HOST
                    if [[ -n "$EXTERNAL_REDIS_HOST" ]]; then
                        break
                    else
                        log_error "主机地址不能为空"
                    fi
                done
                
                read -p "请输入端口 [默认: 6379]: " EXTERNAL_REDIS_PORT
                EXTERNAL_REDIS_PORT=${EXTERNAL_REDIS_PORT:-6379}
                
                read -s -p "请输入密码（可选，直接回车跳过）: " EXTERNAL_REDIS_PASSWORD
                echo
                
                break
                ;;
            *)
                log_error "无效选择，请输入 1 或 2"
                ;;
        esac
    done
}

configure_tdengine() {
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        TDENGINE_TYPE="${TDENGINE_TYPE:-builtin}"
        case "$TDENGINE_TYPE" in
            builtin)  log_info "TDengine: 内置容器" ;;
            disabled) log_info "TDengine: 禁用(节省内存, 历史统计/延迟图表不可用)" ;;
            external)
                [[ -n "${EXTERNAL_TDENGINE_HOST:-}" ]]     || die "$EXIT_MISSING_INPUT" "TDENGINE_TYPE=external 需要 EXTERNAL_TDENGINE_HOST"
                [[ -n "${EXTERNAL_TDENGINE_PASSWORD:-}" ]] || die "$EXIT_MISSING_INPUT" "TDENGINE_TYPE=external 需要 EXTERNAL_TDENGINE_PASSWORD"
                # 注意: 连接 URL 使用 WS/REST 端口(默认 6041), 见 create_env_file
                EXTERNAL_TDENGINE_PORT="${EXTERNAL_TDENGINE_PORT:-6041}"
                EXTERNAL_TDENGINE_USER="${EXTERNAL_TDENGINE_USER:-root}"
                log_info "TDengine: 外部 ${EXTERNAL_TDENGINE_USER}@${EXTERNAL_TDENGINE_HOST}:${EXTERNAL_TDENGINE_PORT}"
                ;;
            *) die "$EXIT_MISSING_INPUT" "TDENGINE_TYPE 非法: ${TDENGINE_TYPE} (应为 builtin|external|disabled)" ;;
        esac
        return 0
    fi
    echo
    log_info "配置 TDengine 时序数据库..."
    echo "TDengine 用于历史统计和延迟图表功能，禁用后这些功能不可用，但不影响核心转发服务。"
    echo "1. 使用内置 TDengine 容器（推荐）"
    echo "2. 使用外部 TDengine 数据库"
    echo "3. 禁用 TDengine（节省内存资源，适合小内存机器）"

    while true; do
        read -p "请选择 TDengine 配置 [1-3]: " tdengine_choice
        case $tdengine_choice in
            1)
                TDENGINE_TYPE="builtin"
                log_info "将使用内置 TDengine 容器"
                break
                ;;
            2)
                TDENGINE_TYPE="external"
                log_info "配置外部 TDengine 连接..."

                while true; do
                    read -p "请输入 TDengine 主机地址: " EXTERNAL_TDENGINE_HOST
                    if [[ -n "$EXTERNAL_TDENGINE_HOST" ]]; then
                        break
                    else
                        log_error "主机地址不能为空"
                    fi
                done

                read -p "请输入 WS/REST 端口 [默认: 6041]: " EXTERNAL_TDENGINE_PORT
                EXTERNAL_TDENGINE_PORT=${EXTERNAL_TDENGINE_PORT:-6041}

                read -p "请输入用户名 [默认: root]: " EXTERNAL_TDENGINE_USER
                EXTERNAL_TDENGINE_USER=${EXTERNAL_TDENGINE_USER:-root}

                while true; do
                    read -s -p "请输入密码: " EXTERNAL_TDENGINE_PASSWORD
                    echo
                    if [[ -n "$EXTERNAL_TDENGINE_PASSWORD" ]]; then
                        break
                    else
                        log_error "密码不能为空"
                    fi
                done

                break
                ;;
            3)
                TDENGINE_TYPE="disabled"
                log_info "将禁用 TDengine，可节省约 500MB+ 内存"
                log_warning "禁用后历史统计、延迟图表等功能不可用，但核心转发服务不受影响"
                break
                ;;
            *)
                log_error "无效选择，请输入 1、2 或 3"
                ;;
        esac
    done
}

configure_caddy() {
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        CADDY_ENABLED="${CADDY_ENABLED:-true}"
        if [[ "$CADDY_ENABLED" == "true" ]]; then
            CADDY_EMAIL="${CADDY_EMAIL:-}"
            # 邮箱可选: 留空则 Caddyfile 省略 tls 指令(仍自动 ACME 签证, 仅无账户邮箱/到期通知)
            if [[ -n "$CADDY_EMAIL" && ! "$CADDY_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                die "$EXIT_MISSING_INPUT" "CADDY_EMAIL 邮箱格式非法: ${CADDY_EMAIL}"
            fi
            log_info "Caddy: 启用 (email=${CADDY_EMAIL:-<未填,自动签证>})"
        else
            log_info "Caddy: 跳过, 需自行配置反向代理"
        fi
        return 0
    fi
    echo
    log_info "配置 Caddy 反向代理..."
    echo "Caddy 可以为您的域名自动配置 HTTPS 证书和反向代理"
    echo "这将需要占用端口 80 和 443"
    echo

    while true; do
        read -p "是否配置 Caddy 反向代理？[Y/n]: " caddy_choice
        case ${caddy_choice,,} in
            y|yes|"")
                CADDY_ENABLED="true"
                log_info "将配置 Caddy 反向代理"
                
                # Check if ports 80 and 443 are available
                log_info "检查端口 80 和 443 是否可用..."
                if ! check_ports_available 80 443; then
                    log_error "无法配置 Caddy，请先释放端口 80 和 443"
                    log_warning "您可以稍后手动配置反向代理"
                    CADDY_ENABLED="false"
                    break
                fi
                
                # Get email for TLS certificates (可选: 直接回车跳过, Caddy 仍自动签证)
                while true; do
                    read -p "请输入用于 TLS 证书的邮箱地址 (可选, 回车跳过): " CADDY_EMAIL
                    if [[ -z "$CADDY_EMAIL" ]]; then
                        log_info "未填邮箱, Caddy 将自动签发证书(无账户邮箱/到期通知)"
                        break
                    elif [[ "$CADDY_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        break
                    else
                        log_error "邮箱格式不正确，请重新输入(或回车跳过)"
                    fi
                done
                
                log_info "将使用 Caddy Docker 容器提供反向代理服务"
                
                # Cloudflare warning for Caddy users
                echo
                log_warning "重要提醒：您已启用 Caddy 反向代理"
                log_warning "如果您使用 Cloudflare 管理域名，请确保："
                log_warning "• 前端域名和控制器域名都不要开启小黄云（代理功能）"
                log_warning "• Caddy 将处理 HTTPS 证书和反向代理，Cloudflare 代理会产生冲突"
                echo
                
                break
                ;;
            n|no)
                CADDY_ENABLED="false"
                log_info "跳过 Caddy 配置，您需要手动设置反向代理"
                break
                ;;
            *)
                log_error "请输入 y 或 n"
                ;;
        esac
    done
}

# Check domain and license preparation
check_preparation() {
    # 非交互: 跳过人工确认墙(必填项缺失会在 get_user_input 阶段被 die)
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        return 0
    fi
    echo
    log_info "全新安装前准备检查..."
    echo
    echo -e "${YELLOW}在开始安装之前，请确认您已准备好以下内容:${NC}"
    echo
    echo "1. ${GREEN}域名准备${NC}:"
    echo "   - 前端网页域名 (例如: forward.example.com)"
    echo "   - 控制器网页域名 (例如: zf-controler.example.com)"
    echo "   - 这两个域名需要解析到当前机器的公网IP地址"
    echo "   - ${RED}重要：如果使用 Cloudflare DNS 服务：${NC}"
    echo "     ${RED}• 如果启用 Caddy 反向代理，两个域名都不能开启小黄云（代理功能）${NC}"
    echo "     ${RED}• 如果不使用 Caddy，至少控制器域名不能开启小黄云${NC}"
    echo
    echo "2. ${GREEN}License 配置${NC}:"
    echo "   - ZFC_INSTANCE_ID (实例标识符)"
    echo "   - ZFC_API_KEY (API密钥)"
    echo "   - 请确保您已从 ZFC 授权方获得有效的许可证信息"
    echo
    echo -e "${YELLOW}注意事项:${NC}"
    echo "- 域名必须指向本机公网IP，否则HTTPS证书申请将失败"
    echo "- 如果使用Caddy自动HTTPS，需要确保80和443端口对外开放"
    echo "- License信息错误将导致系统无法正常运行"
    echo
    
    while true; do
        read -p "确认已准备好上述内容？[y/N]: " preparation_confirmed
        case ${preparation_confirmed,,} in
            y|yes)
                log_success "准备检查通过，开始配置..."
                break
                ;;
            n|no|"")
                log_warning "请准备好必要的域名和License信息后重新运行安装脚本"
                exit 0
                ;;
            *)
                log_error "请输入 y 或 n"
                ;;
        esac
    done
    echo
}

# Get user input
get_user_input() {
    log_info "配置系统参数..."
    
    # Web domain
    ask WEB_DOMAIN "请输入前端网页域名 (例如: forward.example.com)" "" '^[a-zA-Z0-9.-]+$' 1

    # Controller domain
    ask CONTROLER_DOMAIN "请输入控制器网页域名 (例如: zf-controler.example.com)" "" '^[a-zA-Z0-9.-]+$' 1

    # Cloudflare warning for controller domain
    echo
    log_warning "重要提醒：如果您使用 Cloudflare 管理域名"
    log_warning "控制器域名 ${CONTROLER_DOMAIN} 不能开启小黄云（代理功能）"
    log_warning "如果稍后启用 Caddy，则前端和控制器域名都不能开启小黄云"

    # License info (交互清洗+校验; 非交互取 env 并按 ZFC_VALIDATE_LICENSE 校验)
    collect_license

    # Database configuration
    configure_postgres
    configure_redis
    configure_tdengine
    
    # Caddy configuration
    configure_caddy
    
    # Always execute Prisma migration to ensure consistency
    echo
    log_info "数据库初始化选项..."
    if [[ "$POSTGRES_TYPE" == "external" ]]; then
        echo "检测到您使用外部 PostgreSQL 数据库"
        log_info "自动执行 Prisma 数据库迁移以确保一致性"
    fi
    RUN_PRISMA_MIGRATION="true"

    # Docker registry configuration
    ask DOCKER_REGISTRY "Docker 镜像仓库地址" "hub.covm.net"
    ask IMAGE_TAG "镜像标签" "latest"

    # Generate image addresses based on registry
    ZF_WEB_IMAGE="${DOCKER_REGISTRY}/zf-web:${IMAGE_TAG}"
    ZF_CONTROLER_IMAGE="${DOCKER_REGISTRY}/zf-controler:${IMAGE_TAG}"
    RRD_SERVICE_IMAGE="${DOCKER_REGISTRY}/rrd-service:${IMAGE_TAG}"
    ZFC_UTIL_IMAGE="${DOCKER_REGISTRY}/zfc-util:${IMAGE_TAG}"
    ZFC_ADMIN_IMAGE="${DOCKER_REGISTRY}/zfc-admin:${IMAGE_TAG}"
    ZFC_PRISMA_IMAGE="${DOCKER_REGISTRY}/zfc-prisma:latest"

    # 意图与事实分离: channel 记「升级时去哪找新版」, 镜像引用记「现在跑什么」。
    # IMAGE_TAG 本身不落盘(历史如此), 落盘的是拼好的引用 —— 若那是 :latest, 迁移/重启时
    # 「现在跑什么」就丢失了。安装阶段先把 channel 记下, 真正的版本钉死由 resolve_deploy_version
    # 在拉到镜像、从 schema bundle 解出 release 后完成(见 install_pin_deployed_version)。
    ZFC_UPDATE_CHANNEL="${IMAGE_TAG}"

    log_info "使用镜像地址:"
    log_info "  ZF-Web: $ZF_WEB_IMAGE"
    log_info "  ZF-Controller: $ZF_CONTROLER_IMAGE"
    log_info "  RRD Service: $RRD_SERVICE_IMAGE"
    log_info "  ZFC-Util: $ZFC_UTIL_IMAGE"
    log_info "  ZFC-Admin: $ZFC_ADMIN_IMAGE"
    log_info "  ZFC-Prisma: $ZFC_PRISMA_IMAGE"
    
    echo
    log_info "数据库配置总结:"
    log_info "  PostgreSQL: $POSTGRES_TYPE"
    log_info "  Redis: $REDIS_TYPE"
    log_info "  TDengine: $TDENGINE_TYPE"
    if [[ "$POSTGRES_TYPE" == "external" ]]; then
        log_info "  Prisma 迁移: $RUN_PRISMA_MIGRATION"
    fi
    
    log_success "用户输入完成"
}

# Generate configuration
generate_config() {
    log_info "生成配置文件..."
    
    # Generate passwords
    POSTGRES_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    if [[ "$TDENGINE_TYPE" != "disabled" ]]; then
        TDENGINE_ROOT_PASSWORD=$(generate_password)
    fi
    JWT_SECRET=$(generate_jwt_secret)
    
    log_info "生成数据库密码..."
    log_info "生成 JWT 密钥..."
    
    # Pre-pull required images to avoid timeout issues
    log_info "预拉取必要的镜像..."
    docker pull "$ZFC_UTIL_IMAGE" &
    docker pull "$ZFC_ADMIN_IMAGE" &
    docker pull "$ZFC_PRISMA_IMAGE" &
    if [[ -n "$RRD_SERVICE_IMAGE" ]]; then
        docker pull "$RRD_SERVICE_IMAGE" &
    fi
    
    # Wait for zfc-util image to be ready for key generation
    wait
    
    # Generate management key pair using zfc-util
    log_info "生成管理密钥对..."
    
    # Generate key pair
    KEY_OUTPUT=$(docker run --rm "$ZFC_UTIL_IMAGE" generate-key)
    
    MGMT_ARRANGER_PRIV_KEY=$(echo "$KEY_OUTPUT" | grep "private_key:" | awk '{print $2}')
    MGMT_PUBKEY=$(echo "$KEY_OUTPUT" | grep "public_key:" | awk '{print $2}')
    
    if [[ -z "$MGMT_ARRANGER_PRIV_KEY" || -z "$MGMT_PUBKEY" ]]; then
        log_error "密钥对生成失败"
        exit 1
    fi


    # Generate key pair
    WEB_KEY_OUTPUT=$(docker run --rm "$ZFC_UTIL_IMAGE" generate-key)
    
    WEB_PRIV_KEY=$(echo "$WEB_KEY_OUTPUT" | grep "private_key:" | awk '{print $2}')
    WEB_PUBKEY=$(echo "$WEB_KEY_OUTPUT" | grep "public_key:" | awk '{print $2}')
    
    if [[ -z "$WEB_PRIV_KEY" || -z "$WEB_PUBKEY" ]]; then
        log_error "密钥对生成失败"
        exit 1
    fi
    
    log_success "密钥对生成完成"
    log_success "镜像预拉取完成"
}

# Generate docker-compose configuration based on database choices
generate_docker_compose() {
    log_info "生成 Docker Compose 配置..."
    
    # Download base template first
    if [[ -f "docker-compose.template.yml" ]]; then
        log_info "使用本地模板文件"
        cp docker-compose.template.yml docker-compose.yml
    else
        log_info "从远程下载模板文件..."
        TEMPLATE_URL="https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/docker-compose.template.yml"
        curl -fsSL "$TEMPLATE_URL" -o docker-compose.yml
    fi
    
    if [[ ! -f "docker-compose.yml" ]]; then
        log_error "无法获取 Docker Compose 模板"
        exit 1
    fi
    
    # Create backup of original template
    cp docker-compose.yml docker-compose.full.yml
    
    # Remove services based on external database choices
    local services_to_remove=()
    
    if [[ "$POSTGRES_TYPE" == "external" ]]; then
        services_to_remove+=("postgres")
        log_info "移除 PostgreSQL 服务（使用外部数据库）"
    fi
    
    if [[ "$REDIS_TYPE" == "external" ]]; then
        services_to_remove+=("redis")
        log_info "移除 Redis 服务（使用外部数据库）"
    fi
    
    if [[ "$TDENGINE_TYPE" == "external" || "$TDENGINE_TYPE" == "disabled" ]]; then
        services_to_remove+=("tdengine" "tdengine-init")
        if [[ "$TDENGINE_TYPE" == "disabled" ]]; then
            log_info "移除 TDengine 服务（已禁用）"
        else
            log_info "移除 TDengine 服务（使用外部数据库）"
        fi
    fi
    
    if [[ "$CADDY_ENABLED" != "true" ]]; then
        services_to_remove+=("caddy")
        log_info "移除 Caddy 服务（用户未启用）"
    fi
    
    # Remove services from docker-compose.yml
    for service in "${services_to_remove[@]}"; do
        log_info "从 docker-compose.yml 中移除 $service 服务..."
        remove_compose_service docker-compose.yml "$service"
    done
    
    # Also remove volumes for external databases
    if [[ "$POSTGRES_TYPE" == "external" ]]; then
        sed_inplace docker-compose.yml '/postgres_data:/d' 2>/dev/null || true
    fi
    
    if [[ "$REDIS_TYPE" == "external" ]]; then
        sed_inplace docker-compose.yml '/redis_data:/d' 2>/dev/null || true
    fi
    
    if [[ "$TDENGINE_TYPE" == "external" || "$TDENGINE_TYPE" == "disabled" ]]; then
        sed_inplace docker-compose.yml '/tdengine_data:/d' 2>/dev/null || true
        sed_inplace docker-compose.yml '/tdengine_log:/d' 2>/dev/null || true
    fi
    
    if [[ "$CADDY_ENABLED" != "true" ]]; then
        sed_inplace docker-compose.yml '/caddy_data:/d' 2>/dev/null || true
        sed_inplace docker-compose.yml '/caddy_config:/d' 2>/dev/null || true
    fi

    # H6: 启用 Caddy 时,控制器走 Caddy(443)→docker 内网 zf-controler:3100,
    # 无需把 3100 暴露到公网;将其 host 映射收到回环,关闭裸 mgmt API 的公网暴露面。
    # 非 Caddy 安装保留 0.0.0.0 公网映射(worker 经此端口接入)。
    # 见 docs/security/audit-2026-06-10.md (H6)。
    if [[ "$CADDY_ENABLED" == "true" ]]; then
        log_info "启用 Caddy:将控制器 3100 端口映射收口到回环(仅 Caddy 经内网访问)"
        sed_inplace docker-compose.yml 's/- "3100:3100"/- "127.0.0.1:3100:3100"/' 2>/dev/null || true
    fi

    # When TDengine is disabled or external: remove tdengine from depends_on in other services
    if [[ "$TDENGINE_TYPE" == "disabled" || "$TDENGINE_TYPE" == "external" ]]; then
        log_info "从 docker-compose.yml 中移除 TDengine 依赖引用..."

        # Remove "      tdengine:\n        condition: service_healthy" from depends_on blocks
        local temp_file
        temp_file=$(mktemp)
        awk '
        /^      tdengine:$/ {
            if (getline next_line > 0 && next_line ~ /^        condition:/) {
                next  # skip both lines
            } else {
                print; if (next_line != "") print next_line
            }
            next
        }
        { print }
        ' docker-compose.yml > "$temp_file"
        mv "$temp_file" docker-compose.yml
    fi

    log_success "Docker Compose 配置生成完成"
    log_info "完整模板备份为: docker-compose.full.yml"
}

# 选一个与现有 docker 网络不冲突的 /16 子网(默认 172.28, 顺次顺延 29/30)。
# 用于固定 compose 网络子网 + 写入 TRUSTED_PROXY_CIDRS, 使 L1 信任前置代理网段(取真实客户端 IP)。
# 冲突判定按前两段(如 "172.28.")做包含判断即可(不做严格 CIDR 交集, 见设计 §3.1)。
# docker 不可用 / 全冲突 → 回退默认, 不阻断安装(只影响新装 .env)。
pick_free_subnet() {
    local candidates=("172.28.0.0/16" "172.29.0.0/16" "172.30.0.0/16")
    local used=""
    used=$(docker network inspect $(docker network ls -q 2>/dev/null) \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null || true)
    local c prefix
    for c in "${candidates[@]}"; do
        prefix="$(echo "$c" | cut -d. -f1-2)."   # 172.28.
        if ! echo "$used" | grep -q "^${prefix}"; then
            echo "$c"
            return 0
        fi
    done
    echo "${candidates[0]}"
}

# Create environment file
create_env_file() {
    log_info "创建环境变量文件..."
    
    # Generate database connection URLs based on configuration
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        POSTGRES_URL="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/zfc?schema=public"
    else
        POSTGRES_URL="postgresql://${EXTERNAL_POSTGRES_USER}:${EXTERNAL_POSTGRES_PASSWORD}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}?schema=public"
    fi
    
    if [[ "$REDIS_TYPE" == "builtin" ]]; then
        REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379"
    else
        if [[ -n "$EXTERNAL_REDIS_PASSWORD" ]]; then
            REDIS_URL="redis://:${EXTERNAL_REDIS_PASSWORD}@${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
        else
            REDIS_URL="redis://${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
        fi
    fi
    
    if [[ "$TDENGINE_TYPE" == "builtin" ]]; then
        TDENGINE_URL="taos+ws://root:${TDENGINE_ROOT_PASSWORD}@tdengine:6041/zfc"
    elif [[ "$TDENGINE_TYPE" == "external" ]]; then
        TDENGINE_URL="taos+ws://${EXTERNAL_TDENGINE_USER}:${EXTERNAL_TDENGINE_PASSWORD}@${EXTERNAL_TDENGINE_HOST}:${EXTERNAL_TDENGINE_PORT:-6041}/zfc"
    else
        TDENGINE_URL=""
    fi

    # 受信反向代理网段: 固定 compose 默认网络子网, 并写入 TRUSTED_PROXY_CIDRS(L1 靠它信任前置代理 XFF)。
    # 已设(运维自建反代/环境覆盖)则尊重; 否则自动选不冲突子网。二者默认同值。
    if [[ -z "${ZFC_DOCKER_SUBNET:-}" ]]; then
        ZFC_DOCKER_SUBNET="$(pick_free_subnet)"
    fi
    TRUSTED_PROXY_CIDRS="${TRUSTED_PROXY_CIDRS:-$ZFC_DOCKER_SUBNET}"
    log_info "受信代理网段: ZFC_DOCKER_SUBNET=$ZFC_DOCKER_SUBNET  TRUSTED_PROXY_CIDRS=$TRUSTED_PROXY_CIDRS"

    cat > .env << EOF
# Database Types (builtin/external/disabled)
POSTGRES_TYPE=$(quote_env_value "${POSTGRES_TYPE}")
REDIS_TYPE=$(quote_env_value "${REDIS_TYPE}")
TDENGINE_TYPE=$(quote_env_value "${TDENGINE_TYPE}")

# TDengine feature toggle
DISABLE_TDENGINE=$(if [[ "$TDENGINE_TYPE" == "disabled" ]]; then echo "true"; else echo "false"; fi)

# Database Configuration (for builtin databases)
POSTGRES_PASSWORD=$(quote_env_value "${POSTGRES_PASSWORD:-}")
REDIS_PASSWORD=$(quote_env_value "${REDIS_PASSWORD:-}")
TDENGINE_ROOT_PASSWORD=$(quote_env_value "${TDENGINE_ROOT_PASSWORD:-}")

# Database Connection URLs
POSTGRES_URL=$(quote_env_value "${POSTGRES_URL}")
REDIS_URL=$(quote_env_value "${REDIS_URL}")
TDENGINE_URL=$(quote_env_value "${TDENGINE_URL:-}")

# Legacy database environment variables (for backward compatibility)
DB_PATH=$(quote_env_value "${POSTGRES_URL}")
REDIS_PATH=$(quote_env_value "${REDIS_URL}")

# Prisma Configuration
RUN_PRISMA_MIGRATION=$(quote_env_value "${RUN_PRISMA_MIGRATION}")

# Domain Configuration
WEB_DOMAIN=$(quote_env_value "${WEB_DOMAIN}")
CONTROLER_DOMAIN=$(quote_env_value "${CONTROLER_DOMAIN}")

# License Configuration
ZFC_INSTANCE_ID=$(quote_env_value "${ZFC_INSTANCE_ID}")
ZFC_API_KEY=$(quote_env_value "${ZFC_API_KEY}")

# Management Keys
MGMT_ARRANGER_PRIV_KEY=$(quote_env_value "${MGMT_ARRANGER_PRIV_KEY}")
MGMT_PUBKEY=$(quote_env_value "${MGMT_PUBKEY}")

# web keys
WEB_PRIV_KEY=$(quote_env_value "${WEB_PRIV_KEY}")
WEB_PUBKEY=$(quote_env_value "${WEB_PUBKEY}")

# Binary upgrade: require --version label match after download (controller + workers).
# Override with ZFC_STRICT_BINARY_VERSION=0 for hot-swap / intentional label mismatch.
ZFC_STRICT_BINARY_VERSION=$(quote_env_value "${ZFC_STRICT_BINARY_VERSION:-1}")

# JWT Secret
JWT_SECRET=$(quote_env_value "${JWT_SECRET}")

# 升级通道: --update 去哪儿找新版本。latest = 跟随最新发布; 也可钉成具体版本号。
# 与下方镜像引用的区别: 这里是「意图」, 下面是「当前实际部署的版本」(事实)。
ZFC_UPDATE_CHANNEL=$(quote_env_value "${ZFC_UPDATE_CHANNEL:-latest}")

# Docker Images —— 由 --install / --update 写入的**当前实际部署版本**, 不要手改。
ZF_WEB_IMAGE=$(quote_env_value "${ZF_WEB_IMAGE}")
ZF_CONTROLER_IMAGE=$(quote_env_value "${ZF_CONTROLER_IMAGE}")
RRD_SERVICE_IMAGE=$(quote_env_value "${RRD_SERVICE_IMAGE}")
ZFC_UTIL_IMAGE=$(quote_env_value "${ZFC_UTIL_IMAGE}")
ZFC_ADMIN_IMAGE=$(quote_env_value "${ZFC_ADMIN_IMAGE}")
ZFC_PRISMA_IMAGE=$(quote_env_value "${ZFC_PRISMA_IMAGE}")

# Caddy Configuration
CADDY_ENABLED=$(quote_env_value "${CADDY_ENABLED:-false}")
CADDY_EMAIL=$(quote_env_value "${CADDY_EMAIL:-}")

# Trusted reverse-proxy subnet — pins the docker network subnet (docker-compose networks.*.ipam)
# and tells L1 to trust that network's XFF so panels resolve the real client IP (not 172.x).
ZFC_DOCKER_SUBNET=$(quote_env_value "${ZFC_DOCKER_SUBNET}")
TRUSTED_PROXY_CIDRS=$(quote_env_value "${TRUSTED_PROXY_CIDRS}")
EOF
    
    log_success "环境文件创建完成"
    log_info "数据库连接配置:"
    log_info "  PostgreSQL: $POSTGRES_TYPE"
    log_info "  Redis: $REDIS_TYPE"
    log_info "  TDengine: $TDENGINE_TYPE"
}

# Generate Caddyfile
generate_caddyfile() {
    if [[ "$CADDY_ENABLED" != "true" ]]; then
        log_info "跳过 Caddyfile 生成"
        return 0
    fi
    
    log_info "生成 Caddyfile 配置..."

    # 邮箱为空时省略 tls 指令(非法的 `tls ` 会让 Caddy 拒绝配置)。
    # 省略后 Caddy 仍按域名自动签发证书, 只是没有 ACME 账户邮箱与到期通知。
    # 每个站点块单独拼装, 条件性插入 tls 行, 避免在 heredoc 内做跨行展开(脆弱)。
    caddy_site_block() {
        local domain="$1" upstream="$2"
        echo "${domain} {"
        [[ -n "${CADDY_EMAIL:-}" ]] && echo "    tls ${CADDY_EMAIL}"
        cat <<EOF
    encode gzip
    reverse_proxy ${upstream}

    # 错误处理
    handle_errors {
        @5xx expression {http.error.status_code} >= 500
        respond "服务暂时不可用，请稍后重试" 503
    }

    # 日志记录
    log {
        level INFO
        format console
    }
}
EOF
    }

    {
        echo "# ZFC Caddy 配置文件"
        echo "# 自动生成于 $(date)"
        echo
        echo "# 前端 Web 服务"
        caddy_site_block "${WEB_DOMAIN}" "zf-web:3030"
        echo
        echo "# 控制器服务"
        caddy_site_block "${CONTROLER_DOMAIN}" "zf-controler:3100"
    } > Caddyfile

    unset -f caddy_site_block

    log_success "Caddyfile 配置生成完成"
    log_info "配置文件位置: $(pwd)/Caddyfile"
}

# Setup Caddy service
setup_caddy() {
    if [[ "$CADDY_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_info "启动 Caddy Docker 容器..."
    
    # Start Caddy with the caddy profile
    $DOCKER_COMPOSE_CMD --profile caddy up -d caddy
    
    # Wait for Caddy to be ready
    log_info "等待 Caddy 启动..."
    local retry_count=0
    until $DOCKER_COMPOSE_CMD exec -T caddy caddy version > /dev/null 2>&1; do
        sleep 2
        retry_count=$((retry_count + 1))
        if [ $retry_count -gt 30 ]; then
            log_error "Caddy 启动超时"
            return 1
        fi
    done
    
    # Test configuration
    log_info "验证 Caddy 配置..."
    if $DOCKER_COMPOSE_CMD exec -T caddy caddy validate --config /etc/caddy/Caddyfile; then
        log_success "Caddy 配置验证通过"
    else
        log_warning "Caddy 配置验证失败，请检查配置"
    fi
    
    # Check if Caddy is healthy
    sleep 5
    if $DOCKER_COMPOSE_CMD ps caddy | grep -q "healthy\|Up"; then
        log_success "Caddy 容器启动成功"
        log_info "HTTPS 证书将自动申请和续期"
    else
        log_error "Caddy 容器启动失败"
        log_info "请检查日志: $DOCKER_COMPOSE_CMD logs caddy"
        return 1
    fi
}

# Initialize PostgreSQL
init_postgres() {
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        log_info "初始化内置 PostgreSQL..."
        
        # Clean up existing postgres volumes if needed
        local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        if docker volume ls -q --filter "name=${project_name}_postgres" | head -1 >/dev/null 2>&1; then
            log_info "清理现有 PostgreSQL 数据卷..."
            docker volume ls -q --filter "name=${project_name}_postgres" | xargs -r docker volume rm 2>/dev/null || true
        fi
        
        # Start PostgreSQL service
        $DOCKER_COMPOSE_CMD up -d postgres
        
        # Wait for postgres to be ready
        log_info "等待 PostgreSQL 启动..."
        local retry_count=0
        until $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U postgres; do
            sleep 2
            retry_count=$((retry_count + 1))
            if [ $retry_count -gt 30 ]; then
                log_error "PostgreSQL 启动超时"
                return 1
            fi
        done
        
        # Additional wait to ensure PostgreSQL is fully initialized
        log_info "等待 PostgreSQL 完全初始化..."
        sleep 5
        
        # Test PostgreSQL readiness with actual password
        log_info "测试 PostgreSQL 密码认证..."
        local retry_count=0
        until $DOCKER_COMPOSE_CMD exec -T postgres sh -c "PGPASSWORD=\"${POSTGRES_PASSWORD}\" psql -U postgres -c 'SELECT 1;'" > /dev/null 2>&1; do
            sleep 2
            retry_count=$((retry_count + 1))
            if [ $retry_count -gt 20 ]; then
                log_error "PostgreSQL 密码认证失败"
                return 1
            fi
        done
        
        log_success "内置 PostgreSQL 初始化完成"
    else
        log_info "验证外部 PostgreSQL 连接..."
        if validate_postgres_connection "$EXTERNAL_POSTGRES_HOST" "$EXTERNAL_POSTGRES_PORT" "$EXTERNAL_POSTGRES_USER" "$EXTERNAL_POSTGRES_PASSWORD" "$EXTERNAL_POSTGRES_DB"; then
            log_success "外部 PostgreSQL 连接验证成功"
        else
            log_error "外部 PostgreSQL 连接验证失败"
            return 1
        fi
    fi
}

# Initialize Redis
init_redis() {
    if [[ "$REDIS_TYPE" == "builtin" ]]; then
        log_info "初始化内置 Redis..."
        
        # Clean up existing redis volumes if needed
        local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        if docker volume ls -q --filter "name=${project_name}_redis" | head -1 >/dev/null 2>&1; then
            log_info "清理现有 Redis 数据卷..."
            docker volume ls -q --filter "name=${project_name}_redis" | xargs -r docker volume rm 2>/dev/null || true
        fi
        
        # Start Redis service
        $DOCKER_COMPOSE_CMD up -d redis
        
        # Wait for redis to be ready
        log_info "等待 Redis 启动..."
        until $DOCKER_COMPOSE_CMD exec -T redis redis-cli --no-auth-warning -a "$REDIS_PASSWORD" ping | grep -q PONG; do
            sleep 2
        done
        
        log_success "内置 Redis 初始化完成"
    else
        log_info "验证外部 Redis 连接..."
        if validate_redis_connection "$EXTERNAL_REDIS_HOST" "$EXTERNAL_REDIS_PORT" "$EXTERNAL_REDIS_PASSWORD"; then
            log_success "外部 Redis 连接验证成功"
        else
            log_error "外部 Redis 连接验证失败"
            return 1
        fi
    fi
}

# Initialize TDengine
init_tdengine() {
    if [[ "$TDENGINE_TYPE" == "disabled" ]]; then
        log_info "TDengine 已禁用，跳过初始化"
        return 0
    fi

    if [[ "$TDENGINE_TYPE" == "builtin" ]]; then
        log_info "初始化内置 TDengine..."
        
        # Clean up existing tdengine volumes if needed
        local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        if docker volume ls -q --filter "name=${project_name}_tdengine" | head -1 >/dev/null 2>&1; then
            log_info "清理现有 TDengine 数据卷..."
            docker volume ls -q --filter "name=${project_name}_tdengine" | xargs -r docker volume rm 2>/dev/null || true
        fi
        
        # Start TDengine service
        $DOCKER_COMPOSE_CMD up -d tdengine
        
        # Start TDengine password initialization
        log_info "启动 TDengine 密码初始化..."
        $DOCKER_COMPOSE_CMD --profile init up tdengine-init
        
        # Wait for TDengine initialization to complete
        log_info "等待 TDengine 密码初始化完成..."
        local retry_count=0
        while docker ps --filter "name=zfc-tdengine-init" --filter "status=running" | grep -q zfc-tdengine-init; do
            sleep 2
            retry_count=$((retry_count + 1))
            if [ $retry_count -gt 60 ]; then
                log_warning "TDengine 初始化等待超时，继续执行..."
                break
            fi
        done
        
        # Check if initialization was successful
        if docker ps -a --filter "name=zfc-tdengine-init" --filter "exited=0" | grep -q zfc-tdengine-init; then
            log_success "TDengine 密码初始化成功"
            
            # Remove the initialization service from docker-compose.yml and override to avoid future delays
            log_info "清理临时初始化服务..."
            if grep -q "tdengine-init:" docker-compose.yml; then
                cp docker-compose.yml docker-compose.yml.backup
                remove_compose_service docker-compose.yml "tdengine-init"
                log_success "已从 docker-compose.yml 中移除临时初始化服务"
            fi
            if [[ -f "docker-compose.override.yml" ]] && grep -q "tdengine-init:" docker-compose.override.yml; then
                remove_compose_service docker-compose.override.yml "tdengine-init"
                log_success "已从 docker-compose.override.yml 中移除临时初始化服务"
            fi

            # Remove the container
            docker rm -f zfc-tdengine-init 2>/dev/null || true
            log_success "已清理初始化容器"
        else
            log_warning "TDengine 初始化可能失败，请检查日志: docker logs zfc-tdengine-init"
        fi
        
        log_success "内置 TDengine 初始化完成"
    else
        log_info "验证外部 TDengine 连接..."
        if validate_tdengine_connection "$EXTERNAL_TDENGINE_HOST" "$EXTERNAL_TDENGINE_PORT" "$EXTERNAL_TDENGINE_USER" "$EXTERNAL_TDENGINE_PASSWORD"; then
            log_success "外部 TDengine 连接验证成功"
        else
            log_error "外部 TDengine 连接验证失败"
            return 1
        fi
    fi
}

# Run Prisma migrations
run_prisma_migration() {
    if [[ "$RUN_PRISMA_MIGRATION" != "true" ]]; then
        local disabled_bundle_rc
        if prepare_schema_bundle "$ZF_WEB_IMAGE" "$ZF_CONTROLER_IMAGE"; then
            log_error "目标镜像启用了 schema 启动门禁，不能设置 RUN_PRISMA_MIGRATION=false"
            return 1
        else
            disabled_bundle_rc=$?
            [[ "$disabled_bundle_rc" -eq 2 ]] || return 1
            log_info "legacy 镜像：按配置跳过 Prisma 数据库迁移"
            return 0
        fi
    fi
    
    log_info "执行数据库迁移..."
    
    local bundle_rc
    if prepare_schema_bundle "$ZF_WEB_IMAGE" "$ZF_CONTROLER_IMAGE"; then
        install_verified_schema_bundle || return 1
        log_info "使用目标镜像内置的版本化 Prisma schema"
    else
        bundle_rc=$?
        if [[ "$bundle_rc" -ne 2 ]]; then
            return 1
        fi

        SCHEMA_SOURCE="legacy"
        if [[ -f "prisma/schema.prisma" ]]; then
            log_warning "目标镜像为 legacy 版本，沿用本地 Prisma schema"
        else
            log_warning "目标镜像不含 schema bundle，兼容模式从旧 CDN 下载 schema"
            mkdir -p prisma
            if ! curl -fsSL "https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/schema.prisma" -o prisma/schema.prisma; then
                log_error "无法下载 legacy Prisma schema 文件"
                return 1
            fi
        fi
    fi

    SCHEMA_DIR="$(pwd)/prisma"
    prepare_schema_state_sql || return 1
    
    # Determine the correct network name for migration
    local network_name network_arg db_url
    
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        # Get the actual compose network name
        network_name=$(get_compose_network)
        log_info "检测到 Docker Compose 网络: $network_name"
        
        # Verify the network exists, create if it doesn't
        if ! docker network inspect "$network_name" >/dev/null 2>&1; then
            log_info "网络不存在，创建网络: $network_name"
            docker network create "$network_name" || {
                log_error "无法创建网络 $network_name"
                return 1
            }
        fi
        
        # Use internal database URL for builtin PostgreSQL
        db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/zfc?schema=public"
        network_arg="--network $network_name"
    else
        # Use external database URL
        db_url="postgresql://${EXTERNAL_POSTGRES_USER}:${EXTERNAL_POSTGRES_PASSWORD}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}?schema=public"
        network_arg=""
    fi

    preflight_current_schema_state "$db_url" "$network_arg" || return 1
    
    log_info "运行 Prisma 迁移..."
    log_info "使用数据库 URL: ${db_url%:*}:****@${db_url#*@}"
    
    docker run --rm \
        $network_arg \
        -v "$SCHEMA_DIR:/app/prisma" \
        -w /app \
        -e DATABASE_URL="$db_url" \
        "${ZFC_PRISMA_IMAGE}" \
        sh -c "
            echo '使用预装 Prisma CLI，跳过安装步骤...' &&
            echo '修改 schema 文件以支持 npx prisma...' &&
            sed 's/provider = \"cargo prisma\"/provider = \"prisma-client-js\"/' prisma/schema.prisma > prisma/schema.prisma.tmp && mv prisma/schema.prisma.tmp prisma/schema.prisma &&
            sed 's|output.*|// output removed for npx compatibility|' prisma/schema.prisma > prisma/schema.prisma.tmp && mv prisma/schema.prisma.tmp prisma/schema.prisma &&
            if [ -d prisma/migrate-hooks ]; then
              for hook in prisma/migrate-hooks/*.sql; do
                [ -f \"\$hook\" ] || continue
                echo \"执行预迁移 hook: \$hook\"
                npx prisma db execute --file \"\$hook\" --schema prisma/schema.prisma || exit 1
              done
            fi &&
            echo '开始执行数据库迁移（跳过代码生成）...' &&
            npx prisma db push --schema=prisma/schema.prisma --accept-data-loss --skip-generate &&
            if [ -f prisma/.zfc_schema_state.sql ]; then
              npx prisma db execute --file prisma/.zfc_schema_state.sql --schema prisma/schema.prisma
            fi
        "
    
    log_success "Prisma 数据库迁移完成"
}

# Initialize database - main function
init_database() {
    log_info "初始化数据库..."
    
    # Wait for network to be created if using Docker services
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" || "$TDENGINE_TYPE" == "builtin" ]]; then
        log_info "等待 Docker 网络创建..."
        sleep 3
    fi
    
    # Initialize each database component
    init_postgres
    init_redis
    init_tdengine
    
    # Run Prisma migrations
    run_prisma_migration
    
    log_success "数据库初始化完成"
}

# Create admin user
# 查询 DB 中是否已存在 admin@zfc.local 的 token(纯 DB 读, 不依赖 .admin_token)。
# 复用 show-admin-token 命令; 精确按 "Address: admin@zfc.local" 配对其紧邻下一行 "Token:"。
# 设置全局 FOUND_ADMIN_TOKEN(唯一匹配时) / FOUND_ADMIN_DUP_COUNT(多条时)。
# 返回: 0=找到唯一, 1=未找到/查询失败, 2=多条重复(疑似历史坏数据, 调用方应人工介入)。
FOUND_ADMIN_TOKEN=""
FOUND_ADMIN_DUP_COUNT=0
fetch_admin_token_from_db() {
    local db_url="$1" redis_url="$2" network_args="$3"
    FOUND_ADMIN_TOKEN=""
    FOUND_ADMIN_DUP_COUNT=0
    local out
    out=$(docker run --rm \
        $network_args \
        -e DB_PATH="$db_url" \
        -e REDIS_PATH="$redis_url" \
        -e MGMT_ARRANGER_PRIV_KEY="${MGMT_ARRANGER_PRIV_KEY}" \
        -e ARRANGER_HOSTS_URL="https://${CONTROLER_DOMAIN}" \
        "$ZFC_ADMIN_IMAGE" \
        show-admin-token 2>/dev/null) || return 1
    local tokens
    tokens=$(printf '%s\n' "$out" | awk '
        /^[[:space:]]*Address:[[:space:]]*admin@zfc\.local[[:space:]]*$/ { want=1; next }
        want && /^[[:space:]]*Token:[[:space:]]*/ { sub(/^[[:space:]]*Token:[[:space:]]*/, ""); print; want=0 }
    ')
    [[ -n "${tokens//[[:space:]]/}" ]] || return 1
    local n
    n=$(printf '%s\n' "$tokens" | grep -c .)
    if [[ "$n" -gt 1 ]]; then
        FOUND_ADMIN_DUP_COUNT="$n"
        return 2
    fi
    FOUND_ADMIN_TOKEN=$(printf '%s' "$tokens" | tr -d '[:space:]')
    [[ -n "$FOUND_ADMIN_TOKEN" ]] || return 1
    return 0
}

create_admin_user() {
    log_info "创建管理员账户..."

    # Create temporary directory if not exists
    local TEMP_DIR="/tmp"
    
    # Create temporary admin user JSON file
    local admin_json_file="$TEMP_DIR/admin_user.json"
    cat > "$admin_json_file" << EOF
{
  "users": [
    {
      "address": "admin@zfc.local",
      "tg_user": null,
      "tg_chat_id": null,
      "bandwidth": null,
      "traffic": 1048576,
      "activated": true,
      "ports": [],
      "max_ports_per_server": 2000,
      "bill_type": {
        "OneTime": {
          "price": 0,
          "days": 365
        }
      },
      "total_days": 3650,
      "lines": [],
      "is_admin": true
    }
  ]
}
EOF
    
    # Run zfc-admin to create user
    log_info "运行 zfc-admin 创建管理员用户..."
    
    # Determine the correct network name for admin creation
    local network_name
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" ]]; then
        network_name=$(get_compose_network)
        log_info "使用 Docker Compose 网络创建管理员: $network_name"
        
        # Verify network exists
        if ! docker network inspect "$network_name" >/dev/null 2>&1; then
            log_error "Docker Compose 网络 $network_name 不存在"
            log_error "请确保 Docker Compose 服务已启动"
            return 1
        fi
    else
        # For external databases, no network needed
        network_name=""
        log_info "使用外部数据库，无需 Docker 网络"
    fi
    
    # Test database connectivity from admin container
    log_info "测试数据库连接性..."
    local db_test_output
    
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        db_test_output=$(docker run --rm \
            --network "$network_name" \
            -e PGPASSWORD="${POSTGRES_PASSWORD}" \
            postgres:15-alpine \
            psql -h postgres -U postgres -d zfc -c "SELECT 1;" 2>&1) || {
            log_error "数据库连接测试输出: $db_test_output"
            die "$EXIT_DB_CONNECT" "从 admin 容器无法连接内置数据库"
        }
    else
        # For external database, test connectivity directly
        if ! validate_postgres_connection "$EXTERNAL_POSTGRES_HOST" "$EXTERNAL_POSTGRES_PORT" "$EXTERNAL_POSTGRES_USER" "$EXTERNAL_POSTGRES_PASSWORD" "$EXTERNAL_POSTGRES_DB"; then
            die "$EXIT_DB_CONNECT" "外部 PostgreSQL 数据库连接失败"
        fi
    fi
    
    log_success "数据库连接测试成功"
    
    # Test zfc-admin container first
    log_info "测试 zfc-admin 容器启动..."
    local test_output
    test_output=$(timeout 30 docker run --rm "$ZFC_ADMIN_IMAGE" --help 2>&1) || {
        log_warning "zfc-admin 容器启动测试失败"
        log_info "测试输出: $test_output"
        log_info "继续尝试运行 zfc-admin..."
    }
    if [[ $test_output == *"Usage:"* ]] || [[ $test_output == *"USAGE:"* ]]; then
        log_success "zfc-admin 容器测试成功"
    fi
    
    # Add debugging - show admin JSON content
    log_info "管理员用户配置:"
    cat "$admin_json_file"
    
    # Prepare database and Redis URLs based on configuration
    local db_url redis_url network_args
    
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/zfc?schema=public"
    else
        db_url="postgresql://${EXTERNAL_POSTGRES_USER}:${EXTERNAL_POSTGRES_PASSWORD}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}?schema=public"
    fi
    
    if [[ "$REDIS_TYPE" == "builtin" ]]; then
        redis_url="redis://:${REDIS_PASSWORD}@redis:6379"
    else
        if [[ -n "$EXTERNAL_REDIS_PASSWORD" ]]; then
            redis_url="redis://:${EXTERNAL_REDIS_PASSWORD}@${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
        else
            redis_url="redis://${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
        fi
    fi
    
    # Set network arguments based on database type
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" ]]; then
        network_args="--network $network_name"
    else
        network_args=""
    fi

    # 先查后建(幂等, 不轻信 .admin_token): DB 已有 admin@zfc.local 则复用其 token、跳过 add-user,
    # 避免 add-user 每次新建造成重复 admin(残留高权限 token)。
    #   内置库每次被 init_* 清空 → 通常查不到 → 照常新建;
    #   外部库复用 / 半成品断点(DB 已写 admin 但 .admin_token 未落地) → 查到即复用。
    local existing_rc=1
    fetch_admin_token_from_db "$db_url" "$redis_url" "$network_args" && existing_rc=0 || existing_rc=$?
    if [[ "$existing_rc" -eq 2 ]]; then
        die "$EXIT_ADMIN_CREATE" "检测到 ${FOUND_ADMIN_DUP_COUNT} 个 admin@zfc.local 高权限账号(疑似历史重复)。请人工核对并清理多余 admin 后重试。"
    fi
    if [[ "$existing_rc" -eq 0 && -n "$FOUND_ADMIN_TOKEN" ]]; then
        log_success "数据库已存在管理员 admin@zfc.local, 复用其 token(跳过新建, 避免重复 admin)"
        ( umask 077; echo "$FOUND_ADMIN_TOKEN" > .admin_token )
        chmod 600 .admin_token 2>/dev/null || true
        ADMIN_TOKEN="$FOUND_ADMIN_TOKEN"
        rm -f "$admin_json_file"
        return 0
    fi

    log_info "运行 zfc-admin 容器..."
    log_info "容器环境变量:"
    log_info "  DB_PATH=${db_url%:*}:****@${db_url#*@}"
    log_info "  REDIS_PATH=${redis_url%:*}:****@${redis_url#*@}"
    log_info "  ARRANGER_HOSTS_URL=https://${CONTROLER_DOMAIN}"
    
    # Use timeout to prevent hanging
    log_info "启动 zfc-admin 容器（60秒超时）..."
    
    local admin_output
    local exit_code
    
    # Run container with timeout in background and monitor
    {
        timeout 60 docker run --rm \
            $network_args \
            -v "$admin_json_file:/tmp/admin_user.json" \
            -e DB_PATH="$db_url" \
            -e REDIS_PATH="$redis_url" \
            -e MGMT_ARRANGER_PRIV_KEY="${MGMT_ARRANGER_PRIV_KEY}" \
            -e ARRANGER_HOSTS_URL="https://${CONTROLER_DOMAIN}" \
            "$ZFC_ADMIN_IMAGE" \
            add-user --user-file-path /tmp/admin_user.json
    } > /tmp/admin_output.log 2>&1
    
    exit_code=$?
    admin_output=$(cat /tmp/admin_output.log 2>/dev/null || echo "无法读取输出文件")
    
    log_info "zfc-admin 容器退出码: $exit_code"
    
    case $exit_code in
        0)
            log_success "zfc-admin 容器成功完成"
            ;;
        124)
            log_error "zfc-admin 容器执行超时（60秒）"
            log_error "这可能是由于网络连接问题或容器内部错误"
            ;;
        *)
            log_error "zfc-admin 容器执行失败"
            ;;
    esac
    
    log_info "zfc-admin 完整输出:"
    echo "$admin_output"
    
    if [[ $exit_code -ne 0 ]]; then
        die "$EXIT_ADMIN_CREATE" "zfc-admin 容器运行失败 (退出码: $exit_code)"
    fi
    
    # Extract token from output
    local admin_token
    admin_token=$(echo "$admin_output" | grep "add user:" | grep "token:" | awk '{print $NF}')
    
    if [[ -z "$admin_token" ]]; then
        log_error "无法从输出中提取管理员 token"
        log_error "尝试查找其他 token 格式..."
        admin_token=$(echo "$admin_output" | grep -i "token" | tail -1 | awk '{print $NF}')
        
        if [[ -z "$admin_token" ]]; then
            die "$EXIT_ADMIN_CREATE" "仍然无法获取 token，请检查 zfc-admin 输出格式"
        fi
    fi
    
    # Save admin token to file (限制权限: 含敏感凭证)
    ( umask 077; echo "$admin_token" > .admin_token )
    chmod 600 .admin_token 2>/dev/null || true
    # 暴露给成功 JSON 输出
    ADMIN_TOKEN="$admin_token"

    log_success "管理员账户创建完成"
    log_info "管理员 Token: $admin_token"
    
    # Clean up
    rm -f "$admin_json_file"
    rm -f /tmp/admin_output.log
    
    return 0
}

# Start services
start_services() {
    log_info "启动所有服务..."

    # Safety: ensure tdengine-init is removed from compose file AND override
    # before pull/up (it's a one-shot init service that should have been
    # cleaned up already, but setup_docker_log_cleanup may have added it
    # to the override file before init_tdengine removed it)
    if grep -q "^  tdengine-init:" docker-compose.yml 2>/dev/null; then
        log_info "清理残留的 tdengine-init 服务定义..."
        remove_compose_service docker-compose.yml "tdengine-init"
    fi
    if [[ -f "docker-compose.override.yml" ]] && grep -q "^  tdengine-init:" docker-compose.override.yml 2>/dev/null; then
        log_info "清理 override 文件中残留的 tdengine-init 服务定义..."
        remove_compose_service docker-compose.override.yml "tdengine-init"
    fi

    # Pull all images
    log_info "拉取 Docker 镜像..."
    $DOCKER_COMPOSE_CMD pull
    
    # Start all services
    $DOCKER_COMPOSE_CMD up -d
    
    # Wait for services to be healthy
    log_info "等待服务启动..."
    sleep 30
    
    # Check service status
    if $DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
        log_success "服务启动成功"
    else
        log_warning "部分服务可能未正常启动，请检查日志"
    fi
}

# Show final information
show_final_info() {
    echo
    log_success "=== ZFC 安装完成 ==="
    echo
    echo -e "${GREEN}访问地址:${NC}"
    echo -e "  前端界面: https://${WEB_DOMAIN}"
    echo
    echo -e "${GREEN}本地端口映射（仅供调试）:${NC}"
    echo -e "  前端界面: http://localhost:8080"
    echo
    echo -e "${GREEN}管理员登录信息:${NC}"
    if [[ -f ".admin_token" ]]; then
        local admin_token=$(cat .admin_token)
        echo -e "  管理员 Token: ${GREEN}${admin_token}${NC}"
        echo -e "  请使用此 Token 登录前端界面进行管理"
    else
        echo -e "  ${RED}未找到管理员 Token 文件${NC}"
    fi
    echo
    echo -e "${GREEN}数据库信息:${NC}"
    if [[ "$POSTGRES_TYPE" == "builtin" ]]; then
        echo -e "  PostgreSQL (内置): localhost:5432"
        echo -e "    用户名: postgres"
        echo -e "    密码: ${POSTGRES_PASSWORD}"
    else
        echo -e "  PostgreSQL (外部): ${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}"
        echo -e "    数据库: ${EXTERNAL_POSTGRES_DB}"
    fi
    echo
    if [[ "$REDIS_TYPE" == "builtin" ]]; then
        echo -e "  Redis (内置): localhost:6379"
        echo -e "    密码: ${REDIS_PASSWORD}"
    else
        echo -e "  Redis (外部): ${EXTERNAL_REDIS_HOST}:${EXTERNAL_REDIS_PORT}"
    fi
    echo
    if [[ "$TDENGINE_TYPE" == "disabled" ]]; then
        echo -e "  TDengine: ${YELLOW}已禁用${NC}（历史统计功能不可用）"
    elif [[ "$TDENGINE_TYPE" == "builtin" ]]; then
        echo -e "  TDengine (内置): localhost:6030"
        echo -e "    用户名: root"
        echo -e "    密码: ${TDENGINE_ROOT_PASSWORD}"
    else
        echo -e "  TDengine (外部): ${EXTERNAL_TDENGINE_HOST}:${EXTERNAL_TDENGINE_PORT}"
        echo -e "    用户名: ${EXTERNAL_TDENGINE_USER}"
    fi
    echo
    echo -e "${GREEN}管理命令:${NC}"
    echo -e "  查看服务状态: ${DOCKER_COMPOSE_CMD} ps"
    echo -e "  查看日志: ${DOCKER_COMPOSE_CMD} logs -f [service_name]"
    echo -e "  停止服务: ${DOCKER_COMPOSE_CMD} down"
    echo -e "  重启服务: ${DOCKER_COMPOSE_CMD} restart"
    echo
    echo -e "${YELLOW}重要提醒:${NC}"
    echo -e "  - 请妥善保管 .env 和 .admin_token 文件"
    if [[ "$TDENGINE_TYPE" == "builtin" ]]; then
        echo -e "  - TDengine 初始化服务已自动清理，不会影响后续启动速度"
    fi
    if [[ "${CADDY_ENABLED}" == "true" ]]; then
        echo -e "  - ${GREEN}Caddy 反向代理已配置并启动${NC}"
        echo -e "    ${WEB_DOMAIN} -> 自动 HTTPS 代理到 zf-web 容器"
        echo -e "    ${CONTROLER_DOMAIN} -> 自动 HTTPS 代理到 zf-controler 容器"
        echo -e "    配置文件: $(pwd)/Caddyfile"
        echo -e "    HTTPS 证书自动申请和续期"
        echo -e "    ${RED}注意：如使用 Cloudflare，两个域名都不能开启小黄云${NC}"
        echo -e "  - Caddy 管理命令："
        echo -e "    重启: ${DOCKER_COMPOSE_CMD} --profile caddy restart caddy"
        echo -e "    状态: ${DOCKER_COMPOSE_CMD} ps caddy"
        echo -e "    日志: ${DOCKER_COMPOSE_CMD} logs -f caddy"
        echo -e "    停止: ${DOCKER_COMPOSE_CMD} --profile caddy stop caddy"
        echo -e "    启动: ${DOCKER_COMPOSE_CMD} --profile caddy up -d caddy"
    else
        echo -e "  - ${RED}必须配置反向代理${NC}，将以下域名代理到对应服务："
        echo -e "    ${WEB_DOMAIN} -> http://localhost:8080 (zf-web)"
        echo -e "    ${CONTROLER_DOMAIN} -> http://localhost:3100 (zf-controler)"
        echo -e "  - 系统配置使用 HTTPS，请确保反向代理启用 SSL"
        echo -e "  - ${YELLOW}推荐使用 Caddy 自动配置 HTTPS:${NC}"
        echo -e "    参考配置文件: $(pwd)/Caddyfile (如果已生成)"
    fi
    echo -e "  - 管理员 Token 仅在首次安装时显示，请妥善保存"
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" || "$TDENGINE_TYPE" == "builtin" ]]; then
        echo -e "  - 建议定期备份内置数据库数据"
    fi
    echo
}

# Update database schema function
update_schema() {
    log_info "检查数据库 schema 更新..."
    
    # Check if .env file exists
    if [[ ! -f ".env" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "系统未安装(未找到 .env 文件); 请先执行全新安装 (--install)" || return 1
    fi
    
    # Source environment file to get database configuration
    source .env

    # 上面这行会把 resolve_deploy_version export 的钉死引用冲回 .env 文件里的**旧**值
    # (文件改写被推迟到本函数成功之后)。不重新施加的话, 下面的 prepare_schema_bundle
    # 会用旧镜像抽 schema → 库被迁到旧 schema, 而随后 .env 却写入新版本 → 起新镜像
    # 配旧库 → crash-loop。
    apply_resolved_image_pins

    # Old installations may not persist IMAGE_TAG/registry separately. The
    # complete image references in .env or the rendered compose file are the
    # compatibility source of truth.
    if [[ -z "${ZF_WEB_IMAGE:-}" ]]; then
        ZF_WEB_IMAGE=$($DOCKER_COMPOSE_CMD config --images 2>/dev/null | grep '/zf-web:' | head -1 || true)
    fi
    if [[ -z "${ZF_CONTROLER_IMAGE:-}" ]]; then
        ZF_CONTROLER_IMAGE=$($DOCKER_COMPOSE_CMD config --images 2>/dev/null | grep '/zf-controler:' | head -1 || true)
    fi
    if [[ -z "$ZF_WEB_IMAGE" || -z "$ZF_CONTROLER_IMAGE" ]]; then
        log_error "无法从旧 .env/docker-compose.yml 解析 zf-web 与 zf-controler 镜像"
        return 1
    fi
    
    # Only proceed if we're using Prisma migrations
    if [[ "${RUN_PRISMA_MIGRATION:-true}" != "true" ]]; then
        local disabled_bundle_rc
        if prepare_schema_bundle "$ZF_WEB_IMAGE" "$ZF_CONTROLER_IMAGE"; then
            log_error "目标镜像启用了 schema 启动门禁，不能跳过 Prisma schema 更新"
            return 1
        else
            disabled_bundle_rc=$?
            [[ "$disabled_bundle_rc" -eq 2 ]] || return 1
            log_info "legacy 镜像：按配置跳过 Prisma schema 更新"
            return 0
        fi
    fi
    
    # Create backup directory if not exists
    mkdir -p schema_backup
    
    # Backup current schema if exists
    if [[ -f "prisma/schema.prisma" ]]; then
        local backup_name="schema_backup/schema.prisma.$(date +%Y%m%d_%H%M%S)"
        cp "prisma/schema.prisma" "$backup_name"
        log_info "当前 schema 已备份到: $backup_name"
    fi
    
    local bundle_rc
    if prepare_schema_bundle "$ZF_WEB_IMAGE" "$ZF_CONTROLER_IMAGE"; then
        install_verified_schema_bundle || return 1
        log_success "已安装目标镜像内置 schema: release=$TARGET_SCHEMA_RELEASE"
    else
        bundle_rc=$?
        if [[ "$bundle_rc" -ne 2 ]]; then
            return 1
        fi

        # Dual-protocol transition: old images keep their historical behavior.
        SCHEMA_SOURCE="legacy"
        log_warning "目标镜像不含 schema bundle，进入 legacy 兼容迁移"
        mkdir -p prisma
        local temp_schema="prisma/schema.prisma.new"
        if ! curl -fsSL "https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/schema.prisma" -o "$temp_schema"; then
            log_error "无法下载 legacy schema 文件"
            return 1
        fi
        mv "$temp_schema" prisma/schema.prisma
        rm -rf prisma/migrate-hooks
    fi

    prepare_schema_state_sql || return 1
    
    # Generate and apply migration
    if ! apply_schema_migration; then
        log_error "Schema 迁移失败，仅恢复本地 schema 文件；数据库请使用迁移前备份恢复"
        rollback_schema_changes
        return 1
    fi
}

# Apply schema migration function
apply_schema_migration() {
    log_info "应用数据库 schema 迁移..."
    
    # Determine database URL and network settings
    local db_url network_arg
    
    if [[ "${POSTGRES_TYPE}" == "builtin" ]]; then
        # Check if postgres service is running
        if ! $DOCKER_COMPOSE_CMD ps postgres | grep -q "Up"; then
            log_info "启动 PostgreSQL 服务进行迁移..."
            $DOCKER_COMPOSE_CMD up -d postgres
            
            # Wait for postgres to be ready
            local retry_count=0
            until $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U postgres; do
                sleep 2
                retry_count=$((retry_count + 1))
                if [ $retry_count -gt 30 ]; then
                    die_or_return "$EXIT_DB_CONNECT" "PostgreSQL 启动超时，迁移无法连接数据库" || return 1
                fi
            done
        fi

        # Get the actual compose network name
        local network_name
        network_name=$(get_compose_network)
        log_info "使用 Docker Compose 网络: $network_name"

        # Use internal database URL for builtin PostgreSQL
        db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/zfc?schema=public"
        network_arg="--network $network_name"
    else
        # Use external database URL
        db_url="postgresql://${EXTERNAL_POSTGRES_USER}:${EXTERNAL_POSTGRES_PASSWORD}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}?schema=public"
        network_arg=""

        # Validate external database connection
        if ! validate_postgres_connection "$EXTERNAL_POSTGRES_HOST" "$EXTERNAL_POSTGRES_PORT" "$EXTERNAL_POSTGRES_USER" "$EXTERNAL_POSTGRES_PASSWORD" "$EXTERNAL_POSTGRES_DB"; then
            die_or_return "$EXIT_DB_CONNECT" "外部数据库连接失败，无法执行迁移(检查 EXTERNAL_POSTGRES_* 凭据/可达性)" || return 1
        fi
    fi

    preflight_current_schema_state "$db_url" "$network_arg" || return 1
    
    log_info "执行 Prisma 数据库迁移..."
    log_info "使用数据库 URL: ${db_url%:*}:****@${db_url#*@}"
    
    # Create database backup before migration (for builtin PostgreSQL only)
    if [[ "${POSTGRES_TYPE}" == "builtin" ]]; then
        log_info "创建数据库备份..."
        local backup_file="schema_backup/db_backup_$(date +%Y%m%d_%H%M%S).sql"

        # 默认排除诊断/审计/统计表数据，只备份这些表的 schema；设置 ZFC_BACKUP_FULL=1 可做完整备份。
        # 这些表是纯可观测性时序数据(无外键依赖)，单表可达数十 GB(线上实测 LatencyDiagnosticRecord
        # 仅 5 天就 28GB)，排除其数据不影响迁移恢复(表结构仍被 dump，只跳过行数据)。
        # 注意: 排除对 image-bundle(版本化迁移)路径同样生效——之前该路径强制完整备份，会把诊断表
        # 整个 dump 进去导致备份膨胀到几十 GB。ZFC_BACKUP_FULL=1 仍可强制完整备份。
        # 使用数组传参，避免 sh -c "..." 中双引号嵌套导致 --exclude-table-data 失效
        local pg_dump_args=(-h postgres -U postgres -d zfc)
        if [[ "${ZFC_BACKUP_FULL:-0}" != "1" ]]; then
            pg_dump_args+=(
                '--exclude-table-data=public."LatencyDiagnosticRecord"'
                '--exclude-table-data=public."ServerStatusSnapshot"'
                '--exclude-table-data=public."AuditLog"'
                '--exclude-table-data=public."PeerStatistic"'
                '--exclude-table-data=public."ForwarderTask"'
            )
            log_info "备份将跳过诊断/审计/统计/任务队列表数据 (LatencyDiagnosticRecord/ServerStatusSnapshot/AuditLog/PeerStatistic/ForwarderTask)"
            log_info "如需完整备份，请设置 ZFC_BACKUP_FULL=1 后重新运行"
        else
            log_info "完整备份模式"
        fi

        # 后台运行 pg_dump 并定期打印进度 (文件大小)
        docker run --rm \
            $network_arg \
            -e PGPASSWORD="${POSTGRES_PASSWORD}" \
            postgres:15-alpine \
            pg_dump "${pg_dump_args[@]}" > "$backup_file" 2>/dev/null &
        local dump_pid=$!

        local elapsed=0
        local max_wait=600
        while kill -0 "$dump_pid" 2>/dev/null; do
            if [[ $elapsed -ge $max_wait ]]; then
                log_warning "数据库备份超过 ${max_wait}s，终止备份进程"
                kill "$dump_pid" 2>/dev/null
                wait "$dump_pid" 2>/dev/null
                break
            fi
            if [[ $elapsed -gt 0 && $((elapsed % 5)) -eq 0 ]]; then
                local cur_size="?"
                [[ -f "$backup_file" ]] && cur_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
                log_info "备份进行中... 已用 ${elapsed}s，当前大小: ${cur_size}"
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done

        wait "$dump_pid" 2>/dev/null
        local dump_rc=$?

        if [[ $dump_rc -eq 0 && -s "$backup_file" ]]; then
            local final_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
            log_success "数据库备份完成: $backup_file (${final_size}, 耗时 ${elapsed}s)"
        else
            # 删除残缺备份文件: pg_dump 失败(常见为磁盘满)会留下半成品, 不删则重试时继续占用磁盘
            if [[ -f "$backup_file" ]]; then
                local partial_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
                rm -f "$backup_file"
                log_warning "已删除残缺备份文件 $backup_file (${partial_size}); 备份失败常因磁盘空间不足,请清理 schema_backup/ 或检查 df -h"
            fi
            if [[ "$SCHEMA_SOURCE" == "image-bundle" ]]; then
                log_error "数据库完整备份失败，拒绝执行版本化 schema 迁移 (rc=$dump_rc)"
                return 1
            fi
            log_warning "legacy 数据库备份失败，但沿用历史行为继续迁移 (rc=$dump_rc, 耗时 ${elapsed}s)"
        fi
    else
        if [[ "$SCHEMA_SOURCE" == "image-bundle" && "${ZFC_EXTERNAL_DB_BACKUP_CONFIRMED:-0}" != "1" ]]; then
            if ! confirm "外部 PostgreSQL 无法自动备份。是否已完成可恢复的数据库备份？" "no"; then
                log_error "未确认外部数据库备份，拒绝执行版本化 schema 迁移"
                return 1
            fi
        fi
        log_info "外部数据库备份已由用户负责"
    fi
    
    # Use prisma migrate deploy for production deployments
    docker run --rm \
        $network_arg \
        -v "$(pwd)/prisma:/app/prisma" \
        -w /app \
        -e DATABASE_URL="$db_url" \
        "${ZFC_PRISMA_IMAGE}" \
        sh -c "
            echo '使用预装 Prisma CLI，跳过安装步骤...' &&
            echo '修改 schema 文件以支持 npx prisma...' &&
            sed 's/provider = \\\"cargo prisma\\\"/provider = \\\"prisma-client-js\\\"/' prisma/schema.prisma > prisma/schema.prisma.tmp && mv prisma/schema.prisma.tmp prisma/schema.prisma &&
            sed 's|output.*|// output removed for npx compatibility|' prisma/schema.prisma > prisma/schema.prisma.tmp && mv prisma/schema.prisma.tmp prisma/schema.prisma &&
            if [ -d prisma/migrate-hooks ]; then
              for hook in prisma/migrate-hooks/*.sql; do
                [ -f \"\$hook\" ] || continue
                echo \"执行预迁移 hook: \$hook\"
                npx prisma db execute --file \"\$hook\" --schema prisma/schema.prisma || exit 1
              done
            fi &&
            echo '创建迁移目录...' &&
            mkdir -p prisma/migrations/$(date +%Y%m%d_%H%M%S)_schema_update &&
            migration_dir=\"prisma/migrations/$(date +%Y%m%d_%H%M%S)_schema_update\" &&
            echo '生成数据库迁移差异...' &&
            npx prisma migrate diff --from-schema-datasource prisma/schema.prisma --to-schema-datamodel prisma/schema.prisma --script > \"\$migration_dir/migration.sql\" &&
            if [ -s \"\$migration_dir/migration.sql\" ]; then
                echo '发现数据库结构变更，需要应用迁移:' &&
                echo '--- 迁移内容 ---' &&
                cat \"\$migration_dir/migration.sql\" &&
                echo '--- 迁移内容结束 ---' &&
                echo '执行数据库迁移...' &&
                if npx prisma db execute --file \"\$migration_dir/migration.sql\" --schema prisma/schema.prisma; then
                    echo '数据库迁移执行成功'
                else
                    echo '数据库迁移执行失败' >&2
                    exit 1
                fi
            else
                echo '数据库结构无变化，无需迁移' &&
                rm -rf \"\$migration_dir\"
            fi &&
            echo '应用 schema 更改到数据库（跳过代码生成）...' &&
            npx prisma db push --schema=prisma/schema.prisma --accept-data-loss --skip-generate &&
            if [ -f prisma/.zfc_schema_state.sql ]; then
              npx prisma db execute --file prisma/.zfc_schema_state.sql --schema prisma/schema.prisma
            fi
        "
    
    if [[ $? -eq 0 ]]; then
        log_success "数据库 schema 迁移完成"
        return 0
    else
        log_error "数据库 schema 迁移失败"
        return 1
    fi
}

# Rollback schema changes function
rollback_schema_changes() {
    log_info "回滚 schema 变更..."
    
    # Find the most recent backup
    local latest_backup=$(ls -t schema_backup/schema.prisma.* 2>/dev/null | head -1)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log_info "恢复备份文件: $latest_backup"
        cp "$latest_backup" "prisma/schema.prisma"
        log_success "Schema 文件已回滚到之前版本"
    else
        log_warning "未找到备份文件，无法自动回滚"
        log_info "请手动检查 prisma/schema.prisma 文件"
    fi
    
    # Provide manual rollback instructions
    echo
    log_info "手动回滚说明："
    log_info "1. 检查 schema_backup/ 目录中的备份文件"
    log_info "2. 如果需要，手动恢复数据库到之前状态"
    log_info "3. 联系管理员获取进一步支持"
}

# Ensure production binary version strictness on upgrade (controller compose + .env).
ensure_strict_binary_version_config() {
    local env_val="${ZFC_STRICT_BINARY_VERSION:-1}"

    if [[ -f .env ]] && ! grep -qE '^[[:space:]]*ZFC_STRICT_BINARY_VERSION=' .env 2>/dev/null; then
        echo "ZFC_STRICT_BINARY_VERSION=$(quote_env_value "$env_val")" >> .env
        log_info "已添加 ZFC_STRICT_BINARY_VERSION=$env_val 到 .env"
        # shellcheck disable=SC1091
        source .env 2>/dev/null || true
    fi

    if [[ ! -f docker-compose.yml ]]; then
        return 0
    fi
    if grep -q "ZFC_STRICT_BINARY_VERSION" docker-compose.yml 2>/dev/null; then
        return 0
    fi
    if ! grep -A 30 "zf-controler:" docker-compose.yml | grep -q "environment:"; then
        log_warning "docker-compose.yml 中无 zf-controler environment，跳过 ZFC_STRICT_BINARY_VERSION 注入"
        return 0
    fi
    cp docker-compose.yml docker-compose.yml.strict_binary_version_backup 2>/dev/null || true
    sed_inplace docker-compose.yml '/^  zf-controler:/,/^  [a-zA-Z]/ {
            /environment:/a\
      ZFC_STRICT_BINARY_VERSION: ${ZFC_STRICT_BINARY_VERSION:-1}
        }'
    log_info "已向 docker-compose.yml zf-controler 注入 ZFC_STRICT_BINARY_VERSION"
}

# Update docker-compose.yml to include WEB_PRIV_KEY and WEB_PUBKEY if missing
update_docker_compose_web_keys() {
    log_info "检查 docker-compose.yml 中的 WEB 密钥配置..."
    
    # Check if docker-compose.yml exists
    if [[ ! -f "docker-compose.yml" ]]; then
        log_warning "docker-compose.yml 文件不存在，跳过 WEB 密钥配置检查"
        return 0
    fi
    
    # Check if WEB_PRIV_KEY and WEB_PUBKEY already exist
    local has_web_priv_key=$(grep -c "WEB_PRIV_KEY:" docker-compose.yml 2>/dev/null || echo "0")
    local has_web_pubkey=$(grep -c "WEB_PUBKEY:" docker-compose.yml 2>/dev/null || echo "0")
    
    # Clean any newlines and ensure variables are valid numbers
    has_web_priv_key=$(echo "$has_web_priv_key" | tr -d '\n\r' | grep -E '^[0-9]+$' || echo "0")
    has_web_pubkey=$(echo "$has_web_pubkey" | tr -d '\n\r' | grep -E '^[0-9]+$' || echo "0")
    
    # Debug output
    log_info "检测结果: WEB_PRIV_KEY计数=$has_web_priv_key, WEB_PUBKEY计数=$has_web_pubkey"
    
    if [[ "$has_web_priv_key" -gt 0 && "$has_web_pubkey" -gt 0 ]]; then
        log_info "WEB_PRIV_KEY 和 WEB_PUBKEY 已存在于 docker-compose.yml 中"
        return 0
    fi
    
    # Check if zf-web service exists and has environment section
    if ! grep -A 20 "zf-web:" docker-compose.yml | grep -q "environment:"; then
        log_warning "未找到 zf-web 服务的 environment 部分，跳过 WEB 密钥配置"
        return 1
    fi
    
    log_info "在 docker-compose.yml 中添加缺失的 WEB 密钥配置..."
    
    # Create backup
    cp docker-compose.yml docker-compose.yml.web_keys_backup
    
    # Add missing keys directly after environment: line in zf-web service
    if [[ "$has_web_priv_key" -eq 0 ]]; then
        sed_inplace docker-compose.yml '/^  zf-web:/,/^  [a-zA-Z]/ {
            /environment:/a\
      WEB_PRIV_KEY: ${WEB_PRIV_KEY}
        }'
        log_info "已添加 WEB_PRIV_KEY 配置"
    fi
    
    if [[ "$has_web_pubkey" -eq 0 ]]; then
        sed_inplace docker-compose.yml '/^  zf-web:/,/^  [a-zA-Z]/ {
            /environment:/a\
      WEB_PUBKEY: ${WEB_PUBKEY}
        }'
        log_info "已添加 WEB_PUBKEY 配置"
    fi
    
    log_success "docker-compose.yml 中的 WEB 密钥配置更新完成"
    log_info "备份文件: docker-compose.yml.web_keys_backup"
}

# 清理 schema_backup/ 下的历史备份,避免长期累积占满磁盘。
# 策略(优先级从高到低):
#   1. 下限保护: 始终保留最近 keep_count 份(无视年龄), 防止误删刚生成的近期备份。
#   2. 硬上限(max_count>0): 超过 max_count 份的旧备份无视年龄直接删, 真正封顶磁盘占用。
#   3. 软清理: 介于两者之间的, 仅当 mtime 超过 keep_days 天才删(keep_days=0 表示纯按数量删)。
# 通过 ZFC_BACKUP_AUTOCLEAN=0 关闭; RETAIN_COUNT / RETAIN_DAYS / MAX_COUNT 调参。
# 0 值表示不按该维度限制(RETAIN_DAYS=0 → 软清理纯按数量; MAX_COUNT=0 → 无硬上限; 都不限 → 不清理)。
# 注意: RETAIN_COUNT 是「下限」不是「上限」——30 天内攒的备份软清理删不掉, 要封顶请设 MAX_COUNT。
cleanup_old_backups() {
    [[ "${ZFC_BACKUP_AUTOCLEAN:-1}" == "1" ]] || return 0

    local backup_dir="schema_backup"
    [[ -d "$backup_dir" ]] || return 0

    local keep_count="${ZFC_BACKUP_RETAIN_COUNT:-5}"
    local keep_days="${ZFC_BACKUP_RETAIN_DAYS:-30}"
    local max_count="${ZFC_BACKUP_MAX_COUNT:-0}"
    # 非法值回退默认
    [[ "$keep_count" =~ ^[0-9]+$ ]] || keep_count=5
    [[ "$keep_days"  =~ ^[0-9]+$ ]] || keep_days=30
    [[ "$max_count"  =~ ^[0-9]+$ ]] || max_count=0
    # 硬上限不能低于下限, 否则下限会让备份突破硬上限; 以硬上限为准并提示
    if [[ "$max_count" -gt 0 && "$max_count" -lt "$keep_count" ]]; then
        log_warning "ZFC_BACKUP_MAX_COUNT($max_count) 小于 RETAIN_COUNT($keep_count), 以硬上限为准"
        keep_count="$max_count"
    fi
    # 三个维度都不限制等于不清理
    [[ "$keep_count" -gt 0 || "$keep_days" -gt 0 || "$max_count" -gt 0 ]] || return 0

    if [[ "$max_count" -gt 0 ]]; then
        log_info "清理历史备份 (保留最近 ${keep_count} 份; 超出且超过 ${keep_days} 天的删除; 硬上限 ${max_count} 份)..."
    else
        log_info "清理历史备份 (始终保留最近 ${keep_count} 份; 超出且超过 ${keep_days} 天的删除)..."
    fi

    local now
    now=$(date +%s)

    local total_removed=0
    local pattern f idx mtime age removed
    for pattern in "schema.prisma.*" "db_backup_*.sql"; do
        local -a files=()
        while IFS= read -r f; do
            [[ -n "$f" ]] && files+=("$f")
        done < <(ls -t "$backup_dir"/$pattern 2>/dev/null)

        idx=0
        removed=0
        for f in "${files[@]}"; do
            idx=$((idx + 1))
            # 1) 下限窗口内 → 保留(无视年龄)
            [[ "$keep_count" -gt 0 && "$idx" -le "$keep_count" ]] && continue
            # 2) 超过硬上限 → 无视年龄直接删
            if [[ "$max_count" -gt 0 && "$idx" -gt "$max_count" ]]; then
                rm -f "$f" && removed=$((removed + 1))
                continue
            fi
            # 3) 软清理: 看年龄; keep_days=0 表示不按天数限制(纯数量)
            if [[ "$keep_days" -gt 0 ]]; then
                # Linux: stat -c %Y; macOS/BSD: stat -f %m; 取不到 mtime 则保守保留(fail-safe)
                mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
                [[ "$mtime" =~ ^[0-9]+$ ]] || continue
                age=$(( (now - mtime) / 86400 ))
                [[ "$age" -ge "$keep_days" ]] || continue
            fi
            rm -f "$f" && removed=$((removed + 1))
        done
        total_removed=$((total_removed + removed))
    done

    if [[ $total_removed -gt 0 ]]; then
        log_success "已清理 $total_removed 份过期备份 (schema_backup/)"
    else
        log_info "没有过期备份需要清理"
    fi
}

# 升级前磁盘空间预检 (仅 builtin PostgreSQL)。
# 目的: 在停止应用服务之前就拦住磁盘不足的升级——否则 pg_dump 会写出半成品填满磁盘,
# 既让备份失败拒绝迁移,又会把 PostgreSQL 顶进 checkpoint "No space left" 崩溃环导致全站不可用。
# 先清理历史备份腾出空间,再按「待备份数据量 × 1.3 + 256MB 余量」核对剩余磁盘。
# ZFC_SKIP_DISK_PRECHECK=1 可跳过(不建议)。测不出大小时 fail-open(仅告警),由后续备份步骤兜底。
preflight_backup_disk_space() {
    [[ "${ZFC_SKIP_DISK_PRECHECK:-0}" == "1" ]] && { log_warning "已跳过升级前磁盘空间预检 (ZFC_SKIP_DISK_PRECHECK=1)"; return 0; }
    [[ "${POSTGRES_TYPE}" == "builtin" ]] || return 0

    # 先清理历史备份(成功路径之外也清),把最缺空间的时刻先腾出来
    mkdir -p schema_backup
    cleanup_old_backups

    local psql_q=($DOCKER_COMPOSE_CMD exec -T postgres psql -U postgres -d zfc -tAc)
    local db_bytes excl_bytes=0 estimate
    db_bytes=$("${psql_q[@]}" "SELECT pg_database_size('zfc')" 2>/dev/null | tr -dc '0-9')
    if [[ ! "$db_bytes" =~ ^[0-9]+$ ]]; then
        log_warning "无法读取数据库大小,跳过磁盘预检(备份步骤仍会做安全兜底)"
        return 0
    fi
    if [[ "${ZFC_BACKUP_FULL:-0}" != "1" ]]; then
        excl_bytes=$("${psql_q[@]}" "SELECT COALESCE(SUM(pg_total_relation_size(c.oid)),0) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN ('LatencyDiagnosticRecord','ServerStatusSnapshot','AuditLog','PeerStatistic','ForwarderTask')" 2>/dev/null | tr -dc '0-9')
        [[ "$excl_bytes" =~ ^[0-9]+$ ]] || excl_bytes=0
    fi
    estimate=$(( db_bytes - excl_bytes ))
    [[ "$estimate" -lt 0 ]] && estimate=0
    # 文本 dump 体积浮动,留 30% + 256MB 余量
    local required=$(( estimate * 13 / 10 + 268435456 ))

    # schema_backup 所在分区可用字节
    local avail_kb avail_bytes
    avail_kb=$(df -Pk schema_backup 2>/dev/null | awk 'NR==2{print $4}')
    if [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
        log_warning "无法读取磁盘可用空间,跳过磁盘预检"
        return 0
    fi
    avail_bytes=$(( avail_kb * 1024 ))

    local req_mb=$(( required / 1048576 )) avail_mb=$(( avail_bytes / 1048576 ))
    if [[ "$avail_bytes" -lt "$required" ]]; then
        log_error "磁盘空间不足,拒绝开始升级(应用服务尚未停止,当前部署不受影响)"
        log_error "  预计备份需要 ~${req_mb}MB,但 schema_backup/ 所在分区仅剩 ${avail_mb}MB"
        log_error "  请先腾出空间后重试,可选措施:"
        log_error "    1) 删除旧备份:    rm -f schema_backup/db_backup_*.sql (保留最近一份)"
        log_error "    2) 回收 Docker:   docker image prune -a -f"
        log_error "    3) 清理任务队列:  ForwarderTask 等瞬时表可在控制台/DB 清理(已默认排除其数据)"
        log_error "  确认空间充足后,亦可设 ZFC_SKIP_DISK_PRECHECK=1 跳过本预检"
        return 1
    fi
    log_info "磁盘预检通过: 预计需 ~${req_mb}MB, 可用 ${avail_mb}MB"
    return 0
}

# Cleanup old Docker images function
cleanup_old_images() {
    log_info "检查可清理的旧镜像..."

    # 确保已加载环境变量
    if [[ ! -f ".env" ]]; then
        log_warning "未找到 .env 文件，跳过镜像清理"
        return 0
    fi

    source .env

    # 获取当前使用的镜像列表
    local current_images=(
        "${ZF_WEB_IMAGE}"
        "${ZF_CONTROLER_IMAGE}"
        "${RRD_SERVICE_IMAGE}"
        "${ZFC_UTIL_IMAGE}"
        "${ZFC_ADMIN_IMAGE}"
        "${ZFC_PRISMA_IMAGE}"
    )

    # 获取 Docker registry 前缀（用于匹配所有 ZFC 镜像）
    local registry="${DOCKER_REGISTRY:-hub.covm.net}"

    # 列出所有 ZFC 相关镜像
    log_info "扫描 ${registry} 的镜像..."
    local all_zfc_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${registry}/" | sort -u)

    if [[ -z "$all_zfc_images" ]]; then
        log_info "未找到可清理的镜像"
        return 0
    fi

    # 构建需要保留的镜像列表（转换为正则表达式模式）
    local keep_pattern=""
    for img in "${current_images[@]}"; do
        if [[ -n "$img" ]]; then
            # 转义特殊字符
            local escaped_img=$(echo "$img" | sed 's/[.[\*^$()+?{|]/\\&/g')
            if [[ -z "$keep_pattern" ]]; then
                keep_pattern="^${escaped_img}$"
            else
                keep_pattern="${keep_pattern}|^${escaped_img}$"
            fi
        fi
    done

    # 筛选出可删除的镜像
    local images_to_remove=()
    while IFS= read -r image; do
        # 跳过当前使用的镜像
        if echo "$image" | grep -qE "$keep_pattern"; then
            log_info "保留当前版本: $image"
            continue
        fi

        # 添加到待删除列表
        images_to_remove+=("$image")
    done <<< "$all_zfc_images"

    # 如果没有可删除的镜像
    if [[ ${#images_to_remove[@]} -eq 0 ]]; then
        log_success "没有需要清理的旧镜像"
        return 0
    fi

    # 显示可删除的镜像列表
    echo
    log_info "发现 ${#images_to_remove[@]} 个旧版本镜像："
    for img in "${images_to_remove[@]}"; do
        # 获取镜像大小
        local img_size=$(docker images --format "{{.Size}}" "$img" 2>/dev/null || echo "unknown")
        echo "  - $img (大小: $img_size)"
    done
    echo

    # 询问用户是否清理(非交互: 默认按 ZFC_ASSUME_YES)
    if confirm "是否清理这些旧镜像？" "$(assume_default)"; then
        log_info "开始清理旧镜像..."
    else
        log_info "跳过镜像清理"
        return 0
    fi

    # 删除旧镜像
    local removed_count=0
    local failed_count=0

    for img in "${images_to_remove[@]}"; do
        log_info "删除镜像: $img"
        if docker rmi "$img" >/dev/null 2>&1; then
            ((++removed_count))
            log_success "✓ 已删除: $img"
        else
            ((++failed_count))
            log_warning "✗ 删除失败: $img (可能被其他容器使用)"
        fi
    done

    # 额外清理悬空镜像（dangling images）
    log_info "清理悬空镜像..."
    local dangling_removed=$(docker image prune -f 2>&1 | grep "Total reclaimed space" || echo "")
    if [[ -n "$dangling_removed" ]]; then
        log_info "$dangling_removed"
    fi

    # 显示清理结果
    echo
    if [[ $removed_count -gt 0 ]]; then
        log_success "成功清理 $removed_count 个旧镜像"
    fi

    if [[ $failed_count -gt 0 ]]; then
        log_warning "$failed_count 个镜像清理失败（不影响系统运行）"
    fi

    if [[ $removed_count -eq 0 && $failed_count -eq 0 ]]; then
        log_info "没有镜像被清理"
    fi

    return 0
}

# Update images function
update_images() {
    log_info "更新镜像（保留数据）..."
    
    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi
    
    # Check if .env file exists
    if [[ ! -f ".env" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "系统未安装(未找到 .env 文件); 请先执行全新安装 (--install)" || return 1
    fi
    
    # Source environment file to get database configuration
    source .env
    
    # Backward compatibility check for WEB_PRIV_KEY and WEB_PUBKEY
    if [[ -z "${WEB_PRIV_KEY:-}" || -z "${WEB_PUBKEY:-}" ]]; then
        log_info "检测到缺失的 WEB 密钥配置，执行向后兼容性更新..."
        
        # Generate new web key pair using zfc-util
        log_info "生成 WEB 密钥对..."
        
        # Ensure zfc-util image is available
        if [[ -n "${ZFC_UTIL_IMAGE:-}" ]]; then
            docker pull "$ZFC_UTIL_IMAGE" >/dev/null || {
                die_or_return "$EXIT_IMAGE_PULL" "无法拉取 ZFC-Util 镜像: $ZFC_UTIL_IMAGE (检查 DOCKER_REGISTRY/网络/凭据)" || return 1
            }
            local web_key_output
            web_key_output=$(docker run --rm "${ZFC_UTIL_IMAGE}" generate-key)
            
            local new_web_priv_key new_web_pubkey
            new_web_priv_key=$(echo "$web_key_output" | grep "private_key:" | awk '{print $2}')
            new_web_pubkey=$(echo "$web_key_output" | grep "public_key:" | awk '{print $2}')
            
            if [[ -n "$new_web_priv_key" && -n "$new_web_pubkey" ]]; then
                # Append new keys to .env file
                if [[ -z "${WEB_PRIV_KEY:-}" ]]; then
                    echo "WEB_PRIV_KEY=$(quote_env_value "$new_web_priv_key")" >> .env
                    log_info "已添加 WEB_PRIV_KEY 到 .env 文件"
                fi
                
                if [[ -z "${WEB_PUBKEY:-}" ]]; then
                    echo "WEB_PUBKEY=$(quote_env_value "$new_web_pubkey")" >> .env
                    log_info "已添加 WEB_PUBKEY 到 .env 文件"
                fi
                
                # Re-source .env file to load new variables
                source .env
                log_success "WEB 密钥配置向后兼容性更新完成"
            else
                die_or_return "$EXIT_DEP_UNAVAILABLE" "生成 WEB 密钥对失败(zfc-util 未产出有效密钥)" || return 1
            fi
        else
            die_or_return "$EXIT_MISSING_INPUT" "ZFC_UTIL_IMAGE 未配置，无法生成 WEB 密钥对" || return 1
        fi
    else
        log_info "WEB 密钥配置完整，跳过向后兼容性检查"
    fi

    ensure_strict_binary_version_config

    # Backward compatibility and enforcement check for ZFC_PRISMA_IMAGE
    # We insist on using latest tag for zfc-prisma because it only has latest tag
    if [[ -z "${ZFC_PRISMA_IMAGE:-}" ]] || [[ "${ZFC_PRISMA_IMAGE}" != *":latest" ]]; then
        log_info "检测到 ZFC_PRISMA_IMAGE 配置缺失或未使用 latest 标签，执行自动修正..."
        
        # Get Docker registry from existing images
        local docker_registry
        if [[ -n "${ZFC_UTIL_IMAGE:-}" ]]; then
            docker_registry=$(echo "${ZFC_UTIL_IMAGE}" | cut -d'/' -f1)
            
            local new_prisma_image="${docker_registry}/zfc-prisma:latest"
            
            # Remove existing line if present to avoid duplicates
            if grep -q "^ZFC_PRISMA_IMAGE=" .env; then
                sed_inplace .env '/^ZFC_PRISMA_IMAGE=/d'
            fi
            
            echo "ZFC_PRISMA_IMAGE=$(quote_env_value "$new_prisma_image")" >> .env
            log_info "已更新 ZFC_PRISMA_IMAGE 到 .env 文件: $new_prisma_image"
            
            # Re-source .env file to load new variables
            source .env
            log_success "ZFC_PRISMA_IMAGE 配置修正完成"
        else
            log_warning "无法确定镜像仓库地址，请手动配置 ZFC_PRISMA_IMAGE"
        fi
    else
        log_info "ZFC_PRISMA_IMAGE 配置正确，无需修正"
    fi

    if ! docker pull "$ZFC_PRISMA_IMAGE" >/dev/null; then
        die_or_return "$EXIT_IMAGE_PULL" "无法拉取 Prisma 工具镜像: $ZFC_PRISMA_IMAGE (检查 DOCKER_REGISTRY/网络/凭据)" || return 1
    fi
    
    # Check and update docker-compose.yml for WEB keys
    update_docker_compose_web_keys
    
    # Check if docker-compose.yml exists
    if [[ ! -f "docker-compose.yml" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "未找到 docker-compose.yml 文件(系统未安装?); 请先 --install" || return 1
    fi
    
    log_info "当前数据库配置: PostgreSQL=${POSTGRES_TYPE}, Redis=${REDIS_TYPE}, TDengine=${TDENGINE_TYPE}"

    # ── 目标版本解析 ────────────────────────────────────────────────────────
    # 交互: 菜单选 latest / .env 版本 / 手动输入(见 select_update_target_version)。
    # 非交互: 沿用 ZFC_UPDATE_CHANNEL(缺省 latest) + 可选 ZFC_UPDATE_TO/--to。
    # --to / 手动输入覆盖 channel 解析目标, 但**不写回** channel: 一次性动作 vs 长期意图。
    local update_channel update_explicit
    local version_before
    version_before=$(image_ref_tag "${ZF_WEB_IMAGE:-}")
    if ! select_update_target_version update_channel update_explicit; then
        return 1
    fi
    if ! resolve_deploy_version "$update_channel" "$update_explicit"; then
        return 1
    fi
    if [[ -n "${ZFC_RESOLVED_VERSION:-}" ]]; then
        if [[ "$version_before" == "$ZFC_RESOLVED_VERSION" ]]; then
            # 不 no-op 返回: 上次升级可能停在半途(镜像已换、schema 没迁完), 重跑必须幂等。
            log_info "目标版本 ${ZFC_RESOLVED_VERSION} 与当前一致, 继续执行(重跑幂等)"
        else
            log_info "版本变更: ${version_before:-unknown} → ${ZFC_RESOLVED_VERSION}"
        fi
    fi

    # Build list of services to update (only services that exist in compose file)
    local services_to_update=()
    local potential_services=("zf-web" "zf-controler" "rrd-service" "zfc-util" "zfc-admin" "caddy")
    
    # Check which services actually exist in the compose file
    for service in "${potential_services[@]}"; do
        if grep -q "^  $service:" docker-compose.yml; then
            services_to_update+=("$service")
            log_info "发现服务: $service"
        fi
    done
    
    if [[ ${#services_to_update[@]} -eq 0 ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "未找到可更新的应用服务(docker-compose.yml 中无已知服务)" || return 1
    fi
    
    log_info "将更新以下服务: ${services_to_update[*]}"

    # Work out stop/start groups before mutating any deployment state.
    local caddy_in_update=false
    local other_services=()
    
    for service in "${services_to_update[@]}"; do
        if [[ "$service" == "caddy" ]]; then
            caddy_in_update=true
        else
            other_services+=("$service")
        fi
    done

    # Pull first while the old containers keep serving traffic. Schema extraction
    # must use the exact images that are about to be deployed.
    log_info "预拉取目标应用镜像..."
    for service in "${services_to_update[@]}"; do
        if [[ "$service" == "caddy" ]]; then
            $DOCKER_COMPOSE_CMD --profile caddy pull caddy \
                || { die_or_return "$EXIT_IMAGE_PULL" "拉取镜像失败: caddy (检查 DOCKER_REGISTRY/网络/凭据)" || return 1; }
        else
            $DOCKER_COMPOSE_CMD pull "$service" \
                || { die_or_return "$EXIT_IMAGE_PULL" "拉取镜像失败: $service (检查 DOCKER_REGISTRY/网络/凭据)" || return 1; }
        fi
    done

    # zfc-admin / zfc-util 是一次性工具镜像，多数 compose 模板不会声明为服务，
    # 因此上面的 compose pull 永远刷不到它们。本地残留旧 admin 会在「查看/刷新
    # 管理员 Token」时被 schema 指纹门禁拦下（与刚迁完的 DB 不一致 → 防 P2022）。
    # 这里按 .env 引用强制 docker pull，与 web/controler 同次升级对齐。
    pull_utility_tool_images || return 1

    # 在停止应用服务之前做磁盘空间预检: 不足则趁服务仍在运行时干净中止,避免半成品备份填满磁盘拖垮 DB
    if ! preflight_backup_disk_space; then
        die_or_return "$EXIT_SCHEMA_MIGRATION" "升级前磁盘空间预检失败,已中止(应用服务保持运行,当前部署不受影响)" || return 1
    fi

    log_info "目标镜像拉取完成，停止应用服务后执行数据库迁移..."
    # Stop regular services
    if [[ ${#other_services[@]} -gt 0 ]]; then
        $DOCKER_COMPOSE_CMD stop "${other_services[@]}"
    fi
    
    # Stop Caddy with profile if needed
    if [[ "$caddy_in_update" == "true" ]]; then
        log_info "停止 Caddy 服务..."
        $DOCKER_COMPOSE_CMD --profile caddy stop caddy
    fi

    UPDATE_SCHEMA="true"
    if ! update_schema; then
        log_error "数据库 schema 更新失败；为避免不匹配，应用服务保持停止"
        ZFC_HINT="从最近 schema_backup/db_backup_*.sql 恢复后重跑 --update; 或 --doctor 看 schema.delta_class/db_status"
        die_or_return "$EXIT_SCHEMA_MIGRATION" "数据库 schema 更新失败；请根据 schema_backup 中的数据库备份恢复后重试，不会继续启动新镜像" || return 1
    fi
    log_success "数据库 schema 更新完成"

    if ! verify_target_image_ids; then
        die_or_return "$EXIT_SCHEMA_MIGRATION" "迁移期间目标镜像 tag 发生变化，拒绝启动未验证镜像；请重跑 --update" || return 1
    fi

    # schema 已迁完且镜像已验证 —— 此刻才把钉版本落盘。在此之前任何中断,
    # 磁盘上的 .env 都还是旧版本, 与库的实际 schema 自洽(不存在配置超前于库的中间态)。
    if ! commit_pinned_env "$update_channel"; then
        # 此刻 DB 账本可能已是新 release 而 .env 仍是旧 tag —— 直接 compose up 会拿
        # 旧镜像配新账本, 被启动门禁拦下。必须重跑 --update(幂等)而不是手工起服务。
        log_error "注意: 数据库 schema 已迁移完成, 但 .env 未能更新。"
        log_error "请**不要**直接 docker compose up -d(旧镜像配新账本会被启动门禁拒绝)。"
        log_error "修好磁盘/权限后重跑 --update 即可(该动作幂等)。"
        ZFC_HINT="禁止直接 compose up; 修复磁盘/权限后重跑 --update"
        die_or_return "$EXIT_SCHEMA_MIGRATION" ".env 钉版本写入失败(schema 已迁移完成)" || return 1
    fi

    log_info "重新启动应用服务..."
    
    # Start services that were actually updated
    local services_to_start=()
    local caddy_needs_start=false
    
    for service in "${services_to_update[@]}"; do
        # Only start services that should be running (exclude utility services)
        case "$service" in
            "zfc-util"|"zfc-admin")
                # These are utility services, don't restart them
                log_info "跳过工具服务: $service"
                ;;
            "caddy")
                # Caddy needs special handling with profile
                caddy_needs_start=true
                log_info "检测到 Caddy 服务需要重启"
                ;;
            *)
                services_to_start+=("$service")
                ;;
        esac
    done
    
    # Start regular services
    if [[ ${#services_to_start[@]} -gt 0 ]]; then
        log_info "启动服务: ${services_to_start[*]}"
        $DOCKER_COMPOSE_CMD up -d "${services_to_start[@]}"
    fi
    
    # Start Caddy with profile if needed
    if [[ "$caddy_needs_start" == "true" ]]; then
        log_info "启动 Caddy 反向代理服务..."
        $DOCKER_COMPOSE_CMD --profile caddy up -d caddy
    fi
    
    if [[ ${#services_to_start[@]} -eq 0 && "$caddy_needs_start" == "false" ]]; then
        log_info "没有需要启动的服务"
    fi

    if [[ ${#services_to_start[@]} -gt 0 ]]; then
        log_info "等待新版本服务通过启动门禁..."
        if ! wait_for_compose_services 60 "${services_to_start[@]}"; then
            log_error "新版本服务未能在 60 秒内保持运行，保留旧镜像与数据库备份以便恢复"
            $DOCKER_COMPOSE_CMD ps || true
            ZFC_HINT="跑 --doctor 读失败容器日志(常见: schema 指纹不匹配 → 见 db_status/delta_class)"
            die_or_return "$EXIT_UPDATE_HEALTH" "更新后新版本服务未能在 60 秒内保持运行(启动门禁失败)" || return 1
        fi
    fi
    
    log_success "应用镜像更新完成！"
    log_info "数据库服务保持不变，数据完整保留"

    # 清理旧版本镜像
    echo
    cleanup_old_images

    # 清理过期的 schema/数据库备份(默认保留最近 5 份, 超出且超过 30 天的删除)
    if [[ "$UPDATE_SCHEMA" == "true" ]]; then
        echo
        cleanup_old_backups
    fi

    # Show update summary
    echo
    log_success "=== 更新完成总结 ==="
    if [[ "$UPDATE_SCHEMA" == "true" ]]; then
        log_info "✓ 数据库 schema 已检查并更新"
        log_info "✓ Schema 备份保存在 schema_backup/ 目录"
    else
        log_info "- 数据库 schema 更新已跳过"
    fi
    log_info "✓ 应用镜像已更新到最新版本"
    log_info "✓ 所有服务已重新启动"
    echo
    log_info "建议操作："
    log_info "1. 检查服务状态: ${DOCKER_COMPOSE_CMD} ps"
    log_info "2. 查看服务日志: ${DOCKER_COMPOSE_CMD} logs -f [service_name]"
    log_info "3. 测试应用功能确保更新成功"
    log_info "4. 如需手动清理镜像: docker image prune -a"
}

# Uninstall system function
uninstall_system() {
    log_info "卸载 ZFC 系统..."

    # 非交互: 卸载方式必须显式提供, 在做任何更改前先校验(fail-fast)。
    if [[ "$ZFC_NONINTERACTIVE" == "1" && ! "$ZFC_UNINSTALL_MODE" =~ ^[123]$ ]]; then
        die "$EXIT_MISSING_INPUT" "非交互卸载需显式 ZFC_UNINSTALL_MODE=1|2|3 (1=仅停服务保数据, 2=删内置库数据保外部库, 3=完全卸载)"
    fi

    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi
    
    # Check if system is installed
    local has_env=false
    local has_compose=false
    
    if [[ -f ".env" ]]; then
        has_env=true
        source .env
        log_info "检测到数据库配置: PostgreSQL=${POSTGRES_TYPE}, Redis=${REDIS_TYPE}, TDengine=${TDENGINE_TYPE}"
    fi
    
    if [[ -f "docker-compose.yml" ]]; then
        has_compose=true
    fi
    
    if [[ "$has_compose" == "false" && "$has_env" == "false" ]]; then
        log_warning "未找到安装文件，可能系统未安装"
        return 0
    fi
    
    if [[ "$has_compose" == "true" ]]; then
        log_info "停止所有容器化服务..."
        $DOCKER_COMPOSE_CMD down
    fi
    
    echo
    echo "卸载选项："
    echo "1. 仅停止服务，保留所有数据"
    echo "2. 删除内置数据库数据，保留外部数据库"
    echo "3. 完全卸载，删除所有配置和数据"
    
    while true; do
        if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
            uninstall_choice="$ZFC_UNINSTALL_MODE"
            [[ "$uninstall_choice" =~ ^[123]$ ]] || die "$EXIT_MISSING_INPUT" "非交互卸载需显式 ZFC_UNINSTALL_MODE=1|2|3 (1=仅停服务保数据, 2=删内置库数据保外部库, 3=完全卸载)"
        else
            read -p "请选择卸载方式 [1-3]: " uninstall_choice
        fi
        case $uninstall_choice in
            1)
                log_info "仅停止服务，保留所有数据"
                log_success "系统卸载完成（所有数据已保留）"
                break
                ;;
            2)
                log_info "删除内置数据库数据..."
                if [[ "$has_compose" == "true" ]]; then
                    $DOCKER_COMPOSE_CMD down -v
                fi
                
                # Clean up volumes for builtin databases only
                local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
                
                if [[ "${POSTGRES_TYPE:-builtin}" == "builtin" ]]; then
                    log_info "清理 PostgreSQL 数据卷..."
                    docker volume ls -q --filter "name=${project_name}_postgres" | xargs -r docker volume rm 2>/dev/null || true
                fi
                
                if [[ "${REDIS_TYPE:-builtin}" == "builtin" ]]; then
                    log_info "清理 Redis 数据卷..."
                    docker volume ls -q --filter "name=${project_name}_redis" | xargs -r docker volume rm 2>/dev/null || true
                fi
                
                if [[ "${TDENGINE_TYPE:-builtin}" == "builtin" ]]; then
                    log_info "清理 TDengine 数据卷..."
                    docker volume ls -q --filter "name=${project_name}_tdengine" | xargs -r docker volume rm 2>/dev/null || true
                fi
                
                if [[ "${CADDY_ENABLED:-false}" == "true" ]]; then
                    log_info "清理 Caddy 数据卷..."
                    docker volume ls -q --filter "name=${project_name}_caddy" | xargs -r docker volume rm 2>/dev/null || true
                fi
                
                log_success "内置数据库数据已清理，外部数据库保持不变"
                break
                ;;
            3)
                log_info "完全卸载系统..."
                if [[ "$has_compose" == "true" ]]; then
                    $DOCKER_COMPOSE_CMD down -v
                fi
                
                # Clean up all volumes
                local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
                docker volume ls -q --filter "name=${project_name}_" | xargs -r docker volume rm 2>/dev/null || true
                
                log_info "清理配置文件..."
                rm -f .env .admin_token docker-compose.yml docker-compose.yml.backup docker-compose.full.yml .docker_log_config Caddyfile

                # Only delete docker-compose.override.yml if it carries our marker.
                # A user-authored override may contain unrelated customizations we
                # must not silently remove even during "complete uninstall".
                if [[ -f "docker-compose.override.yml" ]]; then
                    if [[ "$(head -n 1 docker-compose.override.yml 2>/dev/null)" == "# ZFC_MANAGED_LOG_CLEANUP: true" ]]; then
                        rm -f docker-compose.override.yml docker-compose.override.yml.backup.*
                        log_info "已删除脚本生成的 docker-compose.override.yml"
                    else
                        log_warning "保留 docker-compose.override.yml（非脚本生成，可能包含您的自定义配置）"
                    fi
                fi

                rm -rf prisma
                
                log_success "系统完全卸载完成"
                break
                ;;
            *)
                log_error "无效选择，请输入 1-3"
                ;;
        esac
    done
}

# Pack migration data function
pack_migration_data() {
    log_info "一键打包迁移文件..."
    
    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi
    
    # Check if system is installed
    if [[ ! -f ".env" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "系统未安装(未找到 .env 文件); 请先执行全新安装 (--install)" || return 1
    fi
    
    # Source environment variables
    source .env
    
    # Check if using builtin PostgreSQL
    if [[ "${POSTGRES_TYPE:-builtin}" != "builtin" ]]; then
        log_error "仅支持内置 PostgreSQL 数据库的迁移"
        log_error "当前配置: POSTGRES_TYPE=${POSTGRES_TYPE:-external}"
        return 1
    fi
    
    # Check if PostgreSQL service is running
    if ! $DOCKER_COMPOSE_CMD ps postgres | grep -q "Up"; then
        log_error "PostgreSQL 服务未运行，请先启动系统"
        log_info "提示：运行 '$DOCKER_COMPOSE_CMD up -d' 启动服务"
        return 1
    fi
    
    # Check PostgreSQL connectivity
    if ! $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
        log_error "PostgreSQL 数据库未就绪"
        return 1
    fi
    
    # Create migration directory
    local migration_timestamp=$(date +%Y%m%d_%H%M%S)
    local migration_dir="zfc_migration_${migration_timestamp}"
    local migration_archive="${migration_dir}.tar.gz"
    
    log_info "创建迁移目录: $migration_dir"
    mkdir -p "$migration_dir"
    
    # Backup configuration files
    log_info "备份配置文件..."
    
    # Essential files
    cp .env "$migration_dir/" || {
        log_error "无法复制 .env 文件"
        rm -rf "$migration_dir"
        return 1
    }
    
    if [[ -f "docker-compose.yml" ]]; then
        cp docker-compose.yml "$migration_dir/"
        log_info "✓ docker-compose.yml"
    else
        log_warning "未找到 docker-compose.yml 文件"
    fi
    
    # Optional files
    if [[ -f "Caddyfile" ]]; then
        cp Caddyfile "$migration_dir/"
        log_info "✓ Caddyfile"
    fi
    
    if [[ -f ".admin_token" ]]; then
        cp .admin_token "$migration_dir/"
        log_info "✓ .admin_token"
    fi
    
    if [[ -d "prisma" ]]; then
        cp -r prisma "$migration_dir/"
        log_info "✓ prisma/ 目录"
    fi
    
    # Export PostgreSQL database
    log_info "导出 PostgreSQL 数据库..."
    local db_dump_file="$migration_dir/postgres_dump.sql"

    # 默认排除诊断/审计/统计表数据 (observability only, 无外键依赖); ZFC_BACKUP_FULL=1 强制完整导出
    # 使用数组传参，避免 sh -c "..." 吃掉 CamelCase 表名所需的双引号。
    local pg_dump_extra_args=()
    if [[ "${ZFC_BACKUP_FULL:-0}" != "1" ]]; then
        pg_dump_extra_args+=(
            '--exclude-table-data=public."LatencyDiagnosticRecord"'
            '--exclude-table-data=public."ServerStatusSnapshot"'
            '--exclude-table-data=public."AuditLog"'
            '--exclude-table-data=public."PeerStatistic"'
            '--exclude-table-data=public."ForwarderTask"'
        )
        log_info "导出将跳过诊断/审计/统计/任务队列表数据 (LatencyDiagnosticRecord/ServerStatusSnapshot/AuditLog/PeerStatistic/ForwarderTask)"
        log_info "如需完整导出，请设置 ZFC_BACKUP_FULL=1 后重新运行"
    else
        log_info "完整导出模式 (ZFC_BACKUP_FULL=1)"
    fi

    # 后台运行 pg_dump 并定期打印进度 (文件大小 + 耗时)
    $DOCKER_COMPOSE_CMD exec -T postgres pg_dump -U postgres -d zfc "${pg_dump_extra_args[@]}" > "$db_dump_file" 2>/dev/null &
    local dump_pid=$!

    local elapsed=0
    while kill -0 "$dump_pid" 2>/dev/null; do
        if [[ $elapsed -gt 0 && $((elapsed % 5)) -eq 0 ]]; then
            local cur_size="?"
            [[ -f "$db_dump_file" ]] && cur_size=$(du -h "$db_dump_file" 2>/dev/null | cut -f1)
            log_info "导出进行中... 已用 ${elapsed}s，当前大小: ${cur_size}"
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$dump_pid" 2>/dev/null
    local dump_rc=$?

    if [[ $dump_rc -eq 0 && -s "$db_dump_file" ]]; then
        local dump_lines=$(wc -l < "$db_dump_file")
        local dump_size_h=$(du -h "$db_dump_file" 2>/dev/null | cut -f1)
        log_success "数据库导出完成 (${dump_lines} 行, ${dump_size_h}, 耗时 ${elapsed}s)"
    else
        log_error "数据库导出失败 (rc=$dump_rc, 耗时 ${elapsed}s)"
        rm -rf "$migration_dir"
        return 1
    fi
    
    # Generate migration metadata
    log_info "生成迁移元数据..."

    # ── release 身份 ────────────────────────────────────────────────────────
    # 这是 S2 的核心: 没有它, 迁移包只钉死了数据、没钉死镜像, 恢复到新机器就会
    # 拉当天的 latest 配老库 → 启动门禁拦下(本设计要修的原始 bug)。
    local rel_source="env" rel_status="" rel_version="" rel_sha=""
    local rel_web_digest="" rel_ctl_digest=""
    local rel_web_repo_digest="" rel_ctl_repo_digest=""
    local ledger
    if ledger=$(read_schema_ledger_from_db); then
        IFS=$'\x1f' read -r rel_status rel_version rel_sha rel_web_digest rel_ctl_digest <<< "$ledger"
        if [[ "$rel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+._-][A-Za-z0-9.-]+)?$ ]]; then
            rel_source="db"
            log_info "✓ schema 账本: release=$rel_version status=$rel_status sha=${rel_sha:0:12}..."
            # 源库半迁移状态: 账本里的 version/sha 可能处于不一致中间态, 按它恢复会在
            # 启动门禁 validate_state(status!="stable" 直接 bail) 挂掉, 且更难排障。
            if [[ "$rel_status" != "stable" ]]; then
                log_warning "源库 schema 状态为 '${rel_status}'(非 stable), 上次迁移可能未完成"
                log_warning "该包恢复后会被启动门禁拒绝; 建议先在本机修好账本(--update)再重新打包"
            fi
        else
            log_warning "schema 账本版本号非法('${rel_version}'), 退回 .env 镜像引用"
            rel_version=""; rel_status=""; rel_sha=""
        fi
    else
        log_warning "读不到 schema 账本(legacy 库?), 退回 .env 镜像引用; 该包的版本身份不确定"
    fi

    # 镜像引用: **由 release.version + repo 前缀构造**, 绝不从 .env 拷贝 ——
    # .env 里今天写的很可能就是 :latest, 照抄等于把活动指针原样带到新机器,
    # 那样即便恢复端仲裁全对, 最后一步又会把 .env 写回 :latest, 修完等于没修。
    local rel_images="" name var ref repo pinned first=1
    for name in zf_web zf_controler rrd_service zfc_util zfc_admin; do
        case "$name" in
            zf_web)       var=ZF_WEB_IMAGE ;;
            zf_controler) var=ZF_CONTROLER_IMAGE ;;
            rrd_service)  var=RRD_SERVICE_IMAGE ;;
            zfc_util)     var=ZFC_UTIL_IMAGE ;;
            zfc_admin)    var=ZFC_ADMIN_IMAGE ;;
        esac
        ref="${!var}"
        [[ -n "$ref" ]] || continue
        if [[ -n "$rel_version" ]]; then
            repo=$(image_repo_prefix "$ref")
            pinned="${repo}:${rel_version}"
        else
            pinned="$ref"          # 无账本: 只能原样带走, 恢复端会显式确认
        fi
        [[ "$first" == "1" ]] && first=0 || rel_images="${rel_images},"
        rel_images="${rel_images}
      \"${name}\": \"${pinned}\""
    done

    # registry digest: 跨机器可 pull 的字节级引用。本地 build 从未 push 过的镜像
    # 取不到, 属正常(开发环境迁移), 恢复端对「包里没记」要跳过而非判失败。
    rel_web_repo_digest=$(image_repo_digest "$ZF_WEB_IMAGE" 2>/dev/null || true)
    rel_ctl_repo_digest=$(image_repo_digest "$ZF_CONTROLER_IMAGE" 2>/dev/null || true)

    cat > "$migration_dir/migration_info.json" << EOF
{
  "migration_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "postgres_type": "builtin",
  "script_version": "2.0.0",
  "source_system": "$(hostname)",
  "release": {
    "source": "${rel_source}",
    "version": "${rel_version}",
    "status": "${rel_status}",
    "schema_artifact_sha256": "${rel_sha}",
    "zf_web_image_digest": "${rel_web_digest}",
    "zf_controler_image_digest": "${rel_ctl_digest}",
    "zf_web_repo_digest": "${rel_web_repo_digest}",
    "zf_controler_repo_digest": "${rel_ctl_repo_digest}",
    "images": {${rel_images}
    }
  },
  "files": {
    "config_files": $(ls -1 "$migration_dir"/*.env "$migration_dir"/*.yml "$migration_dir"/.admin_token "$migration_dir"/Caddyfile 2>/dev/null | wc -l),
    "database_dump": "postgres_dump.sql",
    "prisma_included": $([ -d "$migration_dir/prisma" ] && echo "true" || echo "false")
  }
}
EOF
    
    # Create compressed archive
    log_info "创建压缩包..."
    if tar -czf "$migration_archive" "$migration_dir/" 2>/dev/null; then
        local archive_size=$(du -h "$migration_archive" | cut -f1)
        log_success "迁移包创建完成"
        log_info "文件名: $migration_archive"
        log_info "大小: $archive_size"
    else
        log_error "创建压缩包失败"
        rm -rf "$migration_dir"
        return 1
    fi
    
    # Clean up temporary directory
    rm -rf "$migration_dir"
    
    echo
    log_success "=== 迁移包打包完成 ==="
    echo
    echo -e "${GREEN}迁移包信息:${NC}"
    echo -e "  文件名: ${GREEN}$migration_archive${NC}"
    echo -e "  大小: $archive_size"
    echo -e "  创建时间: $(date)"
    if [[ -n "$rel_version" ]]; then
        echo -e "  锁定版本: ${GREEN}${rel_version}${NC} (恢复后将部署同版本，不会漂到 latest)"
    else
        echo -e "  锁定版本: ${YELLOW}未知${NC} (读不到 schema 账本；恢复时需显式确认版本)"
    fi
    echo
    echo -e "${YELLOW}重要提醒:${NC}"
    echo -e "  - 迁移包包含敏感信息（密钥、密码等）"
    echo -e "  - 请妥善保管，避免泄露"
    echo -e "  - 传输时建议使用安全渠道"
    echo -e "  - 使用完毕后请及时删除"
    echo -e "  - 需要确保目标机器和当前机器系统版本一致（Docker 版本、操作系统等），否则可能无法恢复"
    echo
    echo -e "${GREEN}使用方法:${NC}"
    echo -e "  1. 停止本机服务 'docker-compose down'"
    echo -e "  2. 将 $migration_archive 上传到目标机器"
    echo -e "  3. 在目标机器运行本脚本，选择 '一键恢复迁移文件'"

    echo
}

# Restore migration data function
restore_migration_data() {
    log_info "一键恢复迁移文件..."

    local migration_package=""
    local restore_noninteractive=0
    [[ -n "$ZFC_RESTORE_PACKAGE" || "$ZFC_NONINTERACTIVE" == "1" ]] && restore_noninteractive=1

    # 非交互/显式指定: 在产生任何副作用(改时间同步)前先校验迁移包, 缺失即 fail-fast。
    if [[ "$restore_noninteractive" == "1" ]]; then
        migration_package="$ZFC_RESTORE_PACKAGE"
        [[ -n "$migration_package" ]] || die "$EXIT_MISSING_INPUT" "非交互恢复需显式 ZFC_RESTORE_PACKAGE=<迁移包路径(.tar.gz)>"
        [[ -f "$migration_package" ]] || die "$EXIT_MISSING_INPUT" "迁移包不存在: ${migration_package}"
        [[ "$migration_package" =~ \.tar\.gz$ ]] || die "$EXIT_BAD_CONFIG" "迁移包格式应为 .tar.gz: ${migration_package}"
        [[ -r "$migration_package" ]] || die "$EXIT_BAD_CONFIG" "迁移包不可读: ${migration_package}"
    fi

    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi

    # Setup time synchronization
    setup_time_sync

    # 已在前面校验过的非交互路径: 直接采用 ZFC_RESTORE_PACKAGE, 跳过扫描/选择。
    if [[ "$restore_noninteractive" == "1" ]]; then
        log_success "使用迁移包: ${migration_package}"
    else
    # Scan for migration packages in current directory
    echo
    log_info "扫描当前目录下的迁移包文件..."

    local migration_files=()
    while IFS= read -r -d '' file; do
        migration_files+=("$file")
    done < <(find . -maxdepth 1 -name "zfc_migration_*.tar.gz" -type f -print0 2>/dev/null | sort -z)

    if [[ ${#migration_files[@]} -eq 0 ]]; then
        log_warning "当前目录下未找到迁移包文件"
        echo
        log_info "请提供迁移包文件路径"
        echo "支持的格式: zfc_migration_*.tar.gz"
        echo
        
        while true; do
            read -p "请输入迁移包文件路径: " migration_package
            
            if [[ -z "$migration_package" ]]; then
                log_error "文件路径不能为空"
                continue
            fi
            
            if [[ ! -f "$migration_package" ]]; then
                log_error "文件不存在: $migration_package"
                continue
            fi
            
            if [[ ! "$migration_package" =~ \.tar\.gz$ ]]; then
                log_error "文件格式不支持，请提供 .tar.gz 文件"
                continue
            fi
            
            if [[ ! -r "$migration_package" ]]; then
                log_error "无法读取文件: $migration_package"
                continue
            fi
            
            break
        done
    elif [[ ${#migration_files[@]} -eq 1 ]]; then
        migration_package="${migration_files[0]}"
        log_success "找到迁移包: $migration_package"
    else
        log_success "找到 ${#migration_files[@]} 个迁移包文件"
        echo
        echo "请选择要恢复的迁移包："
        
        local i=1
        for file in "${migration_files[@]}"; do
            local file_size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "unknown")
            local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
            echo "  $i. $(basename "$file") (大小: $file_size, 修改时间: $file_date)"
            ((i++))
        done
        echo "  $i. 手动输入文件路径"
        echo
        
        while true; do
            read -p "请选择 [1-$i]: " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#migration_files[@]} ]]; then
                migration_package="${migration_files[$((choice-1))]}"
                log_success "已选择: $migration_package"
                break
            elif [[ "$choice" -eq $i ]]; then
                # Manual input option
                while true; do
                    read -p "请输入迁移包文件路径: " migration_package
                    
                    if [[ -z "$migration_package" ]]; then
                        log_error "文件路径不能为空"
                        continue
                    fi
                    
                    if [[ ! -f "$migration_package" ]]; then
                        log_error "文件不存在: $migration_package"
                        continue
                    fi
                    
                    if [[ ! "$migration_package" =~ \.tar\.gz$ ]]; then
                        log_error "文件格式不支持，请提供 .tar.gz 文件"
                        continue
                    fi
                    
                    if [[ ! -r "$migration_package" ]]; then
                        log_error "无法读取文件: $migration_package"
                        continue
                    fi
                    
                    break
                done
                break
            else
                log_error "无效选择，请输入 1-$i"
            fi
        done
    fi
    fi  # 结束「非交互 ZFC_RESTORE_PACKAGE / 交互扫描选择」分支

    log_success "迁移包验证通过: $migration_package"
    
    # Create temporary directory for extraction
    local temp_dir="zfc_restore_temp_$(date +%Y%m%d_%H%M%S)"
    ZFC_RESTORE_TEMP_DIR="$temp_dir"     # 供 zfc_on_exit 兜底清理(覆盖 Ctrl-C)
    log_info "创建临时目录: $temp_dir"
    mkdir -p "$temp_dir"
    
    # Extract migration package
    log_info "解压迁移包..."
    if ! tar -xzf "$migration_package" -C "$temp_dir" 2>/dev/null; then
        log_error "解压迁移包失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Find the migration directory inside temp_dir
    local migration_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "zfc_migration_*" | head -1)
    if [[ -z "$migration_dir" ]]; then
        log_error "迁移包格式错误：未找到迁移目录"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_success "迁移包解压完成"
    
    # Validate migration package contents
    log_info "验证迁移包内容..."
    
    local required_files=(".env" "postgres_dump.sql" "migration_info.json")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$migration_dir/$file" ]]; then
            log_error "迁移包缺少必要文件: $file"
            rm -rf "$temp_dir"
            return 1
        fi
    done
    
    # Check migration metadata
    if [[ -f "$migration_dir/migration_info.json" ]]; then
        local postgres_type=$(grep -o '"postgres_type": *"[^"]*"' "$migration_dir/migration_info.json" | cut -d'"' -f4)
        if [[ "$postgres_type" != "builtin" ]]; then
            log_error "迁移包不是内置数据库类型: $postgres_type"
            rm -rf "$temp_dir"
            return 1
        fi
        
        local migration_time=$(grep -o '"migration_time": *"[^"]*"' "$migration_dir/migration_info.json" | cut -d'"' -f4)
        log_info "迁移包信息："
        log_info "  创建时间: $migration_time"
        log_info "  数据库类型: $postgres_type"
    fi

    # ── 版本仲裁 (纯读包内文件, 零副作用) ──────────────────────────────────
    # 必须整体前置到破坏性操作之前。现有流程在下方 4699+ 清容器/卷/网络(等价
    # down -v, 本地数据不可逆销毁)、再 cp 覆盖 .env。若把仲裁插在那之后, 一旦失败
    # 就是「旧部署已毁、新部署起不来、回滚目标已不存在」的不可恢复态。
    if ! restore_resolve_target "$migration_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    # Confirm restoration
    echo
    log_warning "即将开始恢复操作"
    echo -e "${YELLOW}注意：此操作将：${NC}"
    echo "  - 覆盖当前的配置文件"
    echo "  - 清空并重建 PostgreSQL 数据库"
    echo "  - 重启所有服务"
    if [[ -n "$ZFC_RESTORE_VERSION" ]]; then
        echo -e "  - 部署版本: ${GREEN}${ZFC_RESTORE_VERSION}${NC} (与迁移包一致，不会漂到 latest)"
    fi
    echo

    # 非交互: 由 ZFC_ASSUME_YES 决定(默认 yes, 因为 restore 是显式动作)
    # 注意与 restore_resolve_target 里「版本不明」那个确认的区别: 那个必须硬编码 no
    # (fail-closed), 这个是 restore 动作本身的 proceed 确认, 沿用既有语义。
    if confirm "确认执行恢复操作(将覆盖配置/重建数据库/重启服务)？" "$(assume_default)"; then
        log_info "开始执行恢复操作..."
    else
        log_info "取消恢复操作"
        rm -rf "$temp_dir"
        return 0
    fi

    # 拉镜像 + fail-closed 校验。放在确认之后: 版本展示不依赖 pull, 用户选错包时
    # 不必先等几分钟、白占几 GB 磁盘才能取消。此步仍在破坏性清理之前, 失败零损伤。
    if ! restore_pull_and_verify "$migration_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    # 破坏性操作前备份本机 .env。注意其局限: 下方清理会不可逆销毁容器与数据卷,
    # 恢复这份备份只是让本地配置与残留状态自洽(避免 .env 引用已不存在的镜像),
    # **不是**把数据找回来 —— 数据回不来, 唯一出路是重跑 restore。
    if [[ -f .env ]]; then
        ZFC_RESTORE_ENV_BACKUP=".env.pre-restore-$(date +%Y%m%d_%H%M%S)"
        cp .env "$ZFC_RESTORE_ENV_BACKUP" 2>/dev/null && chmod 600 "$ZFC_RESTORE_ENV_BACKUP" 2>/dev/null || true
        log_info "本机 .env 已备份: $ZFC_RESTORE_ENV_BACKUP"
    fi

    # Check and clean existing environment
    log_info "检查现有环境..."
    
    local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    local cleanup_needed=false
    local cleanup_items=()
    
    # Check for existing containers
    local existing_containers=$(docker ps -a --format "{{.Names}}" | grep -E "^zfc-" || true)
    if [[ -n "$existing_containers" ]]; then
        cleanup_needed=true
        cleanup_items+=("容器: $(echo "$existing_containers" | tr '\n' ' ')")
    fi
    
    # Check for existing volumes
    local existing_volumes=$(docker volume ls -q --filter "name=${project_name}_" || true)
    if [[ -n "$existing_volumes" ]]; then
        cleanup_needed=true
        cleanup_items+=("数据卷: $(echo "$existing_volumes" | tr '\n' ' ')")
    fi
    
    # Check for existing networks
    local existing_networks=$(docker network ls --filter "name=${project_name}" --format "{{.Name}}" | grep -v "bridge\|host\|none" || true)
    if [[ -n "$existing_networks" ]]; then
        cleanup_needed=true
        cleanup_items+=("网络: $(echo "$existing_networks" | tr '\n' ' ')")
    fi
    
    if [[ "$cleanup_needed" == "true" ]]; then
        echo
        log_warning "检测到以下残留资源需要清理："
        for item in "${cleanup_items[@]}"; do
            echo "  - $item"
        done
        echo
        
        # 非交互: 由 ZFC_ASSUME_YES 决定(默认 yes; 否则取消恢复)
        if confirm "确认清理这些残留资源(恢复继续所需)？" "$(assume_default)"; then
            log_info "开始清理残留资源..."
        else
            log_error "清理被取消，无法继续恢复操作"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log_info "环境检查通过，无需清理"
    fi

    # Stop existing services
    log_info "停止现有服务..."
    if [[ -f "docker-compose.yml" ]]; then
        $DOCKER_COMPOSE_CMD down 2>/dev/null || true
    fi
    
    # Remove any orphaned containers from previous failed attempts
    log_info "清理可能的残留容器..."
    local containers_to_remove=(
        "zfc-postgres" "zfc-redis" "zfc-tdengine" 
        "zfc-controler" "zfc-web" "zfc-rrd-service" 
        "zfc-caddy" "zfc-tdengine-init"
    )
    
    for container in "${containers_to_remove[@]}"; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            log_info "移除残留容器: $container"
            docker rm -f "$container" 2>/dev/null || true
        fi
    done
    
    # Clean all related volumes
    log_info "清理所有相关数据卷..."
    local project_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    
    local volumes_to_clean=(
        "${project_name}_postgres_data"
        "${project_name}_redis_data" 
        "${project_name}_tdengine_data"
        "${project_name}_tdengine_log"
        "${project_name}_rrd_data"
        "${project_name}_caddy_data"
        "${project_name}_caddy_config"
        "${project_name}_zf_web_downloads"
    )
    
    for volume in "${volumes_to_clean[@]}"; do
        if docker volume ls -q | grep -q "^${volume}$"; then
            log_info "清理数据卷: $volume"
            docker volume rm "$volume" 2>/dev/null || true
        fi
    done
    
    # Also clean any volumes with the project prefix (catch-all)
    local remaining_volumes=$(docker volume ls -q --filter "name=${project_name}_" 2>/dev/null || true)
    if [[ -n "$remaining_volumes" ]]; then
        log_info "清理剩余的项目数据卷..."
        echo "$remaining_volumes" | xargs -r docker volume rm 2>/dev/null || true
    fi
    
    # Clean any networks that might be left behind
    log_info "清理残留网络..."
    local networks_to_clean=$(docker network ls --filter "name=${project_name}" --format "{{.Name}}" 2>/dev/null | grep -v "bridge\|host\|none" || true)
    if [[ -n "$networks_to_clean" ]]; then
        echo "$networks_to_clean" | xargs -r docker network rm 2>/dev/null || true
    fi
    
    log_success "环境清理完成"
    
    # Restore configuration files
    log_info "恢复配置文件..."
    
    local config_files=(".env" "docker-compose.yml" "Caddyfile" ".admin_token")
    for file in "${config_files[@]}"; do
        if [[ -f "$migration_dir/$file" ]]; then
            cp "$migration_dir/$file" ./ 2>/dev/null && log_info "✓ $file" || log_warning "复制 $file 失败"
        fi
    done
    
    # Restore prisma directory
    if [[ -d "$migration_dir/prisma" ]]; then
        cp -r "$migration_dir/prisma" ./ 2>/dev/null && log_info "✓ prisma/ 目录" || log_warning "复制 prisma 目录失败"
    fi
    
    # ── 把恢复出来的 .env 钉到仲裁出的版本 ────────────────────────────────
    # 改写的值只来自仲裁结果(release.version + repo 前缀现拼), **绝不读包内 .env
    # 的旧 tag** —— 包内 .env 在今天的主路径上就是 :latest, 照抄等于把原 bug 一路
    # 带到新机器: 前面仲裁全对, 最后一步又写回 :latest, compose up 照样漂。
    # 不改写就等于没修。
    if [[ -n "${ZFC_RESTORE_VERSION:-}" && -n "${ZFC_RESTORE_WEB_IMAGE:-}" ]]; then
        local rst_channel rst_repo rst_pairs=()
        rst_channel=$(grep -E '^[[:space:]]*ZFC_UPDATE_CHANNEL=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)
        rst_channel="${rst_channel%\"}"; rst_channel="${rst_channel#\"}"
        [[ -n "$rst_channel" ]] || rst_channel="latest"
        rst_pairs+=("ZFC_UPDATE_CHANNEL=$(quote_env_value "$rst_channel")")
        rst_pairs+=("ZF_WEB_IMAGE=$(quote_env_value "$ZFC_RESTORE_WEB_IMAGE")")
        rst_pairs+=("ZF_CONTROLER_IMAGE=$(quote_env_value "$ZFC_RESTORE_CTL_IMAGE")")
        # 其余镜像同 registry 同版本(prisma 恒 latest, 不参与)
        local rst_v rst_name
        for rst_name in RRD_SERVICE_IMAGE ZFC_UTIL_IMAGE ZFC_ADMIN_IMAGE; do
            rst_v=$(grep -E "^[[:space:]]*${rst_name}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true)
            rst_v="${rst_v%\"}"; rst_v="${rst_v#\"}"
            [[ -n "$rst_v" ]] || continue
            rst_repo=$(image_repo_prefix "$rst_v")
            [[ -n "${ZFC_RESTORE_REGISTRY:-}" ]] && rst_repo="${ZFC_RESTORE_REGISTRY%/}/${rst_repo##*/}"
            rst_pairs+=("${rst_name}=$(quote_env_value "${rst_repo}:${ZFC_RESTORE_VERSION}")")
        done
        if write_env_keys_atomic "${rst_pairs[@]}"; then
            log_success ".env 已钉到 ${ZFC_RESTORE_VERSION}"
        else
            log_error ".env 钉版本改写失败"
            if [[ -n "${ZFC_RESTORE_ENV_BACKUP:-}" && -f "$ZFC_RESTORE_ENV_BACKUP" ]]; then
                cp "$ZFC_RESTORE_ENV_BACKUP" .env 2>/dev/null || true
                log_warning "已恢复 $ZFC_RESTORE_ENV_BACKUP (注意: 本机旧数据已在前面被清理, 数据无法找回; 请重跑 restore)"
            fi
            rm -rf "$temp_dir"
            return 1
        fi
        cleanup_env_backups
    fi

    # Source the restored environment
    # 必须在上面的改写**之后** —— 否则后续所有读 shell $ZF_*_IMAGE 的地方拿到的
    # 都是改写前的旧值(update 路径的 §7.2 步骤 7 已有此要求, 这里是对称条款)。
    if [[ -f ".env" ]]; then
        source .env
    else
        log_error "恢复的 .env 文件无效"
        rm -rf "$temp_dir"
        return 1
    fi

    # Setup Docker log auto cleanup on the new host (best-effort).
    # Must run after docker-compose.yml is restored and before any
    # compose up command. Wrapped with '|| true' so an unexpected
    # failure never aborts the restore flow under set -e.
    setup_docker_log_cleanup || true

    # Start PostgreSQL service
    log_info "启动 PostgreSQL 服务..."
    if ! $DOCKER_COMPOSE_CMD up -d postgres 2>/dev/null; then
        log_error "启动 PostgreSQL 失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Wait for PostgreSQL to be ready
    log_info "等待 PostgreSQL 启动..."
    local retry_count=0
    while ! $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U postgres >/dev/null 2>&1; do
        sleep 2
        retry_count=$((retry_count + 1))
        if [ $retry_count -gt 30 ]; then
            log_error "PostgreSQL 启动超时"
            rm -rf "$temp_dir"
            return 1
        fi
    done
    
    # Additional wait for password authentication
    sleep 5
    
    # Import database
    log_info "导入数据库数据..."
    local db_dump_file="$migration_dir/postgres_dump.sql"
    
    if $DOCKER_COMPOSE_CMD exec -T postgres psql -U postgres -d zfc < "$db_dump_file" >/dev/null 2>&1; then
        local import_lines=$(wc -l < "$db_dump_file")
        log_success "数据库导入完成 (${import_lines} 行)"
    else
        log_error "数据库导入失败"
        log_info "尝试创建数据库后重新导入..."
        
        # Try to create database first
        $DOCKER_COMPOSE_CMD exec -T postgres psql -U postgres -c "CREATE DATABASE zfc;" 2>/dev/null || true
        
        if $DOCKER_COMPOSE_CMD exec -T postgres psql -U postgres -d zfc < "$db_dump_file" >/dev/null 2>&1; then
            log_success "数据库重新导入成功"
        else
            log_error "数据库导入仍然失败，请检查数据库配置"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    # Start TDengine and wait for it to be ready (skip if disabled)
    if [[ "${TDENGINE_TYPE:-builtin}" != "disabled" ]]; then
        log_info "启动 TDengine 服务..."
        if $DOCKER_COMPOSE_CMD up -d tdengine 2>/dev/null; then
            log_info "等待 TDengine 启动..."
            sleep 10

            # Initialize TDengine password
            log_info "初始化 TDengine 密码..."
            local tdengine_init_success=false
            local retry_count=0

            while [ $retry_count -lt 5 ]; do
                # Try to set TDengine root password
                if $DOCKER_COMPOSE_CMD exec -T tdengine taos -u root -ptaosdata -s "alter user root pass '${TDENGINE_ROOT_PASSWORD}';" >/dev/null 2>&1; then
                    log_success "TDengine 密码设置成功"
                    tdengine_init_success=true
                    break
                elif $DOCKER_COMPOSE_CMD exec -T tdengine taos -u root -p"${TDENGINE_ROOT_PASSWORD}" -s "show databases;" >/dev/null 2>&1; then
                    log_info "TDengine 密码已经设置"
                    tdengine_init_success=true
                    break
                else
                    retry_count=$((retry_count + 1))
                    log_info "TDengine 密码设置重试 ($retry_count/5)..."
                    sleep 5
                fi
            done

            if [ "$tdengine_init_success" = false ]; then
                log_warning "TDengine 密码初始化失败，可能影响服务启动"
            fi
        else
            log_warning "TDengine 启动失败"
        fi
    else
        log_info "TDengine 已禁用，跳过初始化"
    fi
    
    # Start all services
    log_info "启动所有服务..."
    if $DOCKER_COMPOSE_CMD up -d 2>/dev/null; then
        log_success "服务启动完成"
    else
        log_warning "部分服务启动可能失败，请检查配置"
    fi
    
    # Verify system status
    log_info "验证系统状态..."
    sleep 10
    
    # Check running services using a more compatible approach
    local running_services=0
    if command -v docker-compose >/dev/null 2>&1; then
        # For older docker-compose
        running_services=$($DOCKER_COMPOSE_CMD ps | grep "Up" | wc -l)
    else
        # For newer docker compose
        running_services=$($DOCKER_COMPOSE_CMD ps --format json 2>/dev/null | grep '"State":"running"' | wc -l || $DOCKER_COMPOSE_CMD ps | grep "Up" | wc -l)
    fi
    
    if [[ $running_services -gt 0 ]]; then
        log_success "系统运行正常 ($running_services 个服务运行中)"
    else
        log_warning "系统可能存在问题，请检查服务状态"
        log_info "建议运行: $DOCKER_COMPOSE_CMD ps 检查服务状态"
        log_info "查看日志: $DOCKER_COMPOSE_CMD logs [service_name]"
    fi
    
    # Clean up temporary files
    rm -rf "$temp_dir"
    
    echo
    log_success "=== 迁移恢复完成 ==="
    echo
    echo -e "${GREEN}恢复摘要:${NC}"
    echo -e "  配置文件: 已恢复"
    if [[ -n "${ZFC_RESTORE_VERSION:-}" ]]; then
        echo -e "  部署版本: ${GREEN}${ZFC_RESTORE_VERSION}${NC} (与迁移包一致)"
    else
        # 版本不明的恢复(用户在仲裁处显式确认过): 必须说清现在跑的是什么, 否则
        # 用户会以为「恢复成功 = 版本正确」, 而实际用的是包内 .env 的引用(可能是 :latest)。
        echo -e "  部署版本: ${YELLOW}未确定${NC} (迁移包无版本身份, 已沿用包内 .env 的镜像引用)"
        echo -e "            当前引用: ${ZF_WEB_IMAGE:-?}"
        echo -e "            ${YELLOW}若该引用是 :latest, 起来的可能不是与这份数据匹配的版本${NC}"
    fi
    echo -e "  PostgreSQL: 已恢复"
    echo -e "  服务状态: $running_services 个运行中"
    echo
    if [[ -n "${ZFC_RESTORE_VERSION:-}" ]]; then
        echo
        echo -e "${YELLOW}迁移 != 升级${NC}: 已恢复到 ${ZFC_RESTORE_VERSION}(与包一致)。"
        echo -e "确认服务健康后，如需升级到最新版，再单独执行: ${GREEN}./install.sh --update${NC}"
    fi
    echo
    echo -e "${GREEN}建议操作:${NC}"
    echo -e "  1. 检查服务状态: $DOCKER_COMPOSE_CMD ps"
    echo -e "  2. 查看服务日志: $DOCKER_COMPOSE_CMD logs -f [service_name]"
    echo -e "  3. 访问前端界面验证功能"
    if [[ -f ".admin_token" ]]; then
        local admin_token=$(cat .admin_token 2>/dev/null)
        if [[ -n "$admin_token" ]]; then
            echo -e "  4. 管理员 Token: ${GREEN}$admin_token${NC}"
        fi
    fi
    echo
}

# Show admin token function
show_admin_token() {
    log_info "查看管理员密码..."

    # agent/JSON 模式: 直接返回缓存的 .admin_token(避免容器非结构化输出污染 stdout)
    if [[ "$ZFC_OUTPUT_JSON" == "1" ]]; then
        if [[ -f .admin_token ]]; then
            ADMIN_TOKEN="$(cat .admin_token 2>/dev/null | tr -d '[:space:]')"
        fi
        [[ -n "$ADMIN_TOKEN" ]] || die "$EXIT_MISSING_INPUT" ".admin_token 不存在或为空; 无法返回管理员 token(请确认已安装)"
        return 0
    fi

    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi
    
    # Check if system is installed
    if [[ ! -f ".env" ]] || [[ ! -f "docker-compose.yml" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "系统未安装(缺 .env 或 docker-compose.yml); 请先执行全新安装 (--install)" || return 1
    fi
    
    # Source environment variables
    source .env
    
    # Check if services are running (only for builtin databases)
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" || "$TDENGINE_TYPE" == "builtin" ]]; then
        if ! $DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
            log_error "服务未运行，请先启动系统"
            return 1
        fi
    fi
    
    # Prepare database and Redis URLs from environment
    local db_url="${POSTGRES_URL:-${DB_PATH}}"
    local redis_url="${REDIS_URL:-${REDIS_PATH}}"
    local network_args
    
    # Determine network settings
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" ]]; then
        local network_name
        network_name=$(get_compose_network)
        log_info "使用 Docker Compose 网络: $network_name"
        
        # Verify network exists
        if ! docker network inspect "$network_name" >/dev/null 2>&1; then
            log_error "Docker Compose 网络 $network_name 不存在"
            log_error "请确保系统已安装并运行"
            return 1
        fi
        
        network_args="--network $network_name"
    else
        network_args=""
    fi
    
    log_info "从数据库查询管理员信息..."
    log_info "数据库类型: PostgreSQL=${POSTGRES_TYPE}, Redis=${REDIS_TYPE}"

    # schema 漂移防御（不一致时自动 re-pull 一次工具镜像，见 ensure_zfc_admin_schema_for_ops）
    if ! ensure_zfc_admin_schema_for_ops "$db_url" "$network_args"; then
        return 1
    fi

    # Use zfc-admin to show admin token
    docker run --rm \
        $network_args \
        -e DB_PATH="$db_url" \
        -e REDIS_PATH="$redis_url" \
        -e MGMT_ARRANGER_PRIV_KEY="${MGMT_ARRANGER_PRIV_KEY}" \
        -e ARRANGER_HOSTS_URL="https://${CONTROLER_DOMAIN}" \
        "$ZFC_ADMIN_IMAGE" \
        show-admin-token
}

refresh_admin_token() {
    log_info "刷新管理员 Token..."

    # Set docker-compose command (统一探测, 修正历史只查 docker 的 bug)
    if ! detect_compose_cmd; then
        die "$EXIT_DEP_UNAVAILABLE" "Docker Compose 未安装！请先安装 Docker Compose"
    fi

    # Check if system is installed
    if [[ ! -f ".env" ]] || [[ ! -f "docker-compose.yml" ]]; then
        die_or_return "$EXIT_MISSING_INPUT" "系统未安装(缺 .env 或 docker-compose.yml); 请先执行全新安装 (--install)" || return 1
    fi

    # Source environment variables
    source .env

    # Read current admin token
    local current_token=""
    if [[ -f ".admin_token" ]]; then
        current_token=$(cat .admin_token 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "$current_token" ]]; then
        log_error ".admin_token 文件不存在或为空，无法确定当前管理员 Token"
        return 1
    fi

    log_warning "当前管理员 Token: ${current_token:0:8}..."
    log_warning "刷新后需要重启 zf-web 才能完全生效"
    echo
    if ! confirm "确定要刷新管理员 Token?" "$(assume_default)"; then
        log_info "操作已取消"
        return 0
    fi

    # Check if services are running (only for builtin databases)
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" || "$TDENGINE_TYPE" == "builtin" ]]; then
        if ! $DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
            log_error "服务未运行，请先启动系统"
            return 1
        fi
    fi

    # Prepare database and Redis URLs from environment
    local db_url="${POSTGRES_URL:-${DB_PATH}}"
    local redis_url="${REDIS_URL:-${REDIS_PATH}}"
    local network_args

    # Determine network settings
    if [[ "$POSTGRES_TYPE" == "builtin" || "$REDIS_TYPE" == "builtin" ]]; then
        local network_name
        network_name=$(get_compose_network)
        log_info "使用 Docker Compose 网络: $network_name"

        # Verify network exists
        if ! docker network inspect "$network_name" >/dev/null 2>&1; then
            log_error "Docker Compose 网络 $network_name 不存在"
            return 1
        fi

        network_args="--network $network_name"
    else
        network_args=""
    fi

    log_info "正在刷新管理员 Token..."

    # schema 漂移防御（不一致时自动 re-pull 一次工具镜像，见 ensure_zfc_admin_schema_for_ops）
    if ! ensure_zfc_admin_schema_for_ops "$db_url" "$network_args"; then
        return 1
    fi

    # Run zfc-admin refresh-admin-token and capture output
    local output
    output=$(docker run --rm \
        $network_args \
        -e DB_PATH="$db_url" \
        -e REDIS_PATH="$redis_url" \
        -e MGMT_ARRANGER_PRIV_KEY="${MGMT_ARRANGER_PRIV_KEY}" \
        -e ARRANGER_HOSTS_URL="https://${CONTROLER_DOMAIN}" \
        "$ZFC_ADMIN_IMAGE" \
        refresh-admin-token 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        log_error "刷新管理员 Token 失败"
        return 1
    fi

    # Find the mapping for our current token
    local new_token=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^refreshed\ token:\ (.+)\ -\>\ (.+)$ ]]; then
            local old="${BASH_REMATCH[1]}"
            local new="${BASH_REMATCH[2]}"
            if [[ "$old" == "$current_token" ]]; then
                new_token="$new"
                break
            fi
        fi
    done <<< "$output"

    if [[ -z "$new_token" ]]; then
        log_error "当前 .admin_token 中的 Token 不是管理员 Token，无法自动更新"
        log_error "刷新输出:"
        echo "$output"
        return 1
    fi

    # Update .admin_token file (限制权限: 含敏感凭证)
    ( umask 077; echo "$new_token" > .admin_token )
    chmod 600 .admin_token 2>/dev/null || true
    ADMIN_TOKEN="$new_token"
    log_success "管理员 Token 已刷新"
    echo -e "  新 Token: ${GREEN}${new_token}${NC}"
    echo

    # Mandatory restart zf-web
    log_info "正在重启 zf-web 以使新 Token 生效..."
    if $DOCKER_COMPOSE_CMD restart zf-web; then
        log_success "zf-web 重启完成，新 Token 已生效"
    else
        log_warning "zf-web 重启失败，请手动执行: $DOCKER_COMPOSE_CMD restart zf-web"
    fi

    echo
    log_warning "请妥善保管新的管理员 Token"
}

# Setup Docker log auto cleanup (best-effort)
#
# This function always returns 0 — any failure is logged as a warning
# and the caller (install / restore) continues. Call sites should still
# wrap it with '|| true' for extra safety under set -e.
#
# Design notes (addressing prior review concerns):
#   • Only configures per-service logging in docker-compose.override.yml.
#     We do NOT touch /etc/docker/daemon.json, so the host-wide log-driver
#     and any existing central-logging setup (journald, local, fluentd,
#     splunk, …) is left untouched. This also means we do not care about
#     Docker's data-root, which may not be /var/lib/docker.
#   • We only use Docker's own json-file max-size/max-file rotation. No
#     logrotate rules are installed, so there is no race with dockerd
#     rewriting the same active log files.
#   • Docker's json-file driver has no native "retention days" option;
#     we expose max-size and max-file directly and explain that the
#     per-container cap equals max-size × max-file.
#   • No sudo, no python3, no jq, no logrotate required — we only write
#     files inside the project directory.
#
# Usage: setup_docker_log_cleanup [standalone]
#   standalone: if set, offer to recreate containers at the end
setup_docker_log_cleanup() {
    local mode="${1:-inline}"

    echo
    log_info "=== Docker 日志自动清理配置 ==="
    log_info "Docker 默认不限制容器日志大小，随时间增长可能占用大量磁盘空间。"
    log_info "此功能通过 docker-compose.override.yml 为 ZFC 服务配置日志限制："
    log_info "  • 仅影响 ZFC 容器，不修改宿主机 /etc/docker/daemon.json"
    log_info "  • 使用 Docker 原生 json-file 驱动按大小轮转，无外部工具竞态"
    log_info "  • 单容器日志总量上限 = max-size × max-file"
    log_info "  • 注意：Docker json-file 驱动不支持按天数清理，仅支持按大小"
    echo

    if ! command_exists docker; then
        log_warning "Docker 未安装，跳过日志清理配置"
        return 0
    fi

    # docker-compose.yml is required — we only configure services that
    # actually exist in the generated compose file.
    if [[ ! -f "docker-compose.yml" ]]; then
        log_warning "docker-compose.yml 不存在，跳过日志清理配置"
        return 0
    fi

    local cleanup_default="yes"
    [[ "$ZFC_ASSUME_YES" == "1" ]] || cleanup_default="no"
    if ! confirm "是否启用 Docker 日志自动清理？" "$cleanup_default"; then
        log_warning "已跳过 Docker 日志自动清理配置"
        log_warning "建议后续通过菜单选项 8 手动配置，避免容器日志占满磁盘"
        return 0
    fi

    # Get max log file size (非交互可用 ZFC_LOG_MAX_SIZE 覆盖, 默认 50m)
    local max_size="${ZFC_LOG_MAX_SIZE:-}"
    ask max_size "请输入单个日志文件最大大小 (例如: 10m, 50m, 100m, 1g)" "50m"
    if ! [[ "$max_size" =~ ^[0-9]+[kmgKMG]?$ ]]; then
        log_warning "大小格式无效，使用默认值 50m"
        max_size="50m"
    fi

    # Get max rotated file count (非交互可用 ZFC_LOG_MAX_FILE 覆盖, 默认 5)
    local max_file="${ZFC_LOG_MAX_FILE:-}"
    ask max_file "请输入每个容器保留的日志轮转文件数" "5"
    if ! [[ "$max_file" =~ ^[1-9][0-9]*$ ]]; then
        log_warning "文件数格式无效，使用默认值 5"
        max_file="5"
    fi

    echo
    log_info "配置摘要："
    log_info "  - 日志驱动: json-file (Docker 原生)"
    log_info "  - 单文件最大大小: $max_size"
    log_info "  - 每个容器保留文件数: $max_file"
    log_info "  - 单容器日志总量上限: ${max_size} × ${max_file}"
    echo

    # Parse service names from docker-compose.yml. We only touch services
    # that actually exist in the user's compose file (so external-DB
    # installs where postgres/redis/tdengine were removed still work).
    #
    # Must scope to the `services:` block — volumes/networks/configs
    # share the same 2-space indent, so a naive grep would also pick
    # them up and we'd write bogus logging blocks for volume names.
    local services_in_compose=()
    local svc_name
    while IFS= read -r svc_name; do
        [[ -n "$svc_name" ]] && services_in_compose+=("$svc_name")
    done < <(awk '
        /^[a-zA-Z]/ {
            if ($0 ~ /^services:[[:space:]]*$/) { in_services = 1 }
            else { in_services = 0 }
            next
        }
        in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
            name = $0
            sub(/^  /, "", name)
            sub(/:.*$/, "", name)
            print name
        }
    ' docker-compose.yml 2>/dev/null || true)

    if [[ ${#services_in_compose[@]} -eq 0 ]]; then
        log_warning "未能从 docker-compose.yml 解析出服务列表，跳过日志清理配置"
        return 0
    fi

    log_info "将为 ${#services_in_compose[@]} 个服务配置日志限制: ${services_in_compose[*]}"

    # Write docker-compose.override.yml. Compose auto-loads override files
    # and deep-merges them with docker-compose.yml, so existing service
    # definitions are preserved and only the logging block is added.
    #
    # Safety: docker-compose.override.yml is a well-known auto-loaded
    # user-facing file that may already contain the user's own
    # customizations (ports, env vars, volumes, resource limits, …).
    # We refuse to overwrite anything we did not create ourselves. A
    # marker on the first line distinguishes our managed file from a
    # user-authored one; if the marker is missing we skip the write
    # with manual instructions instead of trampling the user's config.
    local override_file="docker-compose.override.yml"
    local override_marker="# ZFC_MANAGED_LOG_CLEANUP: true"

    if [[ -f "$override_file" ]]; then
        local first_line=""
        first_line=$(head -n 1 "$override_file" 2>/dev/null || echo "")
        if [[ "$first_line" != "$override_marker" ]]; then
            log_warning "检测到已存在的 $override_file 且不是由本脚本生成。"
            log_warning "该文件可能包含您的自定义配置（端口、环境变量、volume、资源限制等），"
            log_warning "为避免覆盖这些设置，已跳过日志清理配置。"
            echo
            log_warning "如需启用日志清理，您有两个选择："
            log_warning ""
            log_warning "  选项 A：手动在 $override_file 中为 ZFC 服务添加 logging 块，例如："
            log_warning "    services:"
            for svc_name in "${services_in_compose[@]}"; do
                log_warning "      ${svc_name}:"
                log_warning "        logging:"
                log_warning "          driver: json-file"
                log_warning "          options:"
                log_warning "            max-size: \"${max_size}\""
                log_warning "            max-file: \"${max_file}\""
            done
            log_warning ""
            log_warning "  选项 B：将您的自定义配置移到其他 compose 文件中，删除 $override_file"
            log_warning "          后重新运行菜单 7，本脚本会创建全新的、受标记保护的 override 文件。"
            return 0
        fi
        # File is managed by us — safe to overwrite. Keep a timestamped
        # backup of the previous script-managed version just in case.
        local backup_file="${override_file}.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "$override_file" "$backup_file" 2>/dev/null; then
            log_info "已备份脚本生成的原 override 文件: $backup_file"
        fi
    fi

    {
        echo "$override_marker"
        echo "# Docker 日志自动清理配置"
        echo "# 由 ZFC 安装脚本自动生成于 $(date)"
        echo "# 此文件会被 docker-compose 自动加载并合并到 docker-compose.yml"
        echo "# 仅影响 ZFC 服务，不修改宿主机 Docker 全局配置"
        echo "#"
        echo "# ⚠ 此文件由 install.sh 管理。第一行的 ZFC_MANAGED_LOG_CLEANUP 标记"
        echo "#   用于识别脚本所有权；删除或修改该标记后，脚本将不再覆盖此文件。"
        echo "#   如果您需要添加自己的 compose 覆盖项，请创建独立的 compose 文件。"
        echo "services:"
        for svc_name in "${services_in_compose[@]}"; do
            echo "  ${svc_name}:"
            echo "    logging:"
            echo "      driver: json-file"
            echo "      options:"
            echo "        max-size: \"${max_size}\""
            echo "        max-file: \"${max_file}\""
        done
    } > "$override_file" 2>/dev/null || {
        log_warning "无法写入 $override_file，跳过日志清理配置"
        return 0
    }

    log_success "$override_file 配置完成"

    # Save a local state file for future reference / reinstall.
    cat > .docker_log_config 2>/dev/null << EOF || true
DOCKER_LOG_MAX_SIZE=$max_size
DOCKER_LOG_MAX_FILE=$max_file
DOCKER_LOG_CONFIGURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    echo
    log_success "=== Docker 日志自动清理配置完成 ==="
    log_info "说明："
    log_info "  • 配置仅影响 ZFC 容器，宿主机全局 Docker 日志行为未变动"
    log_info "  • 对首次创建或 --force-recreate 的容器立即生效"
    log_info "  • 已有容器需要重新创建才能应用新配置"
    log_info "  • 单容器日志总量上限: ${max_size} × ${max_file}"

    # In standalone mode, offer to recreate existing containers.
    if [[ "$mode" == "standalone" ]]; then
        # Determine docker-compose command
        local compose_cmd=""
        if command_exists docker-compose; then
            compose_cmd="docker-compose"
        elif docker compose version >/dev/null 2>&1; then
            compose_cmd="docker compose"
        fi

        if [[ -n "$compose_cmd" ]]; then
            echo
            log_info "要使所有 ZFC 容器使用新日志配置，需要重新创建容器。"
            log_warning "此操作将短暂中断服务（通常几秒钟）。"
            if confirm "是否现在重新创建 ZFC 容器以应用新配置？" "no"; then
                log_info "重新创建容器..."
                if $compose_cmd up -d --force-recreate; then
                    log_success "容器重新创建完成，新日志配置已生效"
                else
                    log_warning "容器重新创建失败，请手动检查"
                fi
            else
                log_info "您可以稍后手动运行以下命令应用新配置："
                log_info "  $compose_cmd up -d --force-recreate"
            fi
        fi
    fi
    echo
    return 0
}

# 完全清理本机安装产物(供 --clean-install): down -v + 删本项目卷 + 删本地配置/prisma。
# 仅清本机 compose 卷与本地配置, 不会自动清外部 PostgreSQL/Redis。镜像 uninstall mode-3。
purge_install_artifacts() {
    log_warning "清空本机安装(--clean-install): 删除容器/数据卷/本地配置 ..."
    if [[ -f "docker-compose.yml" ]]; then
        $DOCKER_COMPOSE_CMD --profile caddy --profile init down -v 2>/dev/null \
            || $DOCKER_COMPOSE_CMD down -v 2>/dev/null || true
    fi
    local project_name
    project_name="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
    if [[ -n "$project_name" ]]; then
        docker volume ls -q --filter "name=${project_name}_" | xargs -r docker volume rm 2>/dev/null || true
        docker ps -aq --filter "label=com.docker.compose.project=${project_name}" | xargs -r docker rm -f 2>/dev/null || true
    fi
    rm -f .env .admin_token docker-compose.yml docker-compose.yml.backup docker-compose.full.yml .docker_log_config Caddyfile .zfc_install_result.json
    if [[ -f "docker-compose.override.yml" ]]; then
        if [[ "$(head -n 1 docker-compose.override.yml 2>/dev/null)" == "# ZFC_MANAGED_LOG_CLEANUP: true" ]]; then
            rm -f docker-compose.override.yml docker-compose.override.yml.backup.* 2>/dev/null || true
        else
            log_warning "保留 docker-compose.override.yml（非脚本生成，可能含您的自定义配置）"
        fi
    fi
    rm -rf prisma
    log_success "本机安装产物已清空"
}

# 停止并删除本 compose 项目的容器以释放端口。即便 docker-compose.yml 已丢失也能按
# project label 接管(compose down 需要文件, label 删除不需要)。
reclaim_stop_project_containers() {
    if [[ -f docker-compose.yml ]]; then
        $DOCKER_COMPOSE_CMD --profile caddy --profile init down 2>/dev/null \
            || $DOCKER_COMPOSE_CMD down 2>/dev/null || true
    fi
    local proj
    proj="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
    if [[ -n "$proj" ]]; then
        docker ps -aq --filter "label=com.docker.compose.project=${proj}" | xargs -r docker rm -f 2>/dev/null || true
    fi
}

# 重装前接管/清理已存在安装(仅在 --force / --clean-install 时动作), 在 check_prerequisites
# 之后、端口预检之前调用, 释放端口避免重试撞 11/16。
# 残留检测口径与 guard_fresh_install / --check 一致: 含「.env/compose 已删但本项目容器还在运行」。
# 健康安装守卫: 用 .admin_token 非空(create_admin_user 末尾才写)作为「装到了建完 admin」的
# 完整性信号(对内置/外部库一视同仁; 不依赖内置 postgres 卷——外部库安装根本没有该卷)。
maybe_reclaim_existing_install() {
    [[ "$ZFC_FORCE" == "1" || "$ZFC_CLEAN_INSTALL" == "1" ]] || return 0

    # 文件或运行中的本项目容器, 任一存在即需接管(修 Codex: 文件已删但容器还在的残留)。
    detect_residual_install || return 0

    # --clean-install: 显式全清, 绕过守卫(purge 按 label 删容器/卷, 不依赖本地文件存在)。
    if [[ "$ZFC_CLEAN_INSTALL" == "1" ]]; then
        purge_install_artifacts
        return 0
    fi

    # --force(非 clean): 疑似完整安装 → 拒绝清库, 引导 --update / --clean-install。
    local admin_present=0
    [[ -s .admin_token ]] && admin_present=1
    if [[ "$admin_present" == "1" ]]; then
        local pgtype="builtin"
        # 尽力读旧 POSTGRES_TYPE 以丰富提示(受限 dotenv 不可用, 这里只 grep 取值)。
        if [[ -f .env ]]; then
            pgtype="$(grep -E '^POSTGRES_TYPE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
            [[ -n "$pgtype" ]] || pgtype="builtin"
        fi
        local extra=""
        [[ "$pgtype" == "external" ]] && extra=" (外部 PostgreSQL 数据不会被清, 但本地配置会被覆盖)"
        ZFC_HINT="保数据升级用 --update; 确需清空重装用 --clean-install"
        die "$EXIT_ALREADY_INSTALLED" "检测到疑似完整安装(.admin_token 已存在)${extra}。--force 会重建内置库并丢数据。保数据升级请用 --update; 确需清空重装请用 --clean-install。"
    fi

    # 半成品安装(无 .admin_token): 放行接管——停旧容器释放端口(内置库卷随后由 init_* 重建)。
    # 即便 compose 文件已丢, 也按 project label 删容器, 否则端口仍被自家容器占用而撞 11。
    log_warning "检测到上次未完成的安装, --force 接管: 停止旧容器以释放端口 ..."
    reclaim_stop_project_containers
}

# 非交互安装: 在产生任何副作用(自动装依赖 / 改时间同步)之前, 先校验所有必填输入,
# 缺失/非法即 die 10。保证 agent 漏传值时 fail-fast 且不动机器。
require_install_env() {
    [[ "$ZFC_NONINTERACTIVE" == "1" ]] || return 0
    local v
    for v in WEB_DOMAIN CONTROLER_DOMAIN ZFC_INSTANCE_ID ZFC_API_KEY; do
        [[ -n "${!v:-}" ]] || die "$EXIT_MISSING_INPUT" "缺少必填项: ${v}; 请用环境变量或 --config 传入"
    done
    [[ "$WEB_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "$EXIT_MISSING_INPUT" "WEB_DOMAIN 格式非法: ${WEB_DOMAIN}"
    [[ "$CONTROLER_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "$EXIT_MISSING_INPUT" "CONTROLER_DOMAIN 格式非法: ${CONTROLER_DOMAIN}"

    # 外部数据库必填项也要在副作用前校验(否则可能先装依赖/改时间才报错)
    if [[ "${POSTGRES_TYPE:-builtin}" == "external" ]]; then
        for v in EXTERNAL_POSTGRES_HOST EXTERNAL_POSTGRES_USER EXTERNAL_POSTGRES_PASSWORD; do
            [[ -n "${!v:-}" ]] || die "$EXIT_MISSING_INPUT" "POSTGRES_TYPE=external 需要 ${v}"
        done
    fi
    if [[ "${REDIS_TYPE:-builtin}" == "external" ]]; then
        [[ -n "${EXTERNAL_REDIS_HOST:-}" ]] || die "$EXIT_MISSING_INPUT" "REDIS_TYPE=external 需要 EXTERNAL_REDIS_HOST"
    fi
    if [[ "${TDENGINE_TYPE:-builtin}" == "external" ]]; then
        for v in EXTERNAL_TDENGINE_HOST EXTERNAL_TDENGINE_PASSWORD; do
            [[ -n "${!v:-}" ]] || die "$EXIT_MISSING_INPUT" "TDENGINE_TYPE=external 需要 ${v}"
        done
    fi
    # Caddy 邮箱(可选)若提供则校验格式, 避免到 Caddyfile 才坏
    if [[ "${CADDY_ENABLED:-true}" == "true" && -n "${CADDY_EMAIL:-}" \
          && ! "$CADDY_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        die "$EXIT_MISSING_INPUT" "CADDY_EMAIL 邮箱格式非法: ${CADDY_EMAIL}"
    fi
}

# Main installation process
main_install() {
    echo
    log_info "开始 ZFC 安装流程..."
    echo

    # 非交互必填校验先行(避免缺值时仍自动装依赖/改时间)
    require_install_env

    # Check prerequisites
    check_prerequisites

    # --force / --clean-install: 接管或清空已存在安装(用旧 compose 释放端口), 必须在端口预检之前。
    # 健康安装守卫: 疑似完整安装 + 仅 --force → die 16 引导 --update/--clean-install。
    maybe_reclaim_existing_install

    # Setup time synchronization
    setup_time_sync

    # Check domain and license preparation
    check_preparation

    # Get user input
    get_user_input

    # Runtime preflight (conditional ports + graded DNS) — after config resolved
    preflight_runtime

    # Generate configuration
    generate_config

    # Generate docker-compose configuration
    generate_docker_compose

    # Create environment file
    create_env_file

    # Generate Caddyfile
    generate_caddyfile

    # Setup Docker log auto cleanup (best-effort; must run after
    # generate_docker_compose since it reads docker-compose.yml to know
    # which services exist). Wrapped with '|| true' so an unexpected
    # failure never aborts the main install under set -e.
    setup_docker_log_cleanup || true

    # Initialize database
    init_database

    # 把 .env 从 :latest 这类活动指针钉到具体 release。必须在 init_database 之后
    # (镜像已拉到本地、schema bundle 可解), start_services 之前。
    # 钉死后 docker compose up -d 变成幂等操作 —— 不会再有人一句 compose up 就把生产
    # 悄悄升到当天 latest 而没跑任何迁移。
    if resolve_deploy_version "${ZFC_UPDATE_CHANNEL:-latest}"; then
        commit_pinned_env "${ZFC_UPDATE_CHANNEL:-latest}" ".env.pre-install" || \
            log_warning ".env 钉版本写入失败, 保留原镜像引用(不影响本次安装)"
    else
        log_warning "无法解析部署版本, .env 保留原镜像引用"
    fi

    # Create admin user
    create_admin_user
    
    # Start services
    start_services
    
    # Setup Caddy
    setup_caddy
    
    # Show final information
    show_final_info

    log_success "安装完成！"

    # agent 模式: 输出结构化成功结果(供 AI agent 解析)
    if [[ "$ZFC_OUTPUT_JSON" == "1" ]]; then
        emit_json_result
    fi
}

# 安装前幂等守卫: 仅检测「本目录的 ZFC 安装」(cwd 的 .env/docker-compose.yml,
# 或本项目名下运行的容器), 不会误伤同机上其它 docker compose 项目。
# 非交互无 ZFC_FORCE → die 16; 交互 → 二次确认。
guard_fresh_install() {
    local existing=""
    if [[ -f docker-compose.yml || -f .env ]]; then
        existing="docker-compose.yml / .env"
    else
        # 仅匹配本目录对应的 compose 项目名(compose 默认以 cwd 目录名为项目名)
        local proj
        proj="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
        if [[ -n "$proj" ]] && docker ps --filter "label=com.docker.compose.project=${proj}" --format '{{.Names}}' 2>/dev/null | grep -q .; then
            existing="运行中的 ZFC 服务(项目 ${proj})"
        fi
    fi
    [[ -z "$existing" ]] && return 0

    if [[ "$ZFC_FORCE" == "1" ]]; then
        log_warning "检测到已存在安装(${existing}); 已指定 --force/ZFC_FORCE, 继续覆盖。"
        return 0
    fi
    if [[ "$ZFC_NONINTERACTIVE" == "1" ]]; then
        die "$EXIT_ALREADY_INSTALLED" "检测到已存在安装(${existing}); 如需重装请加 --force(或 ZFC_FORCE=1), 如需升级请用 --update。"
    fi
    if confirm "检测到已存在安装(${existing})。继续将覆盖现有配置, 是否继续?" "no"; then
        return 0
    fi
    log_info "已取消, 未做改动。如需升级请运行: bash install.sh --update"
    exit 0
}

# ── 入口: 版本 / 帮助 / 参数解析 / 派发 ───────────────────────────────────────
ZFC_VERSION="2.0.0-agent"

print_version() {
    echo "ZFC install.sh ${ZFC_VERSION}"
}

print_help() {
    cat <<'EOF'
ZFC 面板安装器 / ZFC panel installer

用法 / Usage:
  bash install.sh [动作 ACTION] [选项 OPTIONS]
  bash <(curl -sL https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/zf_install_selfhost.sh) --install -y --json

无参数且在终端中 → 进入交互式菜单(向后兼容)。
No args in a TTY  → interactive menu (backward compatible).

动作 / Actions:
  --install         全新安装 / fresh install
  --update          更新镜像(保留数据) / update images, keep data
  --uninstall       卸载 / uninstall (需 ZFC_UNINSTALL_MODE)
  --show-token      打印管理员 token / print admin token
  --refresh-token   刷新管理员 token / refresh admin token
  --to <version>    --update 的一次性目标版本(如 --to 1.1.70); 低于当前即回滚。
                    不写回 ZFC_UPDATE_CHANNEL。交互菜单: 1=latest / 2=.env 版本 /
                    3=手动; 回车默认=沿用当前 ZFC_UPDATE_CHANNEL(与 -y 一致)。
                    非交互省略 --to 时按 ZFC_UPDATE_CHANNEL(缺省 latest)。
  --pack            打包迁移数据 / pack migration data
  --restore         恢复迁移数据 / restore (需 ZFC_RESTORE_PACKAGE)
  --check           只做预检, 不落地 / preflight only, no changes
  --doctor          诊断运行中/损坏的部署(只读 JSON) / diagnose a running/broken deploy (read-only JSON)

选项 / Options:
  -y, --yes, --non-interactive   非交互模式 / non-interactive (== ZFC_NONINTERACTIVE=1)
  --json                         机器可读 JSON 输出 / machine-readable JSON
  --config FILE                  从文件加载 env(env 优先) / load env from file (env wins)
  --auto-install-docker[=0|1]    自动安装缺失依赖 / auto-install missing deps (默认 1)
  --force                        重建内置库的重装(疑似完整安装会被守卫挡下) / rebuild reinstall (guarded)
  --clean-install                一键清空重装(down -v + 清本机卷/配置, 隐含 --force) / wipe + reinstall
  --detach                       后台运行长动作并立即返回 pid/log(隐含 -y) / run in background, return pid/log
  --version                      打印版本 / print version
  -h, --help                     打印本帮助 / print this help

安装必填环境变量 / Required env for --install:
  WEB_DOMAIN          前端域名 / frontend domain (e.g. forward.example.com)
  CONTROLER_DOMAIN    控制器域名 / controller domain (e.g. zf-controler.example.com)
  ZFC_INSTANCE_ID     授权 ID / license instance id
  ZFC_API_KEY         API 密钥 / license api key

常用可选环境变量 / Common optional env:
  CADDY_ENABLED=true|false   是否用 Caddy 自动 HTTPS(默认 true)
  CADDY_EMAIL                ACME 邮箱(可选, 留空则省略, 仍自动签证)
  POSTGRES_TYPE / REDIS_TYPE / TDENGINE_TYPE   builtin|external|disabled(默认 builtin)
  DOCKER_REGISTRY (默认 hub.covm.net)  IMAGE_TAG (默认 latest)
  ZFC_AUTO_INSTALL_DOCKER=0  关闭依赖自动安装
  ZFC_VALIDATE_LICENSE=0     跳过 license 在线校验
  ZFC_ALLOW_SCHEMA_DOWNGRADE=1          显式允许 schema 降级(危险)
  ZFC_EXTERNAL_DB_BACKUP_CONFIRMED=1    确认外部 PostgreSQL 已完成备份
  ZFC_BACKUP_FULL=1                     强制完整 pg_dump(默认排除诊断/审计表数据)
  ZFC_BACKUP_AUTOCLEAN=0                关闭 schema_backup/ 历史备份自动清理
  ZFC_BACKUP_RETAIN_COUNT=N             下限: 始终保留最近 N 份(默认 5; =0 取消下限保护, 可能删光全部备份)
  ZFC_BACKUP_RETAIN_DAYS=D              软清理: 超出 N 份且超过 D 天才删(默认 30; =0 纯按数量)
  ZFC_BACKUP_MAX_COUNT=M                硬上限: 超过 M 份的旧备份无视年龄直接删(默认 0=无上限)
  ZFC_CLEAN_INSTALL=1                   等价 --clean-install(清空重装, 隐含 --force)
  ZFC_DETACH=1                          等价 --detach(后台运行长动作)
  ZFC_LOG_FILE=PATH                     install/update 日志文件(默认 ./zfc-install.log)
  ZFC_ALLOW_SCHEMA_FINGERPRINT_MISMATCH=1  仅 additive/index-only schema delta 时放行二进制启动(危险)

退出码 / Exit codes:
  0 成功 / 10 缺必填输入 / 11 端口冲突 / 12 依赖不可用 / 13 license 无效
  14 DB 连接失败 / 15 admin 创建失败 / 16 已存在安装(需 --force) / 17 配置文件非法
  18 schema 迁移失败/未完成 / 19 更新后启动门禁失败 / 20 镜像拉取失败

后台 / 断连后重试 / Detach & resume:
  --detach 把 install/update/restore 放后台并立即返回 {"status":"detached","pid":..,"log":..,"result_file":..}
  断连用 --detach; 重装用 --force(重建内置库)或 --clean-install(清空); 保数据升级用 --update。
  --clean-install 只清本机 compose 卷与本地配置, 不会自动清外部 PostgreSQL/Redis。
  诊断更新失败用 --doctor(读 schema.delta_class / db_status 决定是否可设 fingerprint override)。

完整 AI agent 安装契约 / Full AI-agent contract:
  仓库 / repo: AGENT_INSTALL.md
  在线 / online: https://www.zeroforwarder.com/llms-install.txt
EOF
}

# 解析命令行参数 → 设置 ZFC_ACTION 与各模式全局。
# 优先级: CLI flag > 真实 env > --config 文件 > 内置默认。
# 预扫描同时识别 --config 路径 + 影响「错误如何输出」的模式 flag(--json / 非交互),
# 这样连 --config 自身的解析错误也能按 --json 输出结构化 JSON。
parse_args() {
    # 1) 完整预扫描(顺序无关): 先记录 action / --json / 非交互 / --config 路径,
    #    再统一校验与加载 config。这样无论 flag 顺序如何, 早期错误都能按 --json
    #    输出结构化 JSON, 且 error JSON 的 action 字段正确。--help/--version 即时生效。
    local a config_pending=0 config_missing=0 to_pending=0 to_missing=0
    local -a flag_locked=()
    for a in "$@"; do
        if [[ "$config_pending" == "1" ]]; then
            config_pending=0
            case "$a" in
                -*) config_missing=1 ;;          # 下一个是 flag → 缺文件名(继续扫描该 flag)
                *)  ZFC_CONFIG_FILE="$a"; continue ;;
            esac
        fi
        if [[ "$to_pending" == "1" ]]; then
            to_pending=0
            case "$a" in
                -*) to_missing=1 ;;              # 下一个是 flag → 缺版本号(继续扫描该 flag)
                *)  ZFC_UPDATE_TO="$a"; continue ;;
            esac
        fi
        case "$a" in
            --install)        ZFC_ACTION="install" ;;
            --update)         ZFC_ACTION="update" ;;
            --uninstall)      ZFC_ACTION="uninstall" ;;
            --show-token)     ZFC_ACTION="show-token" ;;
            --refresh-token)  ZFC_ACTION="refresh-token" ;;
            --pack)           ZFC_ACTION="pack" ;;
            --restore)        ZFC_ACTION="restore" ;;
            --check)          ZFC_ACTION="check" ;;
            --doctor)         ZFC_ACTION="doctor" ;;
            --to)             to_pending=1 ;;
            --to=*)           ZFC_UPDATE_TO="${a#*=}" ;;
            --config)         config_pending=1 ;;
            --config=*)       ZFC_CONFIG_FILE="${a#*=}"
                              [[ -n "$ZFC_CONFIG_FILE" ]] || config_missing=1 ;;
            --json)           ZFC_OUTPUT_JSON=1; flag_locked+=("ZFC_OUTPUT_JSON") ;;
            -y|--yes|--non-interactive) ZFC_NONINTERACTIVE=1; flag_locked+=("ZFC_NONINTERACTIVE") ;;
            --version)        print_version; exit 0 ;;
            -h|--help)        print_help; exit 0 ;;
        esac
    done
    [[ "$config_pending" == "1" ]] && config_missing=1   # --config 是最后一个参数
    [[ "$to_pending" == "1" ]] && to_missing=1           # --to 是最后一个参数

    # flag 设定的模式键在加载文件时受保护(flag 优先于文件, 即使文件中途报错也保留)
    ZFC_FLAG_LOCKED_KEYS=" ${flag_locked[*]} "

    # 现在 --json / action 已知 → 校验 config 缺参 / 加载 config 的错误都能正确输出
    [[ "$config_missing" == "1" ]] && die "$EXIT_BAD_CONFIG" "缺少 --config 的文件名"
    [[ "$to_missing" == "1" ]] && die "$EXIT_BAD_CONFIG" "缺少 --to 的版本号 (如 --to 1.1.70)"
    if [[ -n "$ZFC_UPDATE_TO" ]] && \
       ! [[ "$ZFC_UPDATE_TO" =~ $ZFC_VERSION_TAG_RE ]]; then
        die "$EXIT_BAD_CONFIG" "--to 版本号非法: $ZFC_UPDATE_TO (需形如 1.1.70)"
    fi
    if [[ -n "$ZFC_CONFIG_FILE" ]]; then
        load_config_file "$ZFC_CONFIG_FILE"
    fi

    # 2) 主循环: CLI flag 覆盖文件/env(显式命令行优先级最高), 并报告未知参数。
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)        ZFC_ACTION="install" ;;
            --update)         ZFC_ACTION="update" ;;
            --uninstall)      ZFC_ACTION="uninstall" ;;
            --show-token)     ZFC_ACTION="show-token" ;;
            --refresh-token)  ZFC_ACTION="refresh-token" ;;
            --pack)           ZFC_ACTION="pack" ;;
            --restore)        ZFC_ACTION="restore" ;;
            --check)          ZFC_ACTION="check" ;;
            --doctor)         ZFC_ACTION="doctor" ;;
            --to)             shift; ZFC_UPDATE_TO="${1:-}" ;;
            --to=*)           ZFC_UPDATE_TO="${1#*=}" ;;
            -y|--yes|--non-interactive) ZFC_NONINTERACTIVE=1 ;;
            --json)           ZFC_OUTPUT_JSON=1 ;;
            --force)          ZFC_FORCE=1 ;;
            --clean-install)  ZFC_CLEAN_INSTALL=1; ZFC_FORCE=1 ;;   # 隐含 --force
            --detach)         ZFC_DETACH=1; ZFC_NONINTERACTIVE=1 ;; # 后台无法交互
            --auto-install-docker)     ZFC_AUTO_INSTALL_DOCKER=1 ;;
            --auto-install-docker=*)   ZFC_AUTO_INSTALL_DOCKER="${1#*=}" ;;
            --config)         shift ;;   # 路径已在预扫描处理
            --config=*)       ;;          # 同上
            --version)        print_version; exit 0 ;;
            -h|--help)        print_help; exit 0 ;;
            *)                die "$EXIT_BAD_CONFIG" "未知参数: $1 (用 --help 查看用法)" ;;
        esac
        shift
    done

    # 非 tty 时, 对显式动作自动进入非交互(无法可靠提问)
    if [[ "$ZFC_NONINTERACTIVE" != "1" && ! -t 0 && -n "$ZFC_ACTION" && "$ZFC_ACTION" != "" ]]; then
        ZFC_NONINTERACTIVE=1
    fi
}

# 现有交互式菜单(逐字保留, 仅从 main 抽出)
run_menu() {
    while true; do
        show_menu
        read -p "请选择 [1-9]: " choice
        echo

        case $choice in
            1)
                main_install
                break
                ;;
            2)
                update_images
                read -p "按任意键继续..." -n 1
                echo
                ;;
            3)
                uninstall_system
                break
                ;;
            4)
                show_admin_token
                read -p "按任意键继续..." -n 1
                echo
                ;;
            5)
                refresh_admin_token
                read -p "按任意键继续..." -n 1
                echo
                ;;
            6)
                pack_migration_data
                read -p "按任意键继续..." -n 1
                echo
                ;;
            7)
                restore_migration_data
                read -p "按任意键继续..." -n 1
                echo
                ;;
            8)
                setup_docker_log_cleanup standalone
                read -p "按任意键继续..." -n 1
                echo
                ;;
            9)
                log_info "退出脚本"
                exit 0
                ;;
            *)
                log_error "无效选择，请输入 1-9"
                read -p "按任意键继续..." -n 1
                echo
                ;;
        esac
    done
}

# 非 install/check 动作成功后, agent 模式补一条通用成功 JSON(stdout + 结果文件)。
agent_action_ok() {
    if [[ "$ZFC_OUTPUT_JSON" == "1" && "$ZFC_RESULT_EMITTED" == "0" ]]; then
        ZFC_RESULT_EMITTED=1
        local json
        if [[ -n "$ADMIN_TOKEN" ]]; then
            json=$(printf '{"status":"success","action":"%s","admin_token":"%s"}' \
                "$(json_escape "$ZFC_ACTION")" "$(json_escape "$ADMIN_TOKEN")")
        else
            json=$(printf '{"status":"success","action":"%s"}' "$(json_escape "$ZFC_ACTION")")
        fi
        ( umask 077; printf '%s\n' "$json" > "$ZFC_RESULT_FILE" 2>/dev/null ) || true
        chmod 600 "$ZFC_RESULT_FILE" 2>/dev/null || true
        printf '%s\n' "$json"
    fi
}

# 仅预检, 不落地。按 env 解析配置, report 模式跑全部检查, 输出 JSON 证据。
run_preflight_check() {
    ZFC_NONINTERACTIVE=1
    PREFLIGHT_MODE="report"
    PREFLIGHT_FATAL=0
    PREFLIGHT_FIRST_CODE=0
    log_info "=== 预检 (--check): 不会做任何更改 ==="

    # 解析安装配置(缺必填 → die 10)
    ask WEB_DOMAIN "前端网页域名" "" '^[a-zA-Z0-9.-]+$' 1
    ask CONTROLER_DOMAIN "控制器网页域名" "" '^[a-zA-Z0-9.-]+$' 1
    prompt_credential ZFC_INSTANCE_ID "ZFC_INSTANCE_ID (授权ID)"
    prompt_credential ZFC_API_KEY "ZFC_API_KEY (API密钥)"
    configure_postgres
    configure_redis
    configure_tdengine
    configure_caddy

    # 依赖(只报告) + docker 版本/资源(warning) + 端口/DNS(report) + license(report)
    ensure_dependencies probe || true
    check_docker_versions || true
    check_system_resources || true

    # 残留安装 = 阻断状态(非软 warning): 未给 --force/--clean-install 时, --install 会被
    # guard_fresh_install 以 exit 16 挡下。所以 --check 必须 ready:false + code 16 + hint,
    # 引导 agent 先加 --force/--clean-install, 否则推荐流程会进入必失败安装。
    if detect_residual_install; then
        if [[ "$ZFC_FORCE" == "1" || "$ZFC_CLEAN_INSTALL" == "1" ]]; then
            log_info "检测到已存在安装, 但已指定 --force/--clean-install, 安装时将接管/清空。"
        else
            ZFC_HINT="重装加 --force(重建内置库)或 --clean-install(清空); 保数据升级用 --update"
            preflight_fail "$EXIT_ALREADY_INSTALLED" "检测到已存在 ZFC 安装(.env/compose 或运行中容器)。直接 --install 会被挡下: 重装请加 --force/--clean-install, 升级请用 --update。"
        fi
    fi

    preflight_ports
    preflight_dns
    if [[ "$ZFC_VALIDATE_LICENSE" == "1" ]]; then
        if ! validate_license_online "$ZFC_INSTANCE_ID" "$ZFC_API_KEY"; then
            preflight_fail "$EXIT_LICENSE_INVALID" "授权信息无效(授权服务器拒绝)"
        fi
    fi

    local ready="true"
    [[ $PREFLIGHT_FATAL -gt 0 ]] && ready="false"
    # 先打印人类日志, 再输出 JSON(保证 JSON 是 stdout 最后一行)
    if [[ "$ready" == "true" ]]; then
        log_success "预检通过, 可以安装。"
    else
        log_error "预检发现 ${PREFLIGHT_FATAL} 个致命问题, 请先解决后再安装。"
    fi
    if [[ "$ZFC_OUTPUT_JSON" == "1" ]]; then
        ZFC_RESULT_EMITTED=1
        local cjson hint_json=""
        [[ -n "$ZFC_HINT" ]] && hint_json=$(printf ',"hint":"%s"' "$(json_escape "$ZFC_HINT")")
        cjson=$(printf '{"status":"%s","action":"check","ready":%s,"fatal":%s,"warnings":[%s]%s}' \
            "$([[ "$ready" == "true" ]] && echo ok || echo error)" "$ready" "$PREFLIGHT_FATAL" "$ZFC_WARNINGS_JSON" "$hint_json")
        ( umask 077; printf '%s\n' "$cjson" > "$ZFC_RESULT_FILE" 2>/dev/null ) || true
        chmod 600 "$ZFC_RESULT_FILE" 2>/dev/null || true
        printf '%s\n' "$cjson"
    fi
    [[ "$ready" == "true" ]] && return 0
    # 以首个致命问题的契约退出码退出(10/11/13/...), 而非泛化 1
    local rc="$PREFLIGHT_FIRST_CODE"
    [[ "$rc" -ne 0 ]] || rc=1
    exit "$rc"
}

# 累积 doctor findings(逗号分隔的 JSON 对象)。
DOCTOR_FINDINGS=""
DOCTOR_OVERALL="ok"
# 追加一条 finding, 并按 severity 提升整体状态(error→broken, warning→degraded; 只升不降)。
doctor_add_finding() {  # id severity detail hint
    local obj
    obj=$(printf '{"id":"%s","severity":"%s","detail":"%s","hint":"%s"}' \
        "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$4")")
    [[ -z "$DOCTOR_FINDINGS" ]] && DOCTOR_FINDINGS="$obj" || DOCTOR_FINDINGS="${DOCTOR_FINDINGS},${obj}"
    if [[ "$2" == "error" ]]; then
        DOCTOR_OVERALL="broken"
    elif [[ "$2" == "warning" && "$DOCTOR_OVERALL" == "ok" ]]; then
        DOCTOR_OVERALL="degraded"
    fi
}

# 诊断一个运行中/损坏的部署(只读, 绝不改库/配置)。输出结构化 JSON 供 LLM 自愈。
# 关键: schema 指纹不匹配时不靠「猜」, 而是用只读 prisma migrate diff 机械分类 additive/destructive。
run_doctor() {
    ZFC_NONINTERACTIVE=1
    DOCTOR_FINDINGS=""
    DOCTOR_OVERALL="ok"
    ZFC_WARNINGS_JSON=""
    log_info "=== 诊断 (--doctor): 只读, 不做任何更改 ==="

    # --- docker / compose 版本 ---
    local docker_ver compose_flavor="none" compose_ver=""
    docker_ver="$(docker_server_version)"; [[ -n "$docker_ver" ]] || docker_ver="unknown"
    if detect_compose_cmd; then
        compose_flavor="$DOCKER_COMPOSE_CMD"
        compose_ver="$($DOCKER_COMPOSE_CMD version --short 2>/dev/null || true)"
    else
        doctor_add_finding "compose_missing" "error" "docker compose 不可用" "安装 docker 与 docker compose v2 插件"
    fi
    check_docker_versions || true
    local fid fsev fdet fhint
    while IFS='|' read -r fid fsev fdet fhint; do
        [[ -n "$fid" ]] && doctor_add_finding "$fid" "$fsev" "$fdet" "$fhint"
    done < <(printf '%b' "$DOCKER_VERSION_FINDINGS")

    # --- 资源 ---
    check_system_resources || true
    [[ "$RES_MEM_MB" -gt 0 && "$RES_MEM_MB" -lt 1800 ]] && doctor_add_finding "mem_low" "warning" "内存 ~${RES_MEM_MB}MB < 2GB" "扩容或设 TDENGINE_TYPE=disabled"
    [[ "$RES_DISK_MB" -gt 0 && "$RES_DISK_MB" -lt 40000 ]] && doctor_add_finding "disk_low" "warning" "磁盘可用 ~$((RES_DISK_MB/1024))GB < 40GB" "清理或扩容磁盘"

    local installed="false"
    [[ -f .env && -f docker-compose.yml ]] && installed="true"

    # 整体状态由 doctor_add_finding 按 severity 驱动(DOCTOR_OVERALL), 这里不再手工设。
    local services_json="[]"
    local schema_json='{}'

    if [[ "$installed" != "true" ]]; then
        doctor_add_finding "not_installed" "info" "未检测到安装(.env/docker-compose.yml 缺失)" "如需安装请用 --install"
    else
        source .env 2>/dev/null || true

        # --- 容器状态 ---  (整体状态由 finding severity 驱动: 核心服务 down=error→broken)
        local potential=("postgres" "redis" "tdengine" "zf-web" "zf-controler" "rrd-service" "caddy")
        local svc cid status exitcode item sjson="" logs
        for svc in "${potential[@]}"; do
            cid=$($DOCKER_COMPOSE_CMD ps -q "$svc" 2>/dev/null | head -1)
            [[ -n "$cid" ]] || continue
            status=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)
            exitcode=$(docker inspect --format '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 0)
            [[ "$exitcode" =~ ^[0-9]+$ ]] || exitcode=0
            item=$(printf '{"service":"%s","status":"%s","exit_code":%s}' \
                "$(json_escape "$svc")" "$(json_escape "${status:-unknown}")" "$exitcode")
            [[ -z "$sjson" ]] && sjson="$item" || sjson="${sjson},${item}"
            if [[ "$status" != "running" ]]; then
                if [[ "$svc" == "zf-web" || "$svc" == "zf-controler" ]]; then
                    logs=$(docker logs --tail 20 "$cid" 2>&1 | tr '\n' ' ' | tr -d '\r' | cut -c1-600)
                    doctor_add_finding "svc_${svc}_down" "error" "$svc 状态=${status} exit=${exitcode}; 末尾日志: ${logs}" "结合 schema 诊断或 docker logs ${svc} 排查"
                else
                    doctor_add_finding "svc_${svc}_down" "warning" "$svc 状态=${status} exit=${exitcode}" "docker logs ${svc}"
                fi
            fi
        done
        services_json="[${sjson}]"

        # --- schema 账本 + 指纹 + delta 分类(只读) ---
        local pgtype="${POSTGRES_TYPE:-builtin}" db_url psql_url network_arg=""
        if [[ "$pgtype" == "builtin" ]]; then
            local net; net=$(get_compose_network 2>/dev/null || true)
            db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/zfc?schema=public"
            [[ -n "$net" ]] && network_arg="--network $net"
        else
            db_url="postgresql://${EXTERNAL_POSTGRES_USER}:${EXTERNAL_POSTGRES_PASSWORD}@${EXTERNAL_POSTGRES_HOST}:${EXTERNAL_POSTGRES_PORT}/${EXTERNAL_POSTGRES_DB}?schema=public"
        fi
        psql_url="${db_url%%\?*}"

        local row db_status="" db_release="" db_sha=""
        row=$(docker run --rm $network_arg postgres:15-alpine \
            psql "$psql_url" -At -F '|' -c \
            'SELECT "status","releaseVersion","schemaArtifactSha256" FROM "ZfcSchemaState" WHERE "id"=1' 2>/dev/null || true)
        [[ -n "$row" ]] && IFS='|' read -r db_status db_release db_sha <<<"$row"

        # 目标(镜像内置)指纹
        local web_img="${ZF_WEB_IMAGE:-}" ctl_img="${ZF_CONTROLER_IMAGE:-}"
        [[ -n "$web_img" ]] || web_img=$($DOCKER_COMPOSE_CMD config --images 2>/dev/null | grep '/zf-web:' | head -1 || true)
        [[ -n "$ctl_img" ]] || ctl_img=$($DOCKER_COMPOSE_CMD config --images 2>/dev/null | grep '/zf-controler:' | head -1 || true)
        local target_sha="" target_release="" delta_class="unknown" destructive_ops=""
        if [[ -n "$web_img" && -n "$ctl_img" ]] && prepare_schema_bundle "$web_img" "$ctl_img" >/dev/null 2>&1; then
            target_sha="$EXPECTED_SCHEMA_SHA256"; target_release="$TARGET_SCHEMA_RELEASE"
        fi

        if [[ -z "$db_sha" ]]; then
            doctor_add_finding "schema_ledger_missing" "warning" "ZfcSchemaState 缺失/不可读(DB 未就绪或 legacy)" "用当前 install.sh 跑 --update 重新迁移并写账本"
        elif [[ "$db_status" != "stable" ]]; then
            delta_class="incomplete"
            doctor_add_finding "schema_incomplete" "error" "上次迁移未完成(status=${db_status})" "从最近 schema_backup/db_backup_*.sql 恢复后重跑 --update; 勿设 fingerprint override"
        elif [[ -n "$target_sha" && "$db_sha" == "$target_sha" ]]; then
            delta_class="match"
        elif [[ -n "$target_sha" && "$db_sha" != "$target_sha" ]]; then
            # 只读 diff: 从 live DB 到目标 datamodel, 扫描破坏性算子分类。
            local diff_sql=""
            if [[ -n "${ZFC_PRISMA_IMAGE:-}" && -n "$SCHEMA_BUNDLE_ROOT" && -f "$SCHEMA_BUNDLE_ROOT/zf-web/schema.prisma" ]]; then
                diff_sql=$(docker run --rm $network_arg \
                    -v "$SCHEMA_BUNDLE_ROOT/zf-web:/app/prisma:ro" -w /app \
                    -e DATABASE_URL="$db_url" \
                    "$ZFC_PRISMA_IMAGE" sh -c '
                        sed "s/provider = \"cargo prisma\"/provider = \"prisma-client-js\"/" prisma/schema.prisma > /tmp/s.prisma &&
                        sed -i "s|output.*|// output removed|" /tmp/s.prisma &&
                        npx prisma migrate diff --from-url "$DATABASE_URL" --to-schema-datamodel /tmp/s.prisma --script 2>/dev/null
                    ' 2>/dev/null || true)
            fi
            if [[ -n "$diff_sql" ]]; then
                if printf '%s' "$diff_sql" | grep -Eiq 'DROP TABLE|DROP COLUMN|ALTER[[:space:]].*[[:space:]]TYPE[[:space:]]|RENAME '; then
                    delta_class="destructive"
                    destructive_ops=$(printf '%s' "$diff_sql" | grep -Eio 'DROP TABLE|DROP COLUMN|RENAME' | sort -u | tr '\n' ';')
                    doctor_add_finding "schema_mismatch_destructive" "error" "DB 指纹(${db_sha:0:12})与目标(${target_sha:0:12})不匹配且含破坏性变更(${destructive_ops})" "重跑 --update(迁移并重盖账本); 切勿设 ZFC_ALLOW_SCHEMA_FINGERPRINT_MISMATCH"
                else
                    delta_class="additive"
                    doctor_add_finding "schema_mismatch_additive" "warning" "DB 指纹(${db_sha:0:12})与目标(${target_sha:0:12})不匹配, delta 为 additive/index-only" "可设 ZFC_ALLOW_SCHEMA_FINGERPRINT_MISMATCH=1 重启容器(仅 additive 安全), 或重跑 --update"
                fi
            else
                delta_class="unknown"
                doctor_add_finding "schema_mismatch_unknown" "warning" "DB 指纹与目标不匹配, 但无法计算 delta(prisma 镜像/网络不可用?)" "重跑 --update; 仅在人工确认 delta 为 additive 后才设 fingerprint override"
            fi
        fi

        schema_json=$(printf '{"db_fingerprint":"%s","binary_fingerprint":"%s","db_status":"%s","db_release":"%s","target_release":"%s","delta_class":"%s","destructive_ops":"%s"}' \
            "$(json_escape "$db_sha")" "$(json_escape "$target_sha")" "$(json_escape "$db_status")" \
            "$(json_escape "$db_release")" "$(json_escape "$target_release")" "$(json_escape "$delta_class")" \
            "$(json_escape "$destructive_ops")")

        # 清理 prepare_schema_bundle 临时目录(zfc_on_exit 也会兜底)
        [[ -n "$SCHEMA_BUNDLE_ROOT" && -d "$SCHEMA_BUNDLE_ROOT" ]] && rm -rf "$SCHEMA_BUNDLE_ROOT"
        SCHEMA_BUNDLE_ROOT=""
    fi

    local docker_json
    docker_json=$(printf '{"version":"%s","compose":"%s","compose_version":"%s"}' \
        "$(json_escape "$docker_ver")" "$(json_escape "$compose_flavor")" "$(json_escape "$compose_ver")")
    local resources_json
    resources_json=$(printf '{"mem_mb":%s,"disk_mb":%s}' "${RES_MEM_MB:-0}" "${RES_DISK_MB:-0}")

    ZFC_RESULT_EMITTED=1
    local djson
    djson=$(printf '{"status":"%s","action":"doctor","installed":%s,"docker":%s,"services":%s,"schema":%s,"resources":%s,"warnings":[%s],"findings":[%s]}' \
        "$(json_escape "$DOCTOR_OVERALL")" "$installed" "$docker_json" "$services_json" "$schema_json" "$resources_json" \
        "$ZFC_WARNINGS_JSON" "$DOCTOR_FINDINGS")
    ( umask 077; printf '%s\n' "$djson" > "$ZFC_RESULT_FILE" 2>/dev/null ) || true
    chmod 600 "$ZFC_RESULT_FILE" 2>/dev/null || true
    log_info "诊断完成: status=${DOCTOR_OVERALL}"
    printf '%s\n' "$djson"
    return 0
}

# 派发选定动作(非交互/带参上下文)
dispatch_action() {
    case "$ZFC_ACTION" in
        install)        guard_fresh_install; main_install ;;
        check)          run_preflight_check ;;
        doctor)         run_doctor ;;
        # update: 显式判失败 → 避免 set -e 把按阶段 return 落回 generic exit 1。
        # update_images 在 agent 模式已用 die_or_return 按阶段 die(18/19/20/14/...);
        # 这里兜底非 agent/tty 路径, 保证非 0 退出而非静默成功。
        update)         if ! update_images; then die "${EXIT_SCHEMA_MIGRATION}" "更新失败(详见上方日志)"; fi; agent_action_ok ;;
        uninstall)      uninstall_system;       agent_action_ok ;;
        show-token)     show_admin_token;       agent_action_ok ;;
        refresh-token)  refresh_admin_token;    agent_action_ok ;;
        pack)           pack_migration_data;    agent_action_ok ;;
        restore)        restore_migration_data; agent_action_ok ;;
        *)              die "$EXIT_BAD_CONFIG" "未知动作: ${ZFC_ACTION}" ;;
    esac
}

# 后台化(--detach / ZFC_DETACH): 仅 install/update/restore 适用。非后台子进程(ZFC_DETACHED!=1)
# 且 ZFC_DETACH=1 时, 用 setsid/nohup 重启自身到后台、输出重定向到日志文件, 立即打印 detached
# JSON(含 pid/log/result_file)并退出 0。LLM 随后轮询 result_file / tail 日志。
maybe_detach() {
    [[ "$ZFC_DETACH" == "1" && "$ZFC_DETACHED" != "1" ]] || return 0
    case "$ZFC_ACTION" in
        install|update|restore) ;;
        *) die "$EXIT_BAD_CONFIG" "--detach 仅支持 install/update/restore 动作" ;;
    esac

    # 后台子进程要重跑本脚本。若经 `bash <(curl ...)` 运行, $0 是 /dev/fd/N 这类一次性 fd,
    # 无法重复执行(管道已被读尽), 必须先把脚本固化到临时文件; 子进程退出时自清(见 zfc_on_exit)。
    local self="$0" tmp_self=""
    if [[ -f "$self" && -r "$self" && "$self" != /dev/fd/* && "$self" != /proc/*/fd/* ]]; then
        :   # 常规可重读文件(本地 install.sh)→ 直接重跑
    else
        tmp_self="$(mktemp "${TMPDIR:-/tmp}/zfc-install.XXXXXX.sh" 2>/dev/null)" \
            || die "$EXIT_DEP_UNAVAILABLE" "--detach 无法创建临时脚本"
        # $0 是管道(已读尽)无法 cat 自身 → 从公开入口重新获取同名脚本到临时文件。
        local url="${ZFC_INSTALL_URL:-https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/zf_install_selfhost.sh}"
        if ! curl -fsSL "$url" -o "$tmp_self" 2>/dev/null || [[ ! -s "$tmp_self" ]]; then
            rm -f "$tmp_self"
            ZFC_HINT="把 install.sh 下载到本地文件后再 --detach, 或用 nohup/screen/tmux"
            die "$EXIT_DEP_UNAVAILABLE" "--detach 需要可重跑的脚本, 但当前经管道运行且无法从 ${url} 重新获取"
        fi
        self="$tmp_self"
    fi

    : > "$ZFC_LOG_FILE" 2>/dev/null || true
    local pid
    if command_exists setsid; then
        ZFC_DETACHED=1 ZFC_DETACH_CLEANUP="$tmp_self" nohup setsid bash "$self" "$@" >> "$ZFC_LOG_FILE" 2>&1 < /dev/null &
        pid=$!
    else
        ZFC_DETACHED=1 ZFC_DETACH_CLEANUP="$tmp_self" nohup bash "$self" "$@" >> "$ZFC_LOG_FILE" 2>&1 < /dev/null &
        pid=$!
        disown 2>/dev/null || true
    fi
    ZFC_RESULT_EMITTED=1
    local json
    json=$(printf '{"status":"detached","action":"%s","pid":%s,"log":"%s","result_file":"%s"}' \
        "$(json_escape "$ZFC_ACTION")" "$pid" "$(json_escape "$ZFC_LOG_FILE")" "$(json_escape "$ZFC_RESULT_FILE")")
    printf '%s\n' "$json"
    exit 0
}

# 长写动作(install/update/restore/uninstall)始终把日志 tee 到 ZFC_LOG_FILE, 便于断连后 tail。
# 只读/短动作(check/doctor/show-token/...)不 tee, 以免每次截断安装日志。
# 后台子进程(ZFC_DETACHED=1)的 stdout/err 已被父进程重定向到日志, 不再 tee(避免重复)。
maybe_setup_logging() {
    [[ "$ZFC_DETACHED" == "1" ]] && return 0            # 子进程已重定向
    case "$ZFC_ACTION" in
        install|update|restore|uninstall) ;;
        "") [[ ! -t 0 ]] || return 0 ;;                  # 无动作: 仅非 tty 自动安装路径
        *) return 0 ;;                                    # check/doctor/token/... 不 tee
    esac
    : > "$ZFC_LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$ZFC_LOG_FILE") 2>&1
}

# Main entry
main() {
    parse_args "$@"

    maybe_detach "$@"        # ZFC_DETACH → 派生后台并 exit 0
    maybe_setup_logging      # agent/非交互运行始终落日志

    if [[ -n "$ZFC_ACTION" ]]; then
        # 有显式动作 → 直接派发
        dispatch_action
        return
    fi

    # 无动作: tty → 菜单; 非 tty 且必填 env 齐 → 自动安装; 否则帮助
    if [[ -t 0 ]]; then
        run_menu
    elif [[ -n "${WEB_DOMAIN:-}" && -n "${CONTROLER_DOMAIN:-}" && -n "${ZFC_INSTANCE_ID:-}" && -n "${ZFC_API_KEY:-}" ]]; then
        ZFC_ACTION="install"
        ZFC_NONINTERACTIVE=1
        log_info "检测到非交互环境且必填变量齐全, 自动进入全新安装。"
        guard_fresh_install
        main_install
    else
        print_help
        exit 0
    fi
}

# Handle interrupts & ensure structured output on unexpected exit
trap 'echo -e "\n${RED}安装被中断${NC}" >&2; exit 1' INT TERM
# 忽略 SIGHUP: 即便未 --detach、被 `&` 放后台的前台运行, SSH 断开后也能跑完(配合 ZFC_LOG_FILE)。
trap '' HUP
trap zfc_on_exit EXIT

# Run main function
main "$@"
