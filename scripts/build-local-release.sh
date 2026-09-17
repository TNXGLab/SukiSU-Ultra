#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_KMIS=(
    "android12-5.10"
    "android13-5.10"
    "android13-5.15"
    "android14-5.15"
    "android14-6.1"
    "android15-6.6"
    "android16-6.12"
    "android17-6.18"
)
DEFAULT_ABIS=("arm64-v8a")

KMIS=()
ABIS=()
MANAGER_PACKAGE="moe.tnxg.sukisu"
DDK_RELEASE="20260828"
DDK_REGISTRY_VALUE="${DDK_REGISTRY:-ghcr.nju.edu.cn}"
KEYSTORE_PATH="${KEYSTORE_FILE:-${HOME:-}/android.p12}"
KEY_ALIAS_VALUE="${KEY_ALIAS:-app_sign}"
OUTPUT_NAME=""
DOCKER_PLATFORM_VALUE="${DOCKER_PLATFORM:-linux/amd64}"
ANDROID_API_LEVEL="26"
CONTAINER_ENGINE=""

TEMP_DIR=""

log() {
    printf '[build] %s\n' "$*"
}

die() {
    printf '[build] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: scripts/build-local-release.sh [options]

Build the complete local release chain:
  LKM -> ksuinit -> ksud -> Manager APK -> inject -> align -> sign -> verify

Options:
  --kmi <name>           Build one KMI. Repeat to build multiple KMIs.
                         Defaults to every KMI supported by the project.
  --abi <name>           Package one Android ABI. Repeat to package multiple ABIs.
                         Defaults to arm64-v8a.
  --package <name>       Manager package accepted by the generated LKM.
                         Default: moe.tnxg.sukisu
  --keystore <path>      PKCS12/JKS keystore used for APK and LKM identity.
                         Default: $KEYSTORE_FILE or ~/android.p12
  --alias <name>         Keystore alias. Default: $KEY_ALIAS or app_sign
  --ddk-release <value>  ghcr.io/ylarod/ddk-min release. Default: 20260828
  --ddk-registry <host>  Registry mirror for ylarod/ddk-min.
                         Default: $DDK_REGISTRY or ghcr.nju.edu.cn
  --output-name <name>   Output APK base name under dist/.
  -h, --help             Show this help.

Signing passwords are read from KEYSTORE_PASSWORD and KEY_PASSWORD. When run
interactively, a missing KEYSTORE_PASSWORD is requested without echoing it.
KEY_PASSWORD defaults to KEYSTORE_PASSWORD.

Examples:
  KEYSTORE_PASSWORD='***' scripts/build-local-release.sh
  KEYSTORE_PASSWORD='***' scripts/build-local-release.sh --kmi android16-6.12
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

append_unique() {
    local value="$1"
    shift
    local existing
    for existing in "$@"; do
        [[ "$existing" == "$value" ]] && return 1
    done
    return 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kmi)
                [[ $# -ge 2 ]] || die "--kmi requires a value"
                if append_unique "$2" "${KMIS[@]:-}"; then
                    KMIS+=("$2")
                fi
                shift 2
                ;;
            --abi)
                [[ $# -ge 2 ]] || die "--abi requires a value"
                if append_unique "$2" "${ABIS[@]:-}"; then
                    ABIS+=("$2")
                fi
                shift 2
                ;;
            --package)
                [[ $# -ge 2 ]] || die "--package requires a value"
                MANAGER_PACKAGE="$2"
                shift 2
                ;;
            --keystore)
                [[ $# -ge 2 ]] || die "--keystore requires a value"
                KEYSTORE_PATH="$2"
                shift 2
                ;;
            --alias)
                [[ $# -ge 2 ]] || die "--alias requires a value"
                KEY_ALIAS_VALUE="$2"
                shift 2
                ;;
            --ddk-release)
                [[ $# -ge 2 ]] || die "--ddk-release requires a value"
                DDK_RELEASE="$2"
                shift 2
                ;;
            --ddk-registry)
                [[ $# -ge 2 ]] || die "--ddk-registry requires a value"
                DDK_REGISTRY_VALUE="$2"
                shift 2
                ;;
            --output-name)
                [[ $# -ge 2 ]] || die "--output-name requires a value"
                OUTPUT_NAME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if [[ ${#KMIS[@]} -eq 0 ]]; then
        KMIS=("${DEFAULT_KMIS[@]}")
    fi
    if [[ ${#ABIS[@]} -eq 0 ]]; then
        ABIS=("${DEFAULT_ABIS[@]}")
    fi
}

validate_inputs() {
    local kmi
    local abi
    local has_arm64="false"

    [[ "$MANAGER_PACKAGE" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] ||
        die "Invalid Android package name: $MANAGER_PACKAGE"

    for kmi in "${KMIS[@]}"; do
        [[ "$kmi" =~ ^android[0-9]+-[0-9]+\.[0-9]+$ ]] || die "Invalid KMI: $kmi"
    done

    for abi in "${ABIS[@]}"; do
        case "$abi" in
            arm64-v8a)
                has_arm64="true"
                ;;
            armeabi-v7a|x86_64) ;;
            *) die "Unsupported ABI: $abi" ;;
        esac
    done

    [[ -f "$KEYSTORE_PATH" ]] || die "Keystore not found: $KEYSTORE_PATH"
    [[ "$has_arm64" == "true" ]] || die "arm64-v8a is required because LKM patch assets are arm64-only"
    [[ -z "$OUTPUT_NAME" || "$OUTPUT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "Invalid output name: $OUTPUT_NAME"
    DDK_REGISTRY_VALUE="${DDK_REGISTRY_VALUE#https://}"
    DDK_REGISTRY_VALUE="${DDK_REGISTRY_VALUE#http://}"
    DDK_REGISTRY_VALUE="${DDK_REGISTRY_VALUE%/}"
    [[ -n "$DDK_REGISTRY_VALUE" ]] || die "DDK registry cannot be empty"

    KEYSTORE_PATH="$(cd "$(dirname "$KEYSTORE_PATH")" && pwd)/$(basename "$KEYSTORE_PATH")"
}

resolve_signing_passwords() {
    if [[ -z "${KEYSTORE_PASSWORD:-}" ]]; then
        if [[ -t 0 ]]; then
            printf 'Keystore password: ' >&2
            IFS= read -r -s KEYSTORE_PASSWORD
            printf '\n' >&2
        else
            die "KEYSTORE_PASSWORD is required in non-interactive mode"
        fi
    fi
    KEY_PASSWORD="${KEY_PASSWORD:-$KEYSTORE_PASSWORD}"
    export KEYSTORE_PASSWORD KEY_PASSWORD
}

resolve_android_toolchain() {
    if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
        ANDROID_SDK_ROOT="${ANDROID_HOME:-${HOME:-}/Library/Android/sdk}"
    fi
    [[ -d "$ANDROID_SDK_ROOT" ]] || die "Android SDK not found: $ANDROID_SDK_ROOT"

    if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
        local configured_ndk
        configured_ndk="$(sed -n 's/^ndk = "\([^"]*\)"/\1/p' "$PROJECT_ROOT/manager/gradle/libs.versions.toml" | head -n 1)"
        [[ -n "$configured_ndk" ]] || die "Cannot determine the configured NDK version"
        ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$configured_ndk"
    fi
    [[ -d "$ANDROID_NDK_HOME" ]] || die "Android NDK not found: $ANDROID_NDK_HOME"

    local prebuilt_dir
    prebuilt_dir=""
    for candidate in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*; do
        if [[ -x "$candidate/bin/clang" ]]; then
            prebuilt_dir="$candidate"
            break
        fi
    done
    [[ -n "$prebuilt_dir" ]] || die "No usable NDK LLVM prebuilt found"

    LLVM_BIN="$prebuilt_dir/bin"
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    export ANDROID_SDK_ROOT ANDROID_NDK_HOME LLVM_BIN
}

resolve_java_home() {
    if [[ -z "${JAVA_HOME:-}" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
        JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    fi
    [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" && -x "$JAVA_HOME/bin/jlink" ]] ||
        die "A complete JDK 21 with jlink is required"
    export JAVA_HOME
}

preflight() {
    local command_name
    for command_name in cargo git keytool python3 rsync rustup shasum unzip; do
        require_command "$command_name"
    done

    resolve_container_engine
    [[ -x "$PROJECT_ROOT/manager/gradlew" ]] || die "Gradle wrapper is not executable"

    resolve_android_toolchain
    resolve_java_home
    rustup target add --toolchain stable aarch64-unknown-linux-musl >/dev/null

    local abi
    for abi in "${ABIS[@]}"; do
        rustup target add --toolchain stable "$(abi_to_triple "$abi")" >/dev/null
    done
}

resolve_container_engine() {
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_ENGINE="$(command -v docker)"
        "$CONTAINER_ENGINE" info >/dev/null 2>&1 || die "Docker daemon is not running"
        log "Container engine: Docker"
        return
    fi

    if command -v container >/dev/null 2>&1; then
        CONTAINER_ENGINE="$(command -v container)"
    elif [[ -x /opt/homebrew/bin/container ]]; then
        CONTAINER_ENGINE="/opt/homebrew/bin/container"
    else
        die "Docker or Apple Container is required to build LKM images"
    fi

    if ! "$CONTAINER_ENGINE" system status >/dev/null 2>&1; then
        log "Starting Apple Container services"
        "$CONTAINER_ENGINE" system start >/dev/null
    fi
    "$CONTAINER_ENGINE" system status >/dev/null 2>&1 || die "Apple Container services are not running"
    log "Container engine: Apple Container"
}

abi_to_triple() {
    case "$1" in
        arm64-v8a) printf 'aarch64-linux-android\n' ;;
        armeabi-v7a) printf 'armv7-linux-androideabi\n' ;;
        x86_64) printf 'x86_64-linux-android\n' ;;
        *) die "Unsupported ABI: $1" ;;
    esac
}

triple_to_ndk_triple() {
    case "$1" in
        armv7-linux-androideabi) printf 'armv7a-linux-androideabi\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

prepare_certificate_identity() {
    local cert_path="$TEMP_DIR/manager-cert.der"
    # 内核直接校验 APK 签名证书的 DER 大小和 SHA-256，因此这里从同一密钥库自动派生参数。
    keytool -exportcert \
        -keystore "$KEYSTORE_PATH" \
        -storepass "$KEYSTORE_PASSWORD" \
        -alias "$KEY_ALIAS_VALUE" \
        -file "$cert_path" >/dev/null

    local cert_size_decimal
    cert_size_decimal="$(wc -c < "$cert_path" | tr -d '[:space:]')"
    CERT_SIZE="$(printf '0x%x' "$cert_size_decimal")"
    CERT_HASH="$(shasum -a 256 "$cert_path" | awk '{print $1}')"
    export CERT_SIZE CERT_HASH

    log "Manager package: $MANAGER_PACKAGE"
    log "Manager certificate: size=$CERT_SIZE sha256=$CERT_HASH"
}

build_lkms() {
    local lkm_output_dir="$TEMP_DIR/lkm"
    local kmi
    mkdir -p "$lkm_output_dir"

    for kmi in "${KMIS[@]}"; do
        local image="$DDK_REGISTRY_VALUE/ylarod/ddk-min:${kmi}-${DDK_RELEASE}"
        log "Building LKM for $kmi with $image"
        run_ddk_container "$image" "$lkm_output_dir" "$kmi"
        [[ -s "$lkm_output_dir/${kmi}_kernelsu.ko" ]] || die "Missing LKM output for $kmi"
    done
}

run_ddk_container() {
    local image="$1"
    local lkm_output_dir="$2"
    local kmi="$3"
    local container_command='
                mkdir -p /tmp/repository
                cp -a /source/kernel /tmp/repository/kernel
                cp -a /source/uapi /tmp/repository/uapi
                cd /tmp/repository/kernel
                CONFIG_KSU=m CC=clang make \
                    KSU_MANAGER_PACKAGE="$MANAGER_PACKAGE" \
                    KSU_EXPECTED_SIZE="$CERT_SIZE" \
                    KSU_EXPECTED_HASH="$CERT_HASH" \
                    KSU_VERSION="$KSU_VERSION" \
                    KSU_VERSION_FULL="$KSU_VERSION_FULL"
                llvm-strip -d kernelsu.ko
                cp kernelsu.ko "/output/${KMI}_kernelsu.ko"
                chmod 0644 "/output/${KMI}_kernelsu.ko"
            '

    if [[ "$(basename "$CONTAINER_ENGINE")" == "docker" ]]; then
        "$CONTAINER_ENGINE" run --rm --privileged \
            --platform "$DOCKER_PLATFORM_VALUE" \
            -e KMI="$kmi" \
            -e MANAGER_PACKAGE="$MANAGER_PACKAGE" \
            -e CERT_SIZE="$CERT_SIZE" \
            -e CERT_HASH="$CERT_HASH" \
            -e KSU_VERSION="$KSU_VERSION" \
            -e KSU_VERSION_FULL="$KSU_VERSION_FULL" \
            -v "$PROJECT_ROOT:/source:ro" \
            -v "$lkm_output_dir:/output" \
            "$image" \
            sh -euc "$container_command"
        return
    fi

    # Apple Container 没有 --privileged；DDK 镜像仅编译内核模块，不需要额外设备权限。
    "$CONTAINER_ENGINE" run --rm \
        --platform "$DOCKER_PLATFORM_VALUE" \
        --rosetta \
        -e KMI="$kmi" \
        -e MANAGER_PACKAGE="$MANAGER_PACKAGE" \
        -e CERT_SIZE="$CERT_SIZE" \
        -e CERT_HASH="$CERT_HASH" \
        -e KSU_VERSION="$KSU_VERSION" \
        -e KSU_VERSION_FULL="$KSU_VERSION_FULL" \
        --mount "type=bind,source=$PROJECT_ROOT,target=/source,readonly" \
        --mount "type=bind,source=$lkm_output_dir,target=/output" \
        "$image" \
        sh -euc "$container_command"
}

prepare_rust_workspace() {
    # 在临时副本中注入 LKM/ksuinit，避免污染用户工作区里的生成资源。
    RUST_WORKSPACE="$TEMP_DIR/rust-workspace"
    RUST_TARGET_DIR="$TEMP_DIR/rust-target"
    mkdir -p "$RUST_WORKSPACE" "$RUST_TARGET_DIR"
    cp "$PROJECT_ROOT/Cargo.toml" "$PROJECT_ROOT/Cargo.lock" "$RUST_WORKSPACE/"
    rsync -a "$PROJECT_ROOT/userspace/" "$RUST_WORKSPACE/userspace/"
    rsync -a "$PROJECT_ROOT/uapi/" "$RUST_WORKSPACE/uapi/"
    # ksud 的版本号来自 Git 历史；复制元数据可避免临时工作区生成 0.0.0 版本。
    rsync -a "$PROJECT_ROOT/.git/" "$RUST_WORKSPACE/.git/"
    export RUST_WORKSPACE RUST_TARGET_DIR
}

build_ksuinit() {
    local linker="$LLVM_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang"
    [[ -x "$linker" ]] || die "ksuinit linker not found: $linker"

    log "Building ksuinit"
    CARGO_TARGET_DIR="$RUST_TARGET_DIR" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$linker" \
    RUSTC_WRAPPER="" \
    RUSTFLAGS="-C link-arg=-no-pie" \
        cargo +stable build \
            --manifest-path "$RUST_WORKSPACE/Cargo.toml" \
            --package ksuinit \
            --target aarch64-unknown-linux-musl \
            --release

    local ksuinit_path="$RUST_TARGET_DIR/aarch64-unknown-linux-musl/release/ksuinit"
    [[ -s "$ksuinit_path" ]] || die "ksuinit output is missing"
    cp "$ksuinit_path" "$RUST_WORKSPACE/userspace/ksud/bin/aarch64/ksuinit"
}

stage_lkm_assets() {
    local lkm
    for lkm in "$TEMP_DIR"/lkm/*_kernelsu.ko; do
        [[ -f "$lkm" ]] || die "No LKM assets were generated"
        cp "$lkm" "$RUST_WORKSPACE/userspace/ksud/bin/aarch64/"
    done
}

build_ksud_for_abi() {
    local abi="$1"
    local triple
    local ndk_triple
    local lower_triple
    local upper_triple
    local clang_path
    local cc_variable
    local cxx_variable
    local ar_variable
    local linker_variable
    local bindgen_variable

    triple="$(abi_to_triple "$abi")"
    ndk_triple="$(triple_to_ndk_triple "$triple")"
    lower_triple="$(printf '%s' "$triple" | tr '-' '_')"
    upper_triple="$(printf '%s' "$lower_triple" | tr '[:lower:]' '[:upper:]')"
    clang_path="$LLVM_BIN/${ndk_triple}${ANDROID_API_LEVEL}-clang"
    [[ -x "$clang_path" ]] || die "Android linker not found: $clang_path"

    cc_variable="CC_${lower_triple}"
    cxx_variable="CXX_${lower_triple}"
    ar_variable="AR_${lower_triple}"
    linker_variable="CARGO_TARGET_${upper_triple}_LINKER"
    bindgen_variable="BINDGEN_EXTRA_CLANG_ARGS_${lower_triple}"

    log "Building ksud for $abi ($triple)"
    env \
        "CARGO_TARGET_DIR=$RUST_TARGET_DIR" \
        "KSU_PACKAGE_NAME=$MANAGER_PACKAGE" \
        "RUSTC_WRAPPER=" \
        "$cc_variable=$clang_path" \
        "$cxx_variable=${clang_path}++" \
        "$ar_variable=$LLVM_BIN/llvm-ar" \
        "$linker_variable=$clang_path" \
        "$bindgen_variable=--sysroot=$LLVM_BIN/../sysroot -I$LLVM_BIN/../sysroot/usr/include/$triple" \
        cargo +stable build \
            --manifest-path "$RUST_WORKSPACE/userspace/ksud/Cargo.toml" \
            --target "$triple" \
            --release

    local ksud_path="$RUST_TARGET_DIR/$triple/release/ksud"
    local destination="$PROJECT_ROOT/target/$triple/release/ksud"
    [[ -s "$ksud_path" ]] || die "ksud output is missing for $triple"
    mkdir -p "$(dirname "$destination")"
    cp "$ksud_path" "$destination"
}

build_ksud() {
    local abi
    for abi in "${ABIS[@]}"; do
        build_ksud_for_abi "$abi"
    done
}

build_manager_apk() {
    # Gradle 产物只是中间 APK；最终可发布产物必须继续经过 repack_manager_apk。
    log "Building Gradle release APK"
    (
        cd "$PROJECT_ROOT/manager"
        ./gradlew --no-daemon clean :app:assembleRelease \
            -PKSU_PACKAGE_NAME="$MANAGER_PACKAGE" \
            -PKEYSTORE_FILE="$KEYSTORE_PATH" \
            -PKEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
            -PKEY_ALIAS="$KEY_ALIAS_VALUE" \
            -PKEY_PASSWORD="$KEY_PASSWORD"
    )
}

repack_manager_apk() {
    local args=(
        "$PROJECT_ROOT/repack_apk.py" repack
        -b release
        -t release
        -K "$KEYSTORE_PATH"
        -A "$KEY_ALIAS_VALUE"
        -P "$KEYSTORE_PASSWORD"
        -S "$KEY_PASSWORD"
        --strip
    )
    local abi

    if [[ -n "$OUTPUT_NAME" ]]; then
        args+=(--output-name "$OUTPUT_NAME")
    fi
    for abi in "${ABIS[@]}"; do
        args+=(-a "$abi")
    done

    log "Injecting ksud and signing final APK"
    python3 "${args[@]}"
}

find_final_apk() {
    local final_apk
    if [[ -n "$OUTPUT_NAME" ]]; then
        final_apk="$PROJECT_ROOT/dist/${OUTPUT_NAME}.apk"
    else
        final_apk="$(find "$PROJECT_ROOT/dist" -maxdepth 1 -type f -name '*.apk' -print0 |
            xargs -0 ls -t | head -n 1)"
    fi
    [[ -n "$final_apk" && -f "$final_apk" ]] || die "Final APK was not generated"
    printf '%s\n' "$final_apk"
}

verify_final_apk() {
    local final_apk="$1"
    local build_tools_version
    local build_tools_dir
    local abi
    local package_line
    local actual_package
    local signer_output

    build_tools_version="$(sed -n 's/.*androidBuildToolsVersion.*= "\([^"]*\)".*/\1/p' "$PROJECT_ROOT/manager/build.gradle.kts" | head -n 1)"
    build_tools_dir="$ANDROID_SDK_ROOT/build-tools/$build_tools_version"
    [[ -x "$build_tools_dir/apksigner" ]] || die "apksigner not found under $build_tools_dir"
    [[ -x "$build_tools_dir/aapt" ]] || die "aapt not found under $build_tools_dir"

    signer_output="$("$build_tools_dir/apksigner" verify --verbose --print-certs "$final_apk")"
    printf '%s\n' "$signer_output"
    printf '%s\n' "$signer_output" | grep -Fqi "$CERT_HASH" ||
        die "Final APK signer does not match the configured keystore"

    package_line="$("$build_tools_dir/aapt" dump badging "$final_apk" | head -n 1)"
    printf '%s\n' "$package_line"
    actual_package="$(printf '%s\n' "$package_line" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
    [[ "$actual_package" == "$MANAGER_PACKAGE" ]] ||
        die "Final APK package mismatch: expected $MANAGER_PACKAGE, got $actual_package"

    local archive_listing
    archive_listing="$(unzip -Z1 "$final_apk")"
    for abi in "${ABIS[@]}"; do
        printf '%s\n' "$archive_listing" | grep -qx "lib/$abi/libksud.so" ||
            die "Final APK is missing lib/$abi/libksud.so"
    done

    log "Final APK: $final_apk"
    log "SHA-256: $(shasum -a 256 "$final_apk" | awk '{print $1}')"
}

main() {
    parse_args "$@"
    validate_inputs
    resolve_signing_passwords
    preflight

    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sukisu-release.XXXXXX")"

    local commit_count
    local short_sha
    local branch_name
    local version_tag
    commit_count="$(git -C "$PROJECT_ROOT" rev-list --count HEAD)"
    short_sha="$(git -C "$PROJECT_ROOT" rev-parse --short=8 HEAD)"
    branch_name="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
    version_tag="$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || printf '4.1.3')"
    version_tag="${version_tag#v}"
    KSU_VERSION="$((40000 + commit_count - 2815))"
    KSU_VERSION_FULL="v${version_tag}-${short_sha}@${branch_name}"
    export KSU_VERSION KSU_VERSION_FULL

    prepare_certificate_identity
    build_lkms
    prepare_rust_workspace
    build_ksuinit
    stage_lkm_assets
    build_ksud
    build_manager_apk
    repack_manager_apk

    local final_apk
    final_apk="$(find_final_apk)"
    verify_final_apk "$final_apk"
}

main "$@"
