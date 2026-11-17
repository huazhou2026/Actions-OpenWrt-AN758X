#!/usr/bin/env bash
# ================================================================
# diy-part1.sh —— 拉取可选插件到 package/custom 并校验索引
# 
# 运行目录：ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
# 把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
#
# 温度由 autocore 的 /sbin/tempinfo 提供（files/sbin/tempinfo），
#
# ================================================================
# 严格模式 + pipefail，任何命令失败都立即退出
set -Eeuo pipefail
IFS=$'\n\t'
readonly SCRIPT_START=$(date +%s)
readonly PKG_DIR="$(pwd)/package/custom"
readonly PKGINFO="tmp/.packageinfo"
# ---------------------------------------------------------
# 插件开关（显式声明每一个，避免未定义变量）
# ---------------------------------------------------------
readonly ADD_AIROHA_NPU=true    # luci-app-airoha-npu（Airoha SoC 状态页）
readonly ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
readonly ADD_OPENCLASH=true     # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
readonly ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
readonly ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
readonly ADD_TAILSCALE=false    # luci-app-tailscale
readonly ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
readonly ADD_SMARTDNS=false     # luci-app-smartdns
# ttyd 已在 feeds/luci/applications 中，无需额外克隆，仅在 config 里启用即可
# ---------------------------------------------------------
# 新增：外部源插件开关
# ---------------------------------------------------------
readonly ADD_ONU_CONFIG=true    # naoki66/OpenWrt_ONU_CONFIG (ONU管理、光模块信息)
readonly ADD_ISTORE=true        # iStore应用商店 + quickstart
readonly ADD_ISTOREX=true       # iStoreX 首页/应用管理面板
# ---------------------------------------------------------
# 插件清单——"开关 + 仓库 + 目录 + 分支 [+ 子目录]"集中在这里
# 格式: "name|enabled|url|branch|subdir"  (subdir 可选，用于 monorepo 提取子包)
# 新增插件只需加一行，不再到处复制粘贴
# ---------------------------------------------------------
readonly PKG_LIST=(
    "luci-app-airoha-npu|${ADD_AIROHA_NPU}|https://github.com/luanmuc/luci-app-airoha-npu|main|"
    "openwrt-passwall-packages|${ADD_PASSWALL}|https://github.com/xiaorouji/openwrt-passwall-packages|main|"
    "openwrt-passwall|${ADD_PASSWALL}|https://github.com/xiaorouji/openwrt-passwall|main|"
    "luci-app-mosdns|${ADD_MOSDNS}|https://github.com/sbwml/luci-app-mosdns|v5|"
    "v2ray-geodata|${ADD_MOSDNS}|https://github.com/sbwml/v2ray-geodata|master|"
    "luci-app-lucky|${ADD_LUCKY}|https://github.com/sirpdboy/luci-app-lucky|main|"
    "luci-app-tailscale|${ADD_TAILSCALE}|https://github.com/asvow/luci-app-tailscale|main|"
    "luci-app-openlist2|${ADD_OPENLIST}|https://github.com/sbwml/luci-app-openlist2|main|"
    "luci-app-smartdns|${ADD_SMARTDNS}|https://github.com/pymumu/luci-app-smartdns|master|"
    "smartdns|${ADD_SMARTDNS}|https://github.com/pymumu/smartdns|master|"
    # 新增：外部源插件
    "OpenWrt_ONU_CONFIG|${ADD_ONU_CONFIG}|https://github.com/naoki66/OpenWrt_ONU_CONFIG|main|"
    # iStore: luci-app-store 在 istoreos/istore/luci/luci-app-store
    "luci-app-store|${ADD_ISTORE}|https://github.com/istoreos/istore|main|luci/luci-app-store"
    # iStore quickstart: 在 linkease/nas-packages-luci/luci/luci-app-quickstart
    "luci-app-quickstart|${ADD_ISTORE}|https://github.com/linkease/nas-packages-luci|main|luci/luci-app-quickstart"
    # iStoreX 首页: 在 linkease/nas-packages-luci/luci/luci-app-istorex
    "luci-app-istorex|${ADD_ISTOREX}|https://github.com/linkease/nas-packages-luci|main|luci/luci-app-istorex"
    # iStore libtaskd: 在 istoreos/istore/luci/luci-lib-taskd
    "luci-lib-taskd|${ADD_ISTORE}|https://github.com/istoreos/istore|main|luci/luci-lib-taskd"
    # iStore libxterm: 在 istoreos/istore/luci/luci-lib-xterm
    "luci-lib-xterm|${ADD_ISTORE}|https://github.com/istoreos/istore|main|luci/luci-lib-xterm"
    # iStore taskd: 在 istoreos/istore/luci/taskd
    "taskd|${ADD_ISTORE}|https://github.com/istoreos/istore|main|luci/taskd"
    # quickstart backend: 禁用，依赖太多 ImmortalWrt 中不存在的包
    # "quickstart|${ADD_ISTORE}|https://github.com/linkease/nas-packages|main|network/services/quickstart"
)
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "::error::$*" >&2; exit 1; }
group() { echo "::group::$*"; }
endgroup(){ echo "::endgroup::"; }
# 带指数退避的重试
retry() {
    local attempts=$1 max=$2; shift 2
    while (( attempts <= max )); do
        if "$@"; then return 0; fi
        local rc=$?
        log " ↻ 第 ${attempts}/${max} 次失败（rc=${rc}），${attempts}0s 后重试…"
        sleep $(( attempts * 10 ))
        attempts=$(( attempts + 1 ))
    done
    return 1
}
# 下载并解压 GitHub 仓库 tarball：完全绕过 git credential helper 问题
# 用法: fetch_tarball "owner/repo" "target_dir" "branch"
fetch_tarball() {
    local repo="$1" dir="$2" br="${3:-main}"
    # 目录已存在且有 Makefile 视为已就绪
    if [ -d "$dir" ] && [ -f "$dir/Makefile" ]; then
        log " ↷ 已存在，跳过: $dir"
        return 0
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    local log_file
    log_file="$(mktemp /tmp/tarball-XXXXXX.log)"
    
    # 智能获取默认分支：对公开仓库无需认证即可查询（速率限制 60/hr 足够）
    # GITHUB_TOKEN 仅限当前仓库，不能用于外部仓库 API
    local default_branch=""
    # 先尝试无认证调用（公开仓库适用）
    default_branch=$(curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}" 2>/dev/null | \
        grep -o '"default_branch"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
    if [ -n "$default_branch" ]; then
        log " 🔍 GitHub API 返回默认分支: ${default_branch}"
    else
        log " ⚠ GitHub API 未返回默认分支，使用回退列表"
    fi
    
    # 构建尝试分支列表：API 结果优先，然后是指定分支，最后是常见分支 + OpenWrt 版本分支
    local branches=()
    [ -n "$default_branch" ] && branches+=("$default_branch")
    branches+=("$br" "master" "dev" "v5" "v4" "v3" "mainline" "release" "stable" "latest" "trunk" "openwrt" "lede" \
        "openwrt-24.10" "openwrt-23.05" "openwrt-22.03" "openwrt-21.02" "openwrt-19.07" \
        "24.10" "23.05" "22.03" "21.02" "19.07")
    # 去重：使用关联数组（bash 4+），更可靠
    local unique_branches=()
    declare -A seen_branches
    for b in "${branches[@]}"; do
        [[ -n "$b" && -z "${seen_branches[$b]:-}" ]] || continue
        seen_branches[$b]=1
        unique_branches+=("$b")
    done
    
    local tarball_url=""
    local success=0
    
    for branch in "${unique_branches[@]}"; do
        tarball_url="https://github.com/${repo}/archive/refs/heads/${branch}.tar.gz"
        log " ⤓ ${repo}@${branch} -> $dir (tarball)"
        if retry 1 2 curl -fsSL --retry 2 -o /tmp/${repo//\//_}.tar.gz "$tarball_url" >"$log_file" 2>&1; then
            success=1
            br="$branch"
            break
        fi
        log " ↻ 分支 ${branch} 不存在 (404)，尝试下一个..."
    done
    
    if [ "$success" -ne 1 ]; then
        echo "--- tarball 下载失败，尝试了所有分支 ---" >&2
        cat "$log_file" >&2
        echo "-----------------------------------" >&2
        rm -f "$log_file"
        return 1
    fi
    
    if ! tar -xzf /tmp/${repo//\//_}.tar.gz -C "$dir" --strip-components=1 >"$log_file" 2>&1; then
        echo "--- 解压失败 ---" >&2
        cat "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi
    rm -f "$log_file" /tmp/${repo//\//_}.tar.gz
    if [ ! -f "$dir/Makefile" ]; then
        log " ⚠ $dir 无根 Makefile，视为源仓库/子包容器"
    fi
    log " ✅ ${repo}@${br} 解压完成"
}
# ================================================================
# 主流程
# ================================================================
group "拉取可选插件 (diy-part1.sh)"
mkdir -p "$PKG_DIR"
endgroup
group "下载插件仓库 tarball（共 ${#PKG_LIST[@]} 项清单）"
ENABLED_COUNT=0
FAILED_PKGS=()
for entry in "${PKG_LIST[@]}"; do
    IFS='|' read -r name enabled url branch subdir <<<"$entry"
    if [ "$enabled" != "true" ]; then
        log " ⊘ $name 未启用"
        continue
    fi
    # 从 url 提取 owner/repo
    repo="${url#https://github.com/}"
    ENABLED_COUNT=$((ENABLED_COUNT + 1))
    
    # 临时下载目录（monorepo 用完即删）
    tmp_dir="/tmp/${repo//\//_}_${branch//\//_}"
    if ! fetch_tarball "$repo" "$tmp_dir" "$branch"; then
        FAILED_PKGS+=("$name")
        echo "::error::下载失败: $name ($url)"
        continue
    fi
    
    # 处理 monorepo 子目录提取
    if [ -n "$subdir" ] && [ -d "$tmp_dir/$subdir" ]; then
        rm -rf "$PKG_DIR/$name"
        mv "$tmp_dir/$subdir" "$PKG_DIR/$name"
        log " ✅ 从 monorepo 提取 $subdir -> $PKG_DIR/$name"
        # 清理临时目录
        rm -rf "$tmp_dir"
    elif [ -n "$subdir" ] && [ ! -d "$tmp_dir/$subdir" ]; then
        log " ❌ 未找到子目录 $subdir"
        FAILED_PKGS+=("$name")
        echo "::error::子目录不存在: $name -> $subdir ($url)"
        rm -rf "$tmp_dir"
    else
        # 普通仓库：直接移动到目标目录
        rm -rf "$PKG_DIR/$name"
        mv "$tmp_dir" "$PKG_DIR/$name"
    fi
done
endgroup
# 特殊处理：passwall 仓库里嵌套了 luci-app-passwall2，需要剔除
if [ "$ADD_PASSWALL" = "true" ] && [ -d "$PKG_DIR/openwrt-passwall/luci-app-passwall2" ]; then
    rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2"
    log " ✂ 已剔除 luci-app-passwall2"
fi
(( ${#FAILED_PKGS[@]} == 0 )) || die "以下插件克隆失败: ${FAILED_PKGS[*]}"

# 特殊处理：OpenWrt_ONU_CONFIG 仓库包含多个子包，需移动到 package/custom 根目录
if [ "$ADD_ONU_CONFIG" = "true" ] && [ -d "$PKG_DIR/OpenWrt_ONU_CONFIG" ]; then
    group "展开 OpenWrt_ONU_CONFIG 子包"
    # 先移除冲突的包：luci-app-pon 和 luci-app-iptv 与 luci-app-onu 有文件冲突
    #（注：luci-app-pon/iptv 功能已合并入 luci-app-onu，保留会导致 opkg 安装冲突）
    for conflict_pkg in luci-app-pon luci-app-iptv; do
        if [ -d "$PKG_DIR/OpenWrt_ONU_CONFIG/$conflict_pkg" ]; then
            rm -rf "$PKG_DIR/OpenWrt_ONU_CONFIG/$conflict_pkg"
            log " ✂ 已移除冲突包: $conflict_pkg"
        fi
    done
    for subpkg in airoha-pond airoha-ponctl airoha-pon-debug luci-app-onu luci-app-pon-status; do
        if [ -d "$PKG_DIR/OpenWrt_ONU_CONFIG/$subpkg" ]; then
            mv "$PKG_DIR/OpenWrt_ONU_CONFIG/$subpkg" "$PKG_DIR/"
            log " ✅ 已移动 $subpkg 到 package/custom/"
        else
            log " ⚠ 未找到 $subpkg"
        fi
    done
    # 清理空的父目录
    rmdir "$PKG_DIR/OpenWrt_ONU_CONFIG" 2>/dev/null || true
    endgroup
fi

# 特殊处理：iStore 仓库 - 验证菜单入口并修正
if [ "$ADD_ISTORE" = "true" ]; then
    group "验证 iStore 包菜单入口"
    # luci-app-store 可能在 istoreos/istore/luci/luci-app-store
    if [ -d "$PKG_DIR/luci-app-store" ] && [ -f "$PKG_DIR/luci-app-store/Makefile" ]; then
        log " ✅ luci-app-store 存在，检查菜单配置..."
        # 检查是否有 LUCI_TITLE 和 LUCI_DEPENDS
        grep -q "LUCI_TITLE" "$PKG_DIR/luci-app-store/Makefile" || log " ⚠ luci-app-store 缺少 LUCI_TITLE"
        grep -q "LUCI_DEPENDS" "$PKG_DIR/luci-app-store/Makefile" || log " ⚠ luci-app-store 缺少 LUCI_DEPENDS"
        # 显示菜单相关配置
        grep -E "(LUCI_TITLE|LUCI_DEPENDS|LUCI_MENU)" "$PKG_DIR/luci-app-store/Makefile" || log " ⚠ 未找到菜单配置"
    fi
    # luci-app-quickstart 可能在 linkease/nas-packages-luci/luci/luci-app-quickstart
    if [ -d "$PKG_DIR/luci-app-quickstart" ] && [ -f "$PKG_DIR/luci-app-quickstart/Makefile" ]; then
        log " ✅ luci-app-quickstart 存在，检查菜单配置..."
        grep -E "(LUCI_TITLE|LUCI_DEPENDS|LUCI_MENU)" "$PKG_DIR/luci-app-quickstart/Makefile" || log " ⚠ 未找到菜单配置"
    fi
    # luci-app-istorex 可能在 linkease/nas-packages-luci/luci/luci-app-istorex
    if [ -d "$PKG_DIR/luci-app-istorex" ] && [ -f "$PKG_DIR/luci-app-istorex/Makefile" ]; then
        log " ✅ luci-app-istorex 存在，检查菜单配置..."
        grep -E "(LUCI_TITLE|LUCI_DEPENDS|LUCI_MENU)" "$PKG_DIR/luci-app-istorex/Makefile" || log " ⚠ 未找到菜单配置"
    fi
    endgroup
fi

# 特殊处理：iStore 依赖修正 - 适配 ImmortalWrt/ponwrt feeds
if [ "$ADD_ISTORE" = "true" ]; then
    group "修正 iStore 包依赖 (适配 ImmortalWrt feeds)"
    # luci-app-store: 替换不存在的依赖
    if [ -f "$PKG_DIR/luci-app-store/Makefile" ]; then
        log " 🔧 修正 luci-app-store 依赖..."
        # libuci-lua -> libuci (ImmortalWrt 中 libuci 已包含 lua 绑定)
        sed -i 's/libuci-lua/libuci/g' "$PKG_DIR/luci-app-store/Makefile"
        # tar -> 标准包名即为 tar (可能不在 feeds 中，尝试移除或替换为 busybox)
        # 先检查 feeds 中是否有 tar
        if ! find feeds -name "Makefile" -exec grep -l '^Package: tar$' {} \; | grep -q .; then
            log " ⚠ feeds 中无 tar 包，移除 luci-app-store 对 tar 的依赖"
            sed -i 's/\+tar//g; s/tar\+//g; s/ tar / /g' "$PKG_DIR/luci-app-store/Makefile"
        fi
        log " ✅ luci-app-store 依赖已修正"
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/luci-app-store/Makefile" | head -5
    fi
    # luci-app-quickstart: 移除对 quickstart backend 的依赖
    if [ -f "$PKG_DIR/luci-app-quickstart/Makefile" ]; then
        log " 🔧 修正 luci-app-quickstart 依赖 (移除 quickstart backend 依赖)..."
        # luci-app-quickstart 依赖 quickstart backend，但我们禁用了 backend
        # 移除 +quickstart 依赖
        sed -i 's/\+quickstart//g; s/quickstart\+//g; s/ quickstart / /g' "$PKG_DIR/luci-app-quickstart/Makefile"
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/luci-app-quickstart/Makefile" | head -5
    fi
    # luci-lib-taskd: 修正依赖 (luci-lib-xterm, taskd 已单独拉取)
    if [ -f "$PKG_DIR/luci-lib-taskd/Makefile" ]; then
        log " 🔧 修正 luci-lib-taskd 依赖..."
        # 保留 luci-lib-xterm 和 taskd 依赖，因为我们已经单独拉取了这两个包
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/luci-lib-taskd/Makefile" | head -5
    fi
    # luci-lib-xterm: 检查
    if [ -f "$PKG_DIR/luci-lib-xterm/Makefile" ]; then
        log " 🔧 检查 luci-lib-xterm..."
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/luci-lib-xterm/Makefile" | head -5
    fi
    # luci-app-istorex: 检查 (from remote)
    if [ -f "$PKG_DIR/luci-app-istorex/Makefile" ]; then
        log " 🔧 检查 luci-app-istorex..."
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/luci-app-istorex/Makefile" | head -5
    fi
    # taskd: 修正依赖 (移除 ImmortalWrt 中不存在的 coreutils, coreutils-stty, script-utils)
    if [ -f "$PKG_DIR/taskd/Makefile" ]; then
        log " 🔧 修正 taskd 依赖..."
        # coreutils, coreutils-stty, script-utils 在 ImmortalWrt feeds 中可能不存在
        # 尝试替换为可用的包或移除
        sed -i 's/\+coreutils//g; s/coreutils\+//g; s/ coreutils / /g' "$PKG_DIR/taskd/Makefile"
        sed -i 's/\+coreutils-stty//g; s/coreutils-stty\+//g; s/ coreutils-stty / /g' "$PKG_DIR/taskd/Makefile"
        sed -i 's/\+script-utils//g; s/script-utils\+//g; s/ script-utils / /g' "$PKG_DIR/taskd/Makefile"
        log " ✅ taskd 依赖已修正"
        grep -E "(DEPENDS|LUCI_DEPENDS)" "$PKG_DIR/taskd/Makefile" | head -5
    fi
    endgroup
fi

# 特殊处理：passwall 仓库里嵌套了 luci-app-passwall2，需要剔除
if [ "$ADD_PASSWALL" = "true" ] && [ -d "$PKG_DIR/openwrt-passwall/luci-app-passwall2" ]; then
    rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2"
    log " ✂ 已剔除 luci-app-passwall2"
fi
group "清理重复嵌套目录"
# 个别仓库（如 rchen14b/luci-app-airoha-npu）会在根目录 + 同名子目录里各放一份，
# 会把扫描打断。扫 /Makefile，检查是否同时存在 //Makefile。
while IFS= read -r mkfile; do
    pkg_dir="$(dirname "$mkfile")"
    pkg_name="$(basename "$pkg_dir")"
    nested="$pkg_dir/$pkg_name"
    if [ -d "$nested" ] && [ -f "$nested/Makefile" ]; then
        rm -rf "$nested"
        log " ✂ 已移除重复嵌套目录: $pkg_name/$pkg_name"
    fi
done < <(find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type f -name Makefile)
endgroup
group "重建包索引"
# 必须连 stamp 一起删：prepare-tmpinfo 有 scan_unchanged 优化，
# stamp 不删的话索引不会真正重建
rm -f tmp/.packageinfo tmp/.targetinfo
rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
rm -f tmp/.config-package.in tmp/.config-target.in
make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true
[ -s "$PKGINFO" ] || die "$PKGINFO 为空，prepare-tmpinfo 失败"
log " ✅ tmp/.packageinfo 共 $(grep -c '^Package: ' "$PKGINFO") 个包"
endgroup
group "包索引校验"
INDEX_MISS=()
for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ -f "$d/Makefile" ] || { log " ⊘ $n（无根 Makefile，跳过）"; continue; }
    if grep -qx "Package: $n" "$PKGINFO"; then
        log " ✅ $n"
    else
        log " ❌ $n 未进索引"
        INDEX_MISS+=("$n")
        for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
            [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
        done
    fi
done
endgroup
group "必装插件硬校验"
# config 里已写 =y 的包都必须出现在这里，否则 defconfig 会静默剔除
CRITICAL_PKGS=(luci-app-airoha-npu luci-app-openclash luci-app-onu luci-app-pon-status luci-app-store luci-app-quickstart luci-app-istorex luci-app-autoreboot luci-app-ttyd)
# 若以后新增必装包，在这里追加，例如：
# CRITICAL_PKGS+=(luci-app-passwall luci-app-mosdns)
# 注意：luci-app-ttyd 在 feeds 中，luci-app-onu/pon-status 来自 OpenWrt_ONU_CONFIG，luci-app-store/quickstart 来自 iStore monorepo
[ -f feeds/luci/luci.mk ] || die "feeds/luci/luci.mk 缺失，LuCI app 无法解析"
HARD_MISS=()
for r in "${CRITICAL_PKGS[@]}"; do
    grep -qx "Package: $r" "$PKGINFO" || HARD_MISS+=("$r")
done
if (( ${#HARD_MISS[@]} > 0 )); then
    for m in "${HARD_MISS[@]}"; do
        echo "::error::必装插件 $m 未进索引，defconfig 会静默剔除 =y"
    done
    exit 1
fi
log " ✅ 必装插件全部就绪: ${CRITICAL_PKGS[*]}"
endgroup
# ================================================================
# 覆盖 feeds/luci 中自带的 dae / honk
# ================================================================
group "覆盖 feeds/luci 中的 dae / honk，并将 honk 放入 package/custom"
rm -rf feeds/luci/applications/luci-app-dae
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/applications/luci-app-honk
fetch_tarball "QiuSimons/luci-app-dae" "feeds/luci/applications/luci-app-dae" "main"
# honk 是容器仓库，含 honk + luci-app-honk 两个包，必须放到 package/custom 下
fetch_tarball "QiuSimons/luci-app-honk" "$PKG_DIR/honk" "main"
# ------------------------------------------------------------------
# 预放 honk-core.bin：--if-needed 检测到无 stamp 的产物会直接复用，
# 跳过 zig/bpf-linker/cargo 工具链校验和源码编译
# ------------------------------------------------------------------
HONK_DIR="$PKG_DIR/honk/honk"
HONK_OUT="$HONK_DIR/files/honk-core.bin"
if [ -s "$HONK_OUT" ]; then
    log " ↷ honk-core.bin 已存在，跳过预放"
else
    group "预放 honk-core.bin（免 zig 工具链）"
    curl -fsSL --retry 3 -o /tmp/honk-core.tar.gz \
        "https://github.com/daeuniverse/honk/releases/download/v0.1.0-beta.2/honk-core-v0.1.0-beta.2-aarch64-unknown-linux-musl-stock-native-api.tar.gz"
    echo "bef60542db1d29fa87ad3b5300d0960a1bd173b7ba1121b423b27985a202eb2c /tmp/honk-core.tar.gz" | sha256sum -c -
    rm -rf /tmp/honkpkg && mkdir -p /tmp/honkpkg
    tar -xzf /tmp/honk-core.tar.gz -C /tmp/honkpkg
    core="$(find /tmp/honkpkg -type f -name honk-core -print -quit)"
    [ -n "$core" ] || die "tarball 内未找到 honk-core，release 结构可能已变"
    mkdir -p "$HONK_DIR/files"
    cp "$core" "$HONK_OUT"
    log " ✅ 已预放 honk-core.bin ($(du -h "$HONK_OUT" | cut -f1))"
    endgroup
fi
# ------------------------------------------------------------------
# honk 仓库的 Makefile 把 PKG_HASH 写成大写 SKIP 占位，
# OpenWrt scripts/download.pl 只识别小写 skip 跳过校验；
# 大写 SKIP 会触发 "Cannot find appropriate hash command ..."。
# 这里把 PKG_HASH / PKG_MIRROR_HASH 的纯 SKIP 占位统一改成 skip。
# 只匹配纯占位行，不会误伤真实哈希。
# ------------------------------------------------------------------
sed -i 's/?=SKIP$/?=skip/' "$PKG_DIR/honk/honk/Makefile"
if [ -d "$PKG_DIR/honk" ]; then
    honk_patched=0
    while IFS= read -r -d '' mkfile; do
        if grep -qE '^[[:space:]]*PKG_(HASH|MIRROR_HASH)[[:space:]]*:?=[[:space:]]*SKIP[[:space:]]*$' "$mkfile"; then
            sed -i -E 's/^([[:space:]]*PKG_(HASH|MIRROR_HASH)[[:space:]]*:?=[[:space:]]*)SKIP[[:space:]]*$/\1skip/' "$mkfile"
            log " ✏ 修正 $(basename "$(dirname "$mkfile")")/Makefile：PKG_*HASH SKIP → skip"
            honk_patched=$((honk_patched + 1))
        fi
    done < <(find "$PKG_DIR/honk" -type f -name Makefile -print0)
    log " ✅ honk Makefile 哈希占位修正: ${honk_patched} 处"
fi
# OpenClash update to new version
rm -rf feeds/luci/applications/luci-app-openclash
fetch_tarball "vernesong/OpenClash" "feeds/luci/applications/luci-app-openclash" "dev"
# ================================================================
# 输出 GitHub Step Summary，Actions 页面直接看结果
# ================================================================
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## diy-part1.sh 执行报告"
        echo ""
        echo "| 项目 | 值 |"
        echo "|---|---|"
        echo "| 启用插件 | ${ENABLED_COUNT} / ${#PKG_LIST[@]} |"
        echo "| 索引缺失 | ${INDEX_MISS[*]:-无} |"
        echo "| 必装校验 | ✅ 通过（${CRITICAL_PKGS[*]}） |"
        echo "| 耗时 | $(( $(date +%s) - SCRIPT_START ))s |"
    } >> "$GITHUB_STEP_SUMMARY"
fi
log "🎉 diy-part1.sh 执行完毕"
endgroup