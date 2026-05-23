#!/bin/bash
#
# Sequel PAce CLI Build Script
# Supports: debug, release, tests, archive, clean, run
#
# Usage:
#   ./Scripts/build.sh debug    - Build debug configuration
#   ./Scripts/build.sh release  - Build release configuration
#   ./Scripts/build.sh tests    - Run unit tests
#   ./Scripts/build.sh archive  - Create distribution archive
#   ./Scripts/build.sh clean    - Clean build folder
#   ./Scripts/build.sh run      - Build and run the app
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project Configuration
PROJECT_NAME="sequel-pace.xcodeproj"
SCHEME_DEBUG="Sequel PAce Debug"
SCHEME_RELEASE="Sequel PAce Release"
SCHEME_TESTS="Unit Tests"
APP_NAME="Sequel PAce.app"
BUILD_DIR="build"

# Detect architecture
if [[ $(uname -m) == 'arm64' ]]; then
    ARCH="arm64"
    PG_BASE="/opt/homebrew"
else
    ARCH="x86_64"
    PG_BASE="/usr/local"
fi

# PostgreSQL paths - try multiple versions
# Note: PostgreSQL@17 puts libs in lib/postgresql/, not lib/
PG_VERSIONS=("17" "16" "15" "14")
PG_INCLUDE=""
PG_LIB=""

for ver in "${PG_VERSIONS[@]}"; do
    PG_OPT="${PG_BASE}/opt/postgresql@${ver}"
    if [ -d "$PG_OPT" ]; then
        PG_INCLUDE="${PG_BASE}/include/postgresql@${ver}"
        # Check for lib/postgresql (PostgreSQL 17+) or just lib
        if [ -f "${PG_OPT}/lib/postgresql/libpq.dylib" ]; then
            PG_LIB="${PG_OPT}/lib/postgresql"
        elif [ -f "${PG_OPT}/lib/libpq.dylib" ]; then
            PG_LIB="${PG_OPT}/lib"
        else
            # Try Homebrew's linked lib
            if [ -f "${PG_BASE}/lib/libpq.dylib" ]; then
                PG_LIB="${PG_BASE}/lib"
            fi
        fi
        
        if [ -n "$PG_LIB" ]; then
            echo -e "${GREEN}✓ Found PostgreSQL@${ver}${NC}"
            break
        fi
    fi
done

if [ -z "$PG_INCLUDE" ] || [ -z "$PG_LIB" ]; then
    echo -e "${RED}✗ PostgreSQL not found. Please install with: brew install postgresql@17${NC}"
    exit 1
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Function to print usage
print_usage() {
    echo -e "${BLUE}Sequel PAce CLI Build Script${NC}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  debug     Build debug configuration"
    echo "  release   Build release configuration"
    echo "  package   Build release and create signed .dmg"
    echo "  tests     Run unit tests"
    echo "  archive   Create distribution archive"
    echo "  clean     Clean build folder"
    echo "  run       Build debug and run the app"
    echo ""
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    
    # Check Xcode
    if ! xcode-select -p &>/dev/null; then
        echo -e "${RED}✗ Xcode command line tools not installed${NC}"
        echo "  Run: xcode-select --install"
        exit 1
    fi
    echo -e "${GREEN}✓ Xcode command line tools installed${NC}"
    
    # Check xcpretty (optional but recommended)
    if hash xcpretty 2>/dev/null; then
        USE_XCPRETTY=1
        echo -e "${GREEN}✓ xcpretty available${NC}"
    else
        USE_XCPRETTY=0
        echo -e "${YELLOW}⚠ xcpretty not installed (optional). Install with: gem install xcpretty${NC}"
    fi
    
    # Verify libpq exists
    if [ ! -f "${PG_LIB}/libpq.dylib" ] && [ ! -f "${PG_LIB}/libpq.a" ]; then
        echo -e "${RED}✗ libpq not found in ${PG_LIB}${NC}"
        echo "  Make sure PostgreSQL is installed correctly"
        exit 1
    fi
    echo -e "${GREEN}✓ libpq found at ${PG_LIB}${NC}"
    echo -e "${GREEN}✓ Headers at ${PG_INCLUDE}${NC}"
}

# Command: clean
do_clean() {
    echo -e "${BLUE}Cleaning build folder...${NC}"
    rm -rf "$BUILD_DIR"
    rm -rf ~/Library/Developer/Xcode/DerivedData/sequel-pace-*
    xcodebuild clean -project "$PROJECT_NAME" -scheme "$SCHEME_DEBUG" -quiet 2>/dev/null || true
    echo -e "${GREEN}✓ Clean complete${NC}"
}

# Command: debug
do_debug() {
    check_prerequisites
    echo -e "${BLUE}Building Debug configuration...${NC}"
    
    xcodebuild build \
        -project "$PROJECT_NAME" \
        -scheme "$SCHEME_DEBUG" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        HEADER_SEARCH_PATHS="\$(inherited) ${PG_INCLUDE}" \
        LIBRARY_SEARCH_PATHS="\$(inherited) ${PG_LIB}" \
        OTHER_LDFLAGS="\$(inherited) -L${PG_LIB} -lpq" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO
    
    echo -e "${GREEN}✓ Debug build complete${NC}"
    echo -e "${BLUE}App location: ${BUILD_DIR}/Build/Products/Debug/${APP_NAME}${NC}"

    # Auto-launch only in interactive shell (not CI/headless)
    if [ -t 1 ]; then
        echo -e "${BLUE}Launching Sequel PAce...${NC}"
        open "${BUILD_DIR}/Build/Products/Debug/${APP_NAME}"
    fi
}

# Command: release
do_release() {
    check_prerequisites
    echo -e "${BLUE}Building Release configuration...${NC}"
    
    xcodebuild build \
        -project "$PROJECT_NAME" \
        -scheme "$SCHEME_RELEASE" \
        -configuration Distribution \
        -derivedDataPath "$BUILD_DIR" \
        -destination "platform=macOS,arch=${ARCH}" \
        ARCHS="${ARCH}" \
        ONLY_ACTIVE_ARCH=YES \
        HEADER_SEARCH_PATHS="\$(inherited) ${PG_INCLUDE}" \
        LIBRARY_SEARCH_PATHS="\$(inherited) ${PG_LIB}" \
        OTHER_LDFLAGS="\$(inherited) -L${PG_LIB} -lpq" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO
    
    echo -e "${GREEN}✓ Release build complete${NC}"
    echo -e "${BLUE}App location: ${BUILD_DIR}/Build/Products/Distribution/${APP_NAME}${NC}"
}

# Command: tests
do_tests() {
    check_prerequisites
    echo -e "${BLUE}Running Unit Tests...${NC}"
    
    xcodebuild test \
        -project "$PROJECT_NAME" \
        -scheme "$SCHEME_TESTS" \
        -configuration Debug \
        -destination "platform=macOS,arch=$ARCH" \
        HEADER_SEARCH_PATHS="\$(inherited) ${PG_INCLUDE}" \
        LIBRARY_SEARCH_PATHS="\$(inherited) ${PG_LIB}" \
        OTHER_LDFLAGS="\$(inherited) -L${PG_LIB} -lpq" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO
    
    echo -e "${GREEN}✓ Tests complete${NC}"
}

# Command: archive
do_archive() {
    check_prerequisites
    echo -e "${BLUE}Creating archive...${NC}"
    
    local archive_path="$BUILD_DIR/Sequel PAce.xcarchive"
    
    xcodebuild archive \
        -project "$PROJECT_NAME" \
        -scheme "$SCHEME_RELEASE" \
        -configuration Distribution \
        -archivePath "$archive_path" \
        HEADER_SEARCH_PATHS="\$(inherited) ${PG_INCLUDE}" \
        LIBRARY_SEARCH_PATHS="\$(inherited) ${PG_LIB}" \
        OTHER_LDFLAGS="\$(inherited) -L${PG_LIB} -lpq"
    
    echo -e "${GREEN}✓ Archive complete${NC}"
    echo -e "${BLUE}Archive location: $archive_path${NC}"
}

# Command: package — builds release, ad-hoc signs, and wraps in a DMG
do_package() {
    do_release

    local APP_PATH="${BUILD_DIR}/Build/Products/Distribution/${APP_NAME}"
    local DMG_PATH="${BUILD_DIR}/Sequel PAce.dmg"
    local DMG_STAGING="${BUILD_DIR}/dmg_staging"

    # Verify libpq embedding (must resolve via @rpath, not absolute Homebrew path)
    echo -e "${BLUE}Verifying libpq embedding...${NC}"
    local pq_ref
    pq_ref=$(otool -L "${APP_PATH}/Contents/MacOS/Sequel PAce" 2>/dev/null | grep libpq | awk '{print $1}')
    if [[ "$pq_ref" == /opt/* ]] || [[ "$pq_ref" == /usr/* ]]; then
        echo -e "${YELLOW}⚠ libpq links to absolute Homebrew path: ${pq_ref}${NC}"
        echo -e "${YELLOW}  Run Scripts/setup_libpq.sh to embed libpq into the framework first.${NC}"
    elif [ -n "$pq_ref" ]; then
        echo -e "${GREEN}✓ libpq embedded via: ${pq_ref}${NC}"
    fi

    # Ad-hoc codesign so Gatekeeper doesn't hard-block on first run
    echo -e "${BLUE}Applying ad-hoc codesign...${NC}"
    codesign --force --deep --sign - "${APP_PATH}"
    echo -e "${GREEN}✓ Ad-hoc signature applied${NC}"

    # Build DMG with drag-to-Applications layout + install helper
    echo -e "${BLUE}Creating DMG...${NC}"
    rm -rf "${DMG_STAGING}" "${DMG_PATH}"
    mkdir -p "${DMG_STAGING}"
    cp -R "${APP_PATH}" "${DMG_STAGING}/"
    ln -s /Applications "${DMG_STAGING}/Applications"

    # Install helper script — removes Gatekeeper quarantine automatically
    cat > "${DMG_STAGING}/Install Sequel PAce.command" <<'INSTALL_EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Sequel PAce kuruluyor..."
cp -R "Sequel PAce.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Sequel PAce.app"
echo "Kurulum tamamlandı. Sequel PAce uygulamanızdan başlatabilirsiniz."
INSTALL_EOF
    chmod +x "${DMG_STAGING}/Install Sequel PAce.command"

    hdiutil create \
        -volname "Sequel PAce" \
        -srcfolder "${DMG_STAGING}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    rm -rf "${DMG_STAGING}"

    echo -e "${GREEN}✓ Package complete${NC}"
    echo -e "${BLUE}DMG: ${DMG_PATH}${NC}"
    echo -e "${YELLOW}  Kurulum: DMG içindeki 'Install Sequel PAce.command' scriptini çalıştır${NC}"
    echo -e "${YELLOW}  Ya da Terminal'de: xattr -dr com.apple.quarantine \"/Applications/Sequel PAce.app\"${NC}"
}

# Command: run
do_run() {
    do_debug
    echo -e "${BLUE}Launching Sequel PAce...${NC}"
    open "${BUILD_DIR}/Build/Products/Debug/${APP_NAME}"
}

# Main
MODE="${1:-}"

case "$MODE" in
    debug)
        do_debug
        ;;
    release)
        do_release
        ;;
    package)
        do_package
        ;;
    tests)
        do_tests
        ;;
    archive)
        do_archive
        ;;
    clean)
        do_clean
        ;;
    run)
        do_run
        ;;
    *)
        print_usage
        if [ -n "$MODE" ]; then
            echo -e "${RED}Unknown command: $MODE${NC}"
            exit 1
        fi
        ;;
esac

exit 0
