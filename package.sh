#!/bin/bash

# Sonic Agent 本地打包脚本
# 基于 .github/workflows/release.yml 的打包流程

set -e

# 获取脚本所在目录并切换到该目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取版本号（从 pom.xml 或 git tag）
VERSION=${1:-"dev"}
if [ "$VERSION" = "dev" ]; then
    # 尝试从 git tag 获取版本
    if git describe --tags --exact-match HEAD 2>/dev/null; then
        VERSION=$(git describe --tags --exact-match HEAD)
    else
        VERSION="dev-$(date +%Y%m%d-%H%M%S)"
    fi
fi

# 检测平台
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case "$OS" in
        linux*)
            case "$ARCH" in
                x86_64) echo "linux-x86_64" ;;
                aarch64|arm64) echo "linux-arm64" ;;
                i386|i686) echo "linux-x86" ;;
                *) echo "linux-x86_64" ;;
            esac
            ;;
        darwin*)
            case "$ARCH" in
                arm64) echo "macosx-arm64" ;;
                x86_64) echo "macosx-x86_64" ;;
                *) echo "macosx-arm64" ;;
            esac
            ;;
        msys*|cygwin*|mingw*)
            case "$ARCH" in
                x86_64) echo "windows-x86_64" ;;
                i386|i686) echo "windows-x86" ;;
                *) echo "windows-x86_64" ;;
            esac
            ;;
        *)
            echo "linux-x86_64"
            ;;
    esac
}

PLATFORM=$(detect_platform)

# 根据平台设置变量
case "$PLATFORM" in
    linux-x86)
        DEPEND="linux_x86"
        ADB="linux"
        TAIL=""
        ;;
    linux-x86_64)
        DEPEND="linux_x86_64"
        ADB="linux"
        TAIL=""
        ;;
    linux-arm64)
        DEPEND="linux_arm64"
        ADB="linux"
        TAIL=""
        ;;
    macosx-x86_64)
        DEPEND="macosx_x86_64"
        ADB="darwin"
        TAIL=""
        ;;
    macosx-arm64)
        DEPEND="macosx_arm64"
        ADB="darwin"
        TAIL=""
        ;;
    windows-x86)
        DEPEND="windows_x86"
        ADB="windows"
        TAIL=".exe"
        ;;
    windows-x86_64)
        DEPEND="windows_x86_64"
        ADB="windows"
        TAIL=".exe"
        ;;
    *)
        echo -e "${RED}不支持的平台: $PLATFORM${NC}"
        exit 1
        ;;
esac

PACKAGE_NAME="sonic-agent-${VERSION}-${DEPEND}"
OUT_DIR="out"
PACKAGE_DIR="${OUT_DIR}/${PACKAGE_NAME}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Sonic Agent 打包脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "版本: ${YELLOW}${VERSION}${NC}"
echo -e "平台: ${YELLOW}${PLATFORM}${NC}"
echo -e "依赖标识: ${YELLOW}${DEPEND}${NC}"
echo -e "输出目录: ${YELLOW}${OUT_DIR}${NC}"
echo -e "打包目录: ${YELLOW}${PACKAGE_DIR}${NC}"
echo ""

# 创建输出目录
echo -e "${GREEN}创建输出目录...${NC}"
mkdir -p "${OUT_DIR}"

# 清理旧的打包目录
if [ -d "$PACKAGE_DIR" ]; then
    echo -e "${YELLOW}清理旧的打包目录...${NC}"
    rm -rf "$PACKAGE_DIR"
fi

# 创建打包目录
echo -e "${GREEN}创建打包目录...${NC}"
mkdir -p "${PACKAGE_DIR}/plugins"

# 编译项目
echo -e "${GREEN}编译项目 (平台: ${PLATFORM})...${NC}"
mvn clean package -Dplatform="${PLATFORM}" -Dmaven.test.skip=true

# 复制 JAR 文件
echo -e "${GREEN}复制 JAR 文件...${NC}"
if [ -f "target/sonic-agent-${PLATFORM}.jar" ]; then
    cp "target/sonic-agent-${PLATFORM}.jar" "${PACKAGE_DIR}/"
    echo -e "  ✓ 已复制: sonic-agent-${PLATFORM}.jar"
else
    echo -e "${RED}错误: 找不到编译产物 target/sonic-agent-${PLATFORM}.jar${NC}"
    exit 1
fi

# 复制配置和资源文件
echo -e "${GREEN}复制配置和资源文件...${NC}"
if [ -d "config" ]; then
    cp -r config "${PACKAGE_DIR}/"
    echo -e "  ✓ 已复制: config/"
fi

if [ -d "mini" ]; then
    cp -r mini "${PACKAGE_DIR}/"
    echo -e "  ✓ 已复制: mini/"
fi

# 复制启动脚本
echo -e "${GREEN}复制启动脚本...${NC}"
# 根据平台选择对应的启动脚本
START_SCRIPT=""
START_SCRIPT_NAME=""

case "$PLATFORM" in
    macosx-arm64|macosx-x86_64)
        if [ -f "scripts/start-macosx.command" ]; then
            START_SCRIPT="scripts/start-macosx.command"
            START_SCRIPT_NAME="start-macosx.command"
        fi
        ;;
    linux-*)
        if [ -f "scripts/start-linux.sh" ]; then
            START_SCRIPT="scripts/start-linux.sh"
            START_SCRIPT_NAME="start-linux.sh"
        fi
        ;;
    windows-*)
        if [ -f "scripts/start-windows.bat" ]; then
            START_SCRIPT="scripts/start-windows.bat"
            START_SCRIPT_NAME="start-windows.bat"
        fi
        ;;
esac

# 如果没有找到平台特定的脚本，尝试通用脚本
if [ -z "$START_SCRIPT" ]; then
    if [ -f "scripts/start-macosx.command" ]; then
        START_SCRIPT="scripts/start-macosx.command"
        START_SCRIPT_NAME="start-macosx.command"
    elif [ -f "start-macosx.command" ]; then
        START_SCRIPT="start-macosx.command"
        START_SCRIPT_NAME="start-macosx.command"
    fi
fi

if [ -n "$START_SCRIPT" ]; then
    if [ -n "$START_SCRIPT_NAME" ]; then
        cp "$START_SCRIPT" "${PACKAGE_DIR}/${START_SCRIPT_NAME}"
        # 根据平台更新 JAR 文件名
        sed -i.bak "s/sonic-agent-.*\.jar/sonic-agent-${PLATFORM}.jar/g" "${PACKAGE_DIR}/${START_SCRIPT_NAME}"
        rm -f "${PACKAGE_DIR}/${START_SCRIPT_NAME}.bak"
        chmod +x "${PACKAGE_DIR}/${START_SCRIPT_NAME}"
        echo -e "  ✓ 已复制: ${START_SCRIPT_NAME} (已更新 JAR 文件名)"
    else
        cp "$START_SCRIPT" "${PACKAGE_DIR}/"
        # 根据平台更新 JAR 文件名
        SCRIPT_BASENAME=$(basename "$START_SCRIPT")
        sed -i.bak "s/sonic-agent-.*\.jar/sonic-agent-${PLATFORM}.jar/g" "${PACKAGE_DIR}/${SCRIPT_BASENAME}"
        rm -f "${PACKAGE_DIR}/${SCRIPT_BASENAME}.bak"
        chmod +x "${PACKAGE_DIR}/${SCRIPT_BASENAME}"
        echo -e "  ✓ 已复制: ${SCRIPT_BASENAME} (已更新 JAR 文件名)"
    fi
fi

# 复制插件文件
echo -e "${GREEN}复制插件文件...${NC}"
if [ -d "plugins" ]; then
    # 复制已有的插件文件
    if [ -f "plugins/sonic-android-apk.apk" ]; then
        cp "plugins/sonic-android-apk.apk" "${PACKAGE_DIR}/plugins/"
        echo -e "  ✓ 已复制: sonic-android-apk.apk"
    fi
    
    if [ -f "plugins/sonic-android-scrcpy.jar" ]; then
        cp "plugins/sonic-android-scrcpy.jar" "${PACKAGE_DIR}/plugins/"
        echo -e "  ✓ 已复制: sonic-android-scrcpy.jar"
    fi
    
    if [ -f "plugins/sonic-appium-uiautomator2-server.apk" ]; then
        cp "plugins/sonic-appium-uiautomator2-server.apk" "${PACKAGE_DIR}/plugins/"
        echo -e "  ✓ 已复制: sonic-appium-uiautomator2-server.apk"
    fi
    
    if [ -f "plugins/sonic-appium-uiautomator2-server-test.apk" ]; then
        cp "plugins/sonic-appium-uiautomator2-server-test.apk" "${PACKAGE_DIR}/plugins/"
        echo -e "  ✓ 已复制: sonic-appium-uiautomator2-server-test.apk"
    fi
fi

# 可选：下载外部依赖（需要手动下载或已存在）
echo -e "${YELLOW}注意: 以下依赖需要手动下载或从 release 获取:${NC}"
echo -e "  - ADB binaries (sonic-adb-binary)"
echo -e "  - sonic-android-supply (sas${TAIL})"
echo -e "  - sonic-go-mitmproxy (sonic-go-mitmproxy${TAIL})"
echo -e "  - sonic-ios-bridge (sib${TAIL})"
echo ""
echo -e "${YELLOW}如果需要这些依赖，请:${NC}"
echo -e "  1. 从 GitHub Releases 下载对应平台的二进制文件"
echo -e "  2. 解压到 ${PACKAGE_DIR}/plugins/ 目录"
echo ""

# 创建 README 文件
# 根据平台确定启动脚本名称和说明
START_SCRIPT_NAME=""
START_SCRIPT_CMD=""
case "$PLATFORM" in
    macosx-*)
        START_SCRIPT_NAME="start-macosx.command"
        START_SCRIPT_CMD="./start-macosx.command"
        ;;
    linux-*)
        START_SCRIPT_NAME="start-linux.sh"
        START_SCRIPT_CMD="./start-linux.sh"
        ;;
    windows-*)
        START_SCRIPT_NAME="start-windows.bat"
        START_SCRIPT_CMD="start-windows.bat"
        ;;
    *)
        START_SCRIPT_NAME=""
        START_SCRIPT_CMD=""
        ;;
esac

# 计算对齐位置（最长文件名 + 空格）
JAR_NAME="sonic-agent-${PLATFORM}.jar"
MAX_LEN=${#JAR_NAME}
if [ -n "$START_SCRIPT_NAME" ] && [ ${#START_SCRIPT_NAME} -gt $MAX_LEN ]; then
    MAX_LEN=${#START_SCRIPT_NAME}
fi
if [ ${#MAX_LEN} -lt 30 ]; then
    MAX_LEN=30
fi
ALIGN_POS=$((MAX_LEN + 2))

cat > "${PACKAGE_DIR}/README.txt" << EOF
Sonic Agent 打包文件
===================

版本: ${VERSION}
平台: ${PLATFORM}
打包时间: $(date '+%Y-%m-%d %H:%M:%S')

目录结构:
EOF

# 格式化输出，确保对齐
printf "%-${ALIGN_POS}s : 主程序 JAR 文件\n" "- ${JAR_NAME}" >> "${PACKAGE_DIR}/README.txt"

if [ -n "$START_SCRIPT_NAME" ]; then
    case "$PLATFORM" in
        macosx-*)
            printf "%-${ALIGN_POS}s : 启动脚本 (macOS)\n" "- ${START_SCRIPT_NAME}" >> "${PACKAGE_DIR}/README.txt"
            ;;
        linux-*)
            printf "%-${ALIGN_POS}s : 启动脚本 (Linux)\n" "- ${START_SCRIPT_NAME}" >> "${PACKAGE_DIR}/README.txt"
            ;;
        windows-*)
            printf "%-${ALIGN_POS}s : 启动脚本 (Windows)\n" "- ${START_SCRIPT_NAME}" >> "${PACKAGE_DIR}/README.txt"
            ;;
    esac
fi

printf "%-${ALIGN_POS}s : 配置文件目录\n" "- config/" >> "${PACKAGE_DIR}/README.txt"
printf "%-${ALIGN_POS}s : Minicap 资源文件\n" "- mini/" >> "${PACKAGE_DIR}/README.txt"
printf "%-${ALIGN_POS}s : 插件目录\n" "- plugins/" >> "${PACKAGE_DIR}/README.txt"

cat >> "${PACKAGE_DIR}/README.txt" << EOF

运行方式:
方式1: 直接运行 JAR
  java -jar sonic-agent-${PLATFORM}.jar
EOF

if [ -n "$START_SCRIPT_CMD" ]; then
    cat >> "${PACKAGE_DIR}/README.txt" << EOF

方式2: 使用启动脚本
  ${START_SCRIPT_CMD}
EOF
fi

cat >> "${PACKAGE_DIR}/README.txt" << EOF

注意:
- 确保已安装 JDK 17 或更高版本
- 某些插件可能需要额外的依赖文件
- 首次运行启动脚本时会提示配置 Agent 连接信息
EOF

# 打包成 ZIP
echo -e "${GREEN}打包成 ZIP 文件...${NC}"
ZIP_FILE="${OUT_DIR}/${PACKAGE_NAME}.zip"
if command -v zip &> /dev/null; then
    cd "${OUT_DIR}"
    zip -r "${PACKAGE_NAME}.zip" "$(basename "$PACKAGE_DIR")" > /dev/null
    cd - > /dev/null
    echo -e "  ✓ 已创建: ${ZIP_FILE}"
    echo -e "  ✓ 文件大小: $(du -h "${ZIP_FILE}" | cut -f1)"
else
    echo -e "${YELLOW}警告: 未找到 zip 命令，跳过 ZIP 打包${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}打包完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "输出目录: ${YELLOW}${OUT_DIR}${NC}"
echo -e "打包目录: ${YELLOW}${PACKAGE_DIR}${NC}"
if [ -f "${ZIP_FILE}" ]; then
    echo -e "ZIP 文件: ${YELLOW}${ZIP_FILE}${NC}"
fi
echo ""

