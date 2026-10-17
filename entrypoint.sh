#!/bin/bash

set -euo pipefail

# 自动更新管理器：Bash 调度，内嵌 Python 标准库同步代码，使用镜像内工具。
au_log() { printf '[auto-update] %s\n' "$*"; }

au_validate_number() {
    local name="$1" value="$2" minimum="$3"
    if ! [[ "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]] || (( value < minimum )); then
        au_log "[error] $name 必须为 $minimum 到 999999 之间的整数"
        return 1
    fi
}

au_stop_group() {
    local pid="${1:-}" i
    [ -n "$pid" ] || return 0
    # 信号可能早于 setsid 完成，此时直接终止尚未建立进程组的子进程。
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for ((i=0; i<AU_STOP_TIMEOUT*10; i++)); do
        kill -0 -- "-$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

au_signal() {
    AU_STOPPING=1
    if [ -n "${AU_TASK_PID:-}" ]; then
        kill -TERM -- "-$AU_TASK_PID" 2>/dev/null || kill -TERM "$AU_TASK_PID" 2>/dev/null || true
    fi
    if [ -n "${AU_APP_PID:-}" ]; then
        kill -TERM -- "-$AU_APP_PID" 2>/dev/null || kill -TERM "$AU_APP_PID" 2>/dev/null || true
    fi
}

au_stop_app() {
    au_stop_group "${AU_APP_PID:-}"
    AU_APP_PID=""
}

au_discard_candidate() {
    if [ -n "${AU_CANDIDATE:-}" ] && [ "$AU_CANDIDATE" != "${AU_CURRENT:-}" ]; then
        rm -rf -- "$AU_CANDIDATE"
    fi
    AU_CANDIDATE=""
}

au_exit() {
    local status=$?
    trap - EXIT
    au_stop_group "${AU_TASK_PID:-}"
    au_stop_app
    au_discard_candidate
    [ "$AU_STOPPING" = 0 ] || status=0
    exit "$status"
}

# 不使用命令替换运行耗时任务，确保主 shell 始终持有 PID 并能传递停止信号。
au_run() {
    local directory="$1" limit="$2" status=0
    shift 2
    [ "$AU_STOPPING" = 0 ] || return 130
    (
        cd -- "$directory" || exit 1
        exec setsid timeout --signal=TERM --kill-after="${AU_STOP_TIMEOUT}s" "${limit}s" "$@"
    ) &
    AU_TASK_PID=$!
    wait "$AU_TASK_PID" || status=$?
    if [ "$AU_STOPPING" != 0 ]; then
        au_stop_group "$AU_TASK_PID"
        status=130
    fi
    AU_TASK_PID=""
    return "$status"
}

au_fetch() {
    # Git 的诊断可能包含认证 URL，不把它输出到容器日志。
    if ! au_run "$AU_ROOT" "$AU_GIT_TIMEOUT" git --git-dir "$AU_REPO" \
        fetch --no-tags --force "$GIT_REPO" "$BRANCH" >"$AU_ROOT/git.log" 2>&1; then
        return 1
    fi
    AU_FETCHED=$(git --git-dir "$AU_REPO" rev-parse --verify 'FETCH_HEAD^{commit}') || return 1
    [[ "$AU_FETCHED" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

au_prepare() {
    local commit="$1"
    AU_CANDIDATE=$(mktemp -d "$AU_RELEASES/$commit.XXXXXX") || return 1
    au_log "准备版本 ${commit:0:12}，旧服务继续运行"
    au_run "$AU_ROOT" "$AU_BUILD_TIMEOUT" git clone --quiet --no-hardlinks --no-checkout \
        "$AU_REPO" "$AU_CANDIDATE/code" >"$AU_ROOT/build-git.log" 2>&1 || return 1
    au_run "$AU_ROOT" "$AU_BUILD_TIMEOUT" git -C "$AU_CANDIDATE/code" \
        checkout --quiet --detach "$commit" >>"$AU_ROOT/build-git.log" 2>&1 || return 1
    printf '%s\n' "$commit" >"$AU_CANDIDATE/commit" || return 1
    au_dependency_manifest "$AU_CANDIDATE" || return 1
    touch "$AU_CANDIDATE/.ready" || return 1
}

# 指纹只覆盖依赖输入；普通业务代码变化不会触发 pip。
au_dependency_manifest() {
    local release="$1" program
    program=$(cat <<'PY'
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

release = Path(sys.argv[1])
source = (release / "code").resolve()
tracked = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"])
names = sorted(os.fsdecode(name) for name in tracked.split(b"\0") if name)
names = [name for name in names if not {".git", ".venv", "venv"} & set(Path(name).parts)]
requirements = [name for name in names if Path(name).name == "requirements.txt"]
digest = hashlib.sha256()
digest.update(("dependencies-v1\n" + sys.version + "\n" + platform.machine()).encode())
seen = set()
local_dependency = False

def include(path):
    global local_dependency
    path = path.resolve()
    name = path.relative_to(source).as_posix()
    if name in seen:
        return
    seen.add(name)
    content = path.read_bytes()
    digest.update(name.encode() + b"\0" + content + b"\0")
    if path.suffix != ".txt":
        return
    for line in content.decode("utf-8-sig").replace("\\\n", "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(?:-r\s*|-c\s*|--requirement(?:=|\s+)|--constraint(?:=|\s+))(.+)", line)
        if match:
            value = re.split(r"\s+#", match.group(1), maxsplit=1)[0].strip().strip("'\"")
            if "://" in value or chr(36) + "{" in value:
                local_dependency = True
            else:
                include(path.parent / value)
        elif (line.startswith((".", "/", "-e ", "--editable", "file:"))
              or " @ file:" in line or chr(36) + "{" in line
              or (source / line).exists() or (path.parent / line).exists()):
            local_dependency = True

for name in requirements:
    include(source / name)
for name in names:
    if Path(name).name in {"pyproject.toml", "setup.py", "setup.cfg"}:
        include(source / name)
# 本地包/动态依赖不能只看 requirements；它们随代码提交重新安装。
if local_dependency:
    digest.update((release / "commit").read_bytes())
(release / "requirements.list").write_bytes(b"".join(os.fsencode(name) + b"\0" for name in requirements))
(release / "requirements.sha256").write_text(digest.hexdigest() + "\n", encoding="ascii")
PY
    ) || return 1
    au_run "$AU_ROOT" "$AU_BUILD_TIMEOUT" python3 -c "$program" "$release"
}

au_install_dependencies() {
    local release="$1" fingerprint requirement installed="" status
    local stamp="$AU_VENV/.requirements.sha256"
    [ ! -L "$AU_VENV" ] && [ ! -L "$stamp" ] || {
        au_log "[error] 共享虚拟环境及依赖标记不能是软链接"; return 1;
    }
    fingerprint=$(cat "$release/requirements.sha256") || return 1
    if [ ! -x "$AU_VENV/bin/python" ]; then
        au_log "创建共享依赖环境 $AU_VENV"
        au_run "$AU_ROOT" "$AU_BUILD_TIMEOUT" python3 -m venv "$AU_VENV" || return 1
        rm -f -- "$stamp"
    fi
    if [ -f "$stamp" ]; then installed=$(cat "$stamp") || return 1; fi
    if [ "$installed" = "$fingerprint" ]; then
        au_log "依赖未变化，复用 $AU_VENV，跳过安装"
        return 0
    fi
    # pip 可能安装了一部分包才失败；不得留下表示环境完整的旧标记。
    rm -f -- "$stamp" || return 1
    while IFS= read -r -d '' requirement; do
        au_log "同步依赖：$requirement → $AU_VENV"
        if VIRTUAL_ENV="$AU_VENV" PATH="$AU_VENV/bin:$PATH" \
            au_run "$(dirname "$AU_APP_DIR/$requirement")" "$AU_BUILD_TIMEOUT" \
            "$AU_VENV/bin/python" -m pip install --disable-pip-version-check \
            -r "$AU_APP_DIR/$requirement"; then
            :
        else
            status=$?
            if [ "$status" = 124 ]; then
                au_log "[error] 依赖安装超过 $AU_BUILD_TIMEOUT 秒"
            elif [ "$status" = 137 ]; then
                au_log "[error] 依赖安装被 SIGKILL 强制终止，请检查内存限制及超时"
            else
                au_log "[error] 依赖安装失败，退出码 $status"
            fi
            return 1
        fi
    done <"$release/requirements.list"
    au_run "$AU_APP_DIR" "$AU_BUILD_TIMEOUT" "$AU_VENV/bin/python" -m pip check || return 1
    printf '%s\n' "$fingerprint" >"$stamp.tmp" && mv -f -- "$stamp.tmp" "$stamp"
}

au_app_alive() {
    [ -n "${AU_APP_PID:-}" ] && kill -0 "$AU_APP_PID" 2>/dev/null
}

# 运行目录固定为 /app；只替换 Git 管理的文件，保留本地配置和运行数据。
au_sync_app() {
    local release="$1" program
    program=$(cat <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile

source, target = map(Path, sys.argv[1:3])
reserved = {".auto-update-files.json", ".auto-update.lock", ".venv"}

def protected(name):
    return any(part == ".git" or part in reserved or part == ".env"
               or part.startswith(".env.") for part in PurePosixPath(name).parts)

def checked(names):
    result = set()
    for name in names:
        if not isinstance(name, str) or not name or "\\" in name or "\0" in name:
            raise ValueError("invalid managed file name")
        path = PurePosixPath(name)
        if path.is_absolute() or Path(name).drive or any(part in {".", ".."} for part in name.split("/")):
            raise ValueError("managed path must stay inside /app")
        if not protected(name):
            result.add(name)
    return result

def git_files(directory):
    data = subprocess.check_output(["git", "-C", str(directory), "ls-files", "-z"])
    return checked(os.fsdecode(name) for name in data.split(b"\0") if name)

def write_manifest(names):
    fd, temporary = tempfile.mkstemp(prefix=".auto-update-manifest-", dir=target)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(sorted(names), stream)
        os.replace(temporary, manifest)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def validate_parents(name):
    # 不跟随本地目录中的软链接，以免代码复制或清理写到 /app 外。
    for parent in (target / name).parents:
        if parent == target:
            break
        if parent.is_symlink():
            raise ValueError("managed file parent is a symlink: " + name)
        if parent.exists() and not parent.is_dir() and parent.relative_to(target).as_posix() not in obsolete:
            raise ValueError("local file blocks code directory: " + name)

try:
    if not target.is_absolute() or target.is_symlink():
        raise ValueError("application directory must be an absolute, real directory")
    target.mkdir(parents=True, exist_ok=True)
    target = target.resolve()
    manifest = target / ".auto-update-files.json"
    current = git_files(source)
    if manifest.is_symlink():
        raise ValueError("managed file manifest must not be a symlink")
    if manifest.exists():
        previous = checked(json.loads(manifest.read_text(encoding="utf-8")))
    elif (target / ".git").exists():
        previous = git_files(target)
    else:
        previous = set()
    obsolete = previous - current
    for name in current | previous:
        validate_parents(name)
    for name in current:
        src = source / name
        if not src.is_file() and not src.is_symlink():
            raise ValueError("unsupported Git entry: " + name)

    # 先登记所有可能改动的路径；中途失败后，回滚也能删除新版新增文件。
    write_manifest(previous | current)
    for name in sorted(obsolete, key=lambda value: value.count("/"), reverse=True):
        destination = target / name
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        parent = destination.parent
        while parent != target:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent

    for name in sorted(current):
        src, destination = source / name, target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_dir() and not destination.is_symlink():
            # 非空目录可能包含用户数据，不能为了替换代码而递归删除。
            destination.rmdir()
        fd, temporary = tempfile.mkstemp(prefix=".auto-update-copy-", dir=destination.parent)
        os.close(fd)
        try:
            if src.is_symlink():
                os.unlink(temporary)
                os.symlink(os.readlink(src), temporary)
            else:
                shutil.copy2(src, temporary)
            os.replace(temporary, destination)
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)
    write_manifest(current)
except Exception as error:
    print("[auto-update] /app code sync failed: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
    ) || return 1
    au_run "$AU_ROOT" "$AU_BUILD_TIMEOUT" python3 -c "$program" "$release/code" "$AU_APP_DIR"
}

au_start() {
    local release="$1" started commit remaining
    commit=$(cat "$release/commit") || return 1
    au_dependency_manifest "$release" || return 1
    au_sync_app "$release" || return 1
    au_install_dependencies "$release" || return 1
    started=$SECONDS
    au_log "启动版本 ${commit:0:12}，运行目录 $AU_APP_DIR"
    (
        cd -- "$AU_APP_DIR" || exit 1
        export VIRTUAL_ENV="$AU_VENV" PATH="$AU_VENV/bin:$PATH"
        export PYTHONUNBUFFERED=1 APP_COMMIT="$commit"
        unset PYTHONHOME
        exec setsid bash -c "${RUN_COMMAND:-python3 main.py}"
    ) &
    AU_APP_PID=$!
    while [ "$AU_STOPPING" = 0 ]; do
        if ! au_app_alive; then
            au_log "[warn] 后端在启动观察期内退出"
            return 1
        fi
        if (( SECONDS - started >= AU_GRACE )); then
            if [ -z "$AU_HEALTH_URL" ]; then
                return 0
            fi
            remaining=$((AU_HEALTH_TIMEOUT - (SECONDS - started)))
            if (( remaining <= 0 )); then
                au_log "[warn] 健康检查超时"
                return 1
            fi
            (( remaining <= 2 )) || remaining=2
            if au_run "$AU_ROOT" 3 curl --noproxy '*' --fail --silent --output /dev/null \
                --max-time "$remaining" "$AU_HEALTH_URL" && au_app_alive; then
                return 0
            fi
        fi
        if (( SECONDS - started >= AU_HEALTH_TIMEOUT )); then
            au_log "[warn] 健康检查超时"
            return 1
        fi
        au_run "$AU_ROOT" 2 sleep 1 || return 1
    done
    return 1
}

au_load_current() {
    local name
    AU_CURRENT="" AU_CURRENT_COMMIT=""
    [ -f "$AU_ROOT/current" ] || return 0
    IFS= read -r name <"$AU_ROOT/current" || return 1
    [[ "$name" =~ ^[0-9a-f]{40}([0-9a-f]{24})?\.[a-zA-Z0-9]+$ ]] || return 1
    AU_CURRENT="$AU_RELEASES/$name"
    [ -f "$AU_CURRENT/.ready" ] && [ -d "$AU_CURRENT/code" ] || return 1
    AU_CURRENT_COMMIT=$(cat "$AU_CURRENT/commit") || return 1
    [ "${name%%.*}" = "$AU_CURRENT_COMMIT" ]
}

au_save_current() {
    printf '%s\n' "${AU_CANDIDATE##*/}" >"$AU_ROOT/current.tmp" && \
        mv -f -- "$AU_ROOT/current.tmp" "$AU_ROOT/current"
}

au_cleanup() {
    local previous="$1" entry directory count=0
    while IFS= read -r -d '' entry; do
        directory="${entry#* }"
        [ -f "$directory/.ready" ] || continue
        count=$((count + 1))
        if (( count > AU_KEEP )) && [ "$directory" != "$AU_CURRENT" ] && [ "$directory" != "$previous" ]; then
            rm -rf -- "$directory" || return 1
        fi
    done < <(find "$AU_RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\0' | sort -z -nr)
}

# 返回 1：候选版本失败、旧版仍可用；返回 2：无法恢复服务。
au_deploy() {
    local commit="$1" previous="$AU_CURRENT" failed=0
    if ! au_prepare "$commit"; then
        au_log "[warn] 新版本准备失败，不切换旧服务"
        au_discard_candidate
        return 1
    fi
    if [ "$AU_STOPPING" != 0 ]; then
        au_discard_candidate
        return 1
    fi
    au_stop_app
    au_start "$AU_CANDIDATE" || failed=1
    if [ "$failed" = 0 ]; then
        au_save_current || failed=1
    fi
    if [ "$failed" != 0 ]; then
        au_stop_app
        au_discard_candidate
        if [ -n "$previous" ] && [ "$AU_STOPPING" = 0 ]; then
            au_log "新版本不可用，恢复旧版本"
            au_start "$previous" || return 2
        fi
        return 1
    fi
    AU_CURRENT="$AU_CANDIDATE" AU_CURRENT_COMMIT="$commit" AU_CANDIDATE=""
    au_log "版本 ${commit:0:12} 已通过检查并启用"
    au_cleanup "$previous" || au_log "[warn] 清理旧版本失败，不影响当前服务"
}

au_check_update() {
    local status
    if ! au_fetch; then
        [ "$AU_STOPPING" != 0 ] || au_log "[warn] Git 检查失败，保持当前服务，下次重试"
        return 0
    fi
    if [ "$AU_FETCHED" = "$AU_CURRENT_COMMIT" ]; then
        AU_FAILED_COMMIT=""
        return 0
    fi
    [ "$AU_FETCHED" != "$AU_FAILED_COMMIT" ] || return 0
    if au_deploy "$AU_FETCHED"; then
        AU_FAILED_COMMIT=""
    else
        status=$?
        AU_FAILED_COMMIT="$AU_FETCHED"
        au_log "[warn] 更新失败，同一提交本次运行不再重试"
        [ "$status" != 2 ] || return 1
        [ "$AU_STOPPING" != 0 ] || au_app_alive || return 1
    fi
}

au_main() {
    local key tool name value minimum next_check
    umask 077
    set +m
    AU_STOPPING=0 AU_TASK_PID="" AU_APP_PID="" AU_CANDIDATE=""
    AU_CURRENT="" AU_CURRENT_COMMIT="" AU_FAILED_COMMIT=""
    AU_INTERVAL="${UPDATE_INTERVAL:-60}" AU_GIT_TIMEOUT="${GIT_TIMEOUT:-60}"
    AU_BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}" AU_STOP_TIMEOUT="${STOP_TIMEOUT:-20}"
    AU_GRACE="${STARTUP_GRACE_SECONDS:-10}" AU_HEALTH_TIMEOUT="${HEALTHCHECK_TIMEOUT:-60}"
    AU_KEEP="${UPDATE_KEEP_RELEASES:-3}" AU_HEALTH_URL="${HEALTHCHECK_URL:-}"
    for name in INTERVAL GIT_TIMEOUT BUILD_TIMEOUT STOP_TIMEOUT GRACE HEALTH_TIMEOUT KEEP; do
        value="AU_$name" minimum=1
        [ "$name" != GRACE ] || minimum=0
        [ "$name" != KEEP ] || minimum=2
        au_validate_number "$value" "${!value}" "$minimum" || return 1
    done
    if (( AU_HEALTH_TIMEOUT < AU_GRACE )); then
        au_log "[error] HEALTHCHECK_TIMEOUT 不能小于 STARTUP_GRACE_SECONDS"
        return 1
    fi
    case "$AU_HEALTH_URL" in
        ''|http://*|https://*) ;;
        *) au_log "[error] HEALTHCHECK_URL 必须使用 http:// 或 https://"; return 1 ;;
    esac
    [ -n "${BRANCH:-}" ] && [[ "$BRANCH" != -* ]] || return 1
    for tool in git python3 curl setsid flock timeout sha256sum find sort; do
        command -v "$tool" >/dev/null || { au_log "[error] 缺少命令 $tool，请重建镜像"; return 1; }
    done
    # 排除凭据，使 Token 轮换不影响已验证版本的缓存。
    key=$(printf '%s' "${GIT_REPO##*@}#$BRANCH" | sha256sum) || return 1
    mkdir -p -- "${UPDATE_STATE_DIR:-/config/auto-update}" || return 1
    AU_ROOT=$(cd -- "${UPDATE_STATE_DIR:-/config/auto-update}" && pwd) || return 1
    AU_APP_DIR="${TARGET_DIR:-/app}"
    AU_VENV="$AU_APP_DIR/.venv"
    mkdir -p -- "$AU_APP_DIR" || return 1
    [ ! -L "$AU_APP_DIR" ] && [ ! -L "$AU_APP_DIR/.auto-update.lock" ] || {
        au_log "[error] 应用目录和运行锁不能是软链接"; return 1;
    }
    exec {AU_APP_LOCK_FD}>"$AU_APP_DIR/.auto-update.lock"
    flock -n "$AU_APP_LOCK_FD" || { au_log "[error] /app 已有更新管理器运行"; return 1; }
    AU_ROOT="$AU_ROOT/${key:0:16}"
    AU_REPO="$AU_ROOT/repository.git"
    AU_RELEASES="$AU_ROOT/releases"
    mkdir -p -- "$AU_RELEASES" || return 1
    exec {AU_LOCK_FD}>"$AU_ROOT/update.lock"
    flock -n "$AU_LOCK_FD" || { au_log "[error] 同一仓库已有更新管理器运行"; return 1; }
    trap au_signal TERM INT
    trap au_exit EXIT
    if [ ! -d "$AU_REPO" ]; then
        au_run "$AU_ROOT" "$AU_GIT_TIMEOUT" git init --bare "$AU_REPO" \
            >"$AU_ROOT/git.log" 2>&1 || return 1
    fi
    au_load_current || { au_log "[error] 当前版本记录不完整"; return 1; }
    if [ -n "$AU_CURRENT" ]; then
        au_log "先启动已验证缓存版本，再检查远程更新"
        au_start "$AU_CURRENT" || return 1
        next_check=$SECONDS
    else
        au_fetch || { au_log "[error] 首次拉取 Git 失败，无缓存版本可用"; return 1; }
        au_deploy "$AU_FETCHED" || return 1
        next_check=$((SECONDS + AU_INTERVAL))
    fi
    au_log "每 $AU_INTERVAL 秒检查分支 $BRANCH"
    [ -n "$AU_HEALTH_URL" ] || au_log "[warn] 未设置 HEALTHCHECK_URL，仅检查进程存活"
    while [ "$AU_STOPPING" = 0 ]; do
        au_app_alive || { au_log "[error] 后端意外退出，交由 Docker 重启"; return 1; }
        if (( SECONDS >= next_check )); then
            au_check_update || return 1
            next_check=$((SECONDS + AU_INTERVAL))
        fi
        au_run "$AU_ROOT" 2 sleep 1 || { [ "$AU_STOPPING" != 0 ] || return 1; }
    done
    au_log "更新管理器已停止"
}

# 允许测试只加载上面的函数，不执行容器启动逻辑。
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# 设置环境变量、工作目录等（如果需要）
# 例如：
# export PYTHONPATH=/app


# 验证环境变量
# echo "GITHUB_PAT: ${GITHUB_PAT}"
# echo "GITHUB_USERNAME: ${GITHUB_USERNAME}"
# echo "GITHUB_REPO: ${GITHUB_REPO}"

# 判断使用 Gitee 还是 GitHub
if [ -n "${GITEE_TOKEN:-}" ]; then
    # 使用 Gitee 配置
    echo "检测到 Gitee 配置,使用 Gitee 仓库"
    GIT_REPO="https://gitee.com/${GITEE_USERNAME}/${GITHUB_REPO}.git"
else
    # 使用 GitHub 配置
    echo "使用 GitHub 仓库"
    GIT_REPO="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
fi

TARGET_DIR="/app"
BRANCH="${BRANCH:-main}"

# 小函数：判断目录是否为空
is_empty_dir() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# 配置代理（如果设置了 PROXY_HOST 且不为空）
if [ -n "${PROXY_HOST:-}" ] && [ "${PROXY_HOST}" != "" ]; then
    echo "配置代理: $PROXY_HOST"
    export http_proxy="${PROXY_HOST}"
    export https_proxy="${PROXY_HOST}"
    export HTTP_PROXY="${PROXY_HOST}"
    export HTTPS_PROXY="${PROXY_HOST}"
    export ALL_PROXY="${PROXY_HOST}"
    export all_proxy="${PROXY_HOST}"
    
    # Git 不支持 SOCKS5 代理,只为 HTTP/HTTPS 代理配置 Git
    if [[ "${PROXY_HOST}" == http://* ]] || [[ "${PROXY_HOST}" == https://* ]]; then
        git config --global http.proxy "${PROXY_HOST}"
        git config --global https.proxy "${PROXY_HOST}"
        echo "Git 已配置代理"
    else
        echo "检测到 SOCKS5 代理,Git 将直连(不支持 SOCKS5)"
    fi
else
    echo "未设置代理，直连 Git 仓库"
fi

# 配置 Git 认证
echo "配置 Git 认证..."
# 禁用交互式密码提示
git config --global core.askPass ""
git config --global credential.helper store

# 根据平台配置认证信息
if [ -n "${GITEE_TOKEN:-}" ]; then
    echo "https://${GITEE_USERNAME}:${GITEE_TOKEN}@gitee.com" > ~/.git-credentials
    echo "使用 Gitee 认证"
else
    : > ~/.git-credentials
    if [ -n "${GITHUB_PAT:-}" ]; then
        echo "https://${GITHUB_USERNAME}:${GITHUB_PAT}@github.com" > ~/.git-credentials
    fi
    echo "使用 GitHub 认证"
fi
chmod 600 ~/.git-credentials

# 设置 Git 环境变量，避免密码提示
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# 自动更新在缓存目录准备版本，再将受管代码同步到 /app；保留本地 .env 和运行文件。
# 在旧的同步、安装依赖逻辑之前分流，依赖统一安装在 /app/.venv，未变化时跳过安装。
case "${AUTO_UPDATE:-false}" in
    true)
        if [ -d /data ] && ! is_empty_dir /data; then
            echo "[error] AUTO_UPDATE=true 与非空 /data 文件同步模式不能同时使用。"
            exit 1
        fi
        export GIT_REPO BRANCH
        au_main
        exit 0
        ;;
    false) ;;
    *)
        echo "[error] AUTO_UPDATE 必须为 true 或 false。"
        exit 1
        ;;
esac


# 如果是 Debian/Ubuntu 基础镜像
# 安装系统依赖（用于编译 asyncpg 和 psycopg2）
echo "安装系统依赖..."
if command -v apt-get &> /dev/null; then
    # Debian/Ubuntu (apt-get 不支持 SOCKS5,临时取消代理)
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
        apt-get update && \
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
        apt-get install -y libpq-dev gcc python3-dev && \
    rm -rf /var/lib/apt/lists/*
elif command -v apk &> /dev/null; then
    # Alpine
    apk add --no-cache postgresql-dev gcc python3-dev musl-dev
fi


ACTION="none"
DATA_DIR="/data"

# 检查是否挂载了 data 目录
if [ -d "$DATA_DIR" ] && ! is_empty_dir "$DATA_DIR"; then
    echo "检测到 data 目录挂载，准备同步..."
    
    # 清空 /app 目录（保留 .git 如果存在）
    if [ -d "$TARGET_DIR/.git" ]; then
        # 保留 .git 目录，清空其他内容
        find "$TARGET_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    else
        # 清空整个目录
        rm -rf "${TARGET_DIR:?}"/*
    fi
    
    # 硬链接 data 目录中的文件（排除 .git）
    echo "从 $DATA_DIR 硬链接文件到 $TARGET_DIR..."
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' | while read -r item; do
        ln -f "$item" "$TARGET_DIR/" 2>/dev/null || cp -a "$item" "$TARGET_DIR/"
    done
    
    ACTION="link"
fi

# 如果没有 data 目录或 data 目录为空，执行原有的克隆/更新逻辑
if [ "$ACTION" = "none" ]; then
    # 检查 /app 目录是否已存在 Git 仓库或为空
    if [ -d "$TARGET_DIR/.git" ] && git -C "$TARGET_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        # 如果存在有效的 Git 仓库，进入目录并更新代码
        echo "更新现有仓库在 $TARGET_DIR..."
        if git -C "$TARGET_DIR" fetch origin "$BRANCH" && git -C "$TARGET_DIR" reset --hard FETCH_HEAD; then
            ACTION="pull"
        else
            echo "[warn] Git 更新失败，使用现有文件"
            ACTION="skip"
        fi
    elif is_empty_dir "$TARGET_DIR"; then
        # 如果目录为空，克隆新的仓库
        echo "从储存库克隆到 $TARGET_DIR..."
        git clone -b "$BRANCH" "$GIT_REPO" "$TARGET_DIR"
        ACTION="clone"
    else
        # 目录非空且不是 Git 仓库（多见于挂载了宿主机目录）
        echo "[warn] $TARGET_DIR 非空且不是 Git 仓库，跳过 clone，使用现有文件。"
        ACTION="skip"
    fi
fi

# 根据执行结果给出提示
if [ "$ACTION" = "clone" ] || [ "$ACTION" = "pull" ]; then
    echo "从储存库$([ "$ACTION" = "clone" ] && echo 克隆 || echo 更新)成功."
elif [ "$ACTION" = "link" ]; then
    echo "从 data 目录同步文件完成."
else
    # 跳过 clone 的场景：不视为失败，但提示如何切换到'仓库模式'
    echo "已跳过从储存库克隆/更新（目录非空且非 Git 仓库）。若需使用 Git，请清空 $TARGET_DIR 或更改 TARGET_DIR 至空目录（例如 /src）。"
fi

# 进入目标目录
cd "$TARGET_DIR"

# 更新依赖
pip install --upgrade -i https://mirrors.aliyun.com/pypi/simple/ pip
# 查找所有 requirements.txt 文件，并对每个文件执行 pip install
if find . -name "requirements.txt" -print0 | while IFS= read -r -d '' file; do
    echo "找到 requirements.txt in: $(dirname "$file")"
    echo "安装依赖 $file..."
    pip install -r "$file" || exit 1
done; then
    echo "所有依赖已更新完毕."
else
    echo "更新依赖失败,退出"
    exit 1
fi

# 启动你的应用
# 使用 RUN_COMMAND 环境变量或默认命令
if [ -n "${RUN_COMMAND:-}" ] && [ "${RUN_COMMAND}" != "" ]; then
    echo "使用自定义启动命令: $RUN_COMMAND"
    exec $RUN_COMMAND
else
    echo "使用默认启动命令: python3 main.py"
    exec python3 main.py
fi
