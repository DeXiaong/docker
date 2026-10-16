#!/bin/bash
# 模拟函数由 source 的生产函数间接调用；每个测试在独立进程中修改 PATH。
# shellcheck disable=SC2031,SC2329
set -euo pipefail

ROOT=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/entrypoint.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [ "$1" = "$2" ] || fail "expected '$1', got '$2'"; }

fixture_cleanup() {
    if [ -n "${WORKER_PID:-}" ]; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$BASE"
}

setup() {
    BASE=$(mktemp -d "${TMPDIR:-/tmp}/git-auto-update-test.XXXXXX")
    trap fixture_cleanup EXIT
    export GIT_CONFIG_GLOBAL="$BASE/gitconfig" GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0 GIT_REPO="$BASE/remote" BRANCH=main
    mkdir -p "$GIT_REPO" "$BASE/bin"
    git -C "$GIT_REPO" init --quiet --initial-branch=main
    git -C "$GIT_REPO" config user.name Test
    git -C "$GIT_REPO" config user.email test@example.invalid
    AU_ROOT="$BASE/state" AU_REPO="$BASE/state/repository.git" AU_RELEASES="$BASE/state/releases"
    mkdir -p "$AU_RELEASES"
    git init --quiet --bare "$AU_REPO"
    AU_STOPPING=0 AU_TASK_PID="" AU_APP_PID="" AU_CANDIDATE=""
    AU_CURRENT="" AU_CURRENT_COMMIT="" AU_FAILED_COMMIT=""
    AU_GIT_TIMEOUT=10 AU_BUILD_TIMEOUT=10 AU_STOP_TIMEOUT=1 AU_KEEP=3
    AU_STOPS=0 AU_STARTS=0
    # 模拟 venv 和 pip，不访问网络、不安装 Python；生产代码仍使用真实 python3。
    cat >"$BASE/bin/python3" <<'STUB'
#!/bin/bash
set -eu
[ "$1" = -m ] && [ "$2" = venv ] || exit 91
mkdir -p "$3/bin"
cat >"$3/bin/python" <<'PIP'
#!/bin/bash
set -eu
requirement="${!#}"
if grep -q FAIL_DEPENDENCY "$requirement"; then exit 42; fi
printf installed >"$(dirname "$0")/../installed"
PIP
chmod +x "$3/bin/python"
STUB
    chmod +x "$BASE/bin/python3"
    export PATH="$BASE/bin:$PATH"
    # 单元测试只模拟进程运行；Git、目录准备、状态切换逻辑使用真实实现。
    au_run() {
        local directory="$1" limit="$2"
        shift 2
        (cd -- "$directory" && timeout "${limit}s" "$@")
    }
    au_start() {
        AU_STARTS=$((AU_STARTS + 1))
        if grep -q FAIL_START "$1/code/main.sh"; then return 1; fi
        AU_RUNNING="$1" AU_APP_PID=mock
    }
    au_stop_app() { AU_STOPS=$((AU_STOPS + 1)); AU_APP_PID=""; }
    au_app_alive() { [ -n "$AU_APP_PID" ]; }
}

commit() {
    printf '%s\n' "$1" >"$GIT_REPO/main.sh"
    git -C "$GIT_REPO" add .
    git -C "$GIT_REPO" commit --quiet -m 'test release'
    COMMIT=$(git -C "$GIT_REPO" rev-parse HEAD)
}

test_validation() {
    au_validate_number test 60 1
    for value in 0 -1 01 1.5 nan inf abc 1000000; do
        if au_validate_number test "$value" 1; then fail "accepted $value"; fi
    done
    printf '../outside\n' >"$AU_ROOT/current"
    if au_load_current; then fail 'accepted invalid state path'; fi
}

test_snapshot_update_and_rollback() {
    commit 'echo v1'
    au_fetch
    equal "$COMMIT" "$AU_FETCHED"
    au_deploy "$AU_FETCHED"
    local first="$AU_CURRENT" original_commit="$COMMIT"
    printf 'user local edits\n' >"$GIT_REPO/main.sh"
    printf 'local config\n' >"$GIT_REPO/untracked-config"
    au_check_update
    equal 'user local edits' "$(cat "$GIT_REPO/main.sh")"
    equal 'local config' "$(cat "$GIT_REPO/untracked-config")"
    equal "$first" "$AU_CURRENT"
    rm "$GIT_REPO/untracked-config"
    commit 'echo v2'
    au_check_update
    local second="$AU_CURRENT" second_commit="$COMMIT"
    [ "$first" != "$second" ] || fail 'release directories were reused'
    equal "$second_commit" "$AU_CURRENT_COMMIT"
    equal 'echo v1' "$(cat "$first/code/main.sh")"
    commit FAIL_START
    au_check_update
    equal "$second" "$AU_CURRENT"
    equal "$second" "$AU_RUNNING"
    equal "$COMMIT" "$AU_FAILED_COMMIT"
    equal "${second##*/}" "$(cat "$AU_ROOT/current")"
    local starts="$AU_STARTS"
    au_check_update
    equal "$starts" "$AU_STARTS"
    au_load_current
    equal "$second_commit" "$AU_CURRENT_COMMIT"
    equal "$original_commit" "$(cat "$first/commit")"
}

test_dependency_failure_does_not_stop_old_service() {
    commit 'echo v1'
    au_fetch && au_deploy "$AU_FETCHED"
    local previous="$AU_CURRENT" stops="$AU_STOPS"
    printf 'FAIL_DEPENDENCY\n' >"$GIT_REPO/requirements.txt"
    commit 'echo bad-dependency'
    au_check_update
    equal "$previous" "$AU_CURRENT"
    equal "$stops" "$AU_STOPS"
    [ -z "$AU_CANDIDATE" ] || fail 'failed candidate not cleaned'
    equal 1 "$(find "$AU_RELEASES" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
}

test_network_failure_does_not_stop_old_service() {
    commit 'echo v1'
    au_fetch && au_deploy "$AU_FETCHED"
    local previous="$AU_CURRENT" stops="$AU_STOPS"
    mv "$GIT_REPO" "$GIT_REPO.offline"
    au_check_update
    equal "$previous" "$AU_CURRENT"
    equal "$stops" "$AU_STOPS"
}

test_failed_rollback_is_fatal() {
    commit 'echo v1'
    au_fetch && au_deploy "$AU_FETCHED"
    commit FAIL_START
    au_start() { return 1; }
    if au_check_update; then fail 'rollback failure was ignored'; fi
}

test_release_cleanup_protects_current_and_previous() {
    local i path
    for i in 1 2 3 4 5 6; do
        path="$AU_RELEASES/release$i"
        mkdir -p "$path"
        touch "$path/.ready"
        touch -t "20260101000$i" "$path"
    done
    AU_CURRENT="$AU_RELEASES/release1"
    au_cleanup "$AU_RELEASES/release2"
    [ -d "$AU_RELEASES/release1" ] && [ -d "$AU_RELEASES/release2" ] || fail 'protected release deleted'
    [ ! -d "$AU_RELEASES/release3" ] || fail 'obsolete release retained'
    [ -d "$AU_RELEASES/release4" ] && [ -d "$AU_RELEASES/release6" ] || fail 'recent release deleted'
}

wait_for_text() {
    local file="$1" text="$2" i
    for ((i=0; i<200; i++)); do
        if [ -f "$file" ] && grep -q -- "$text" "$file"; then return 0; fi
        kill -0 "$WORKER_PID" 2>/dev/null || { cat "$BASE/worker.log"; fail 'worker exited'; }
        sleep 0.1
    done
    cat "$BASE/worker.log"
    fail "timed out waiting for $text"
}

start_worker() {
    bash -c 'source "$1"; au_main' _ "$ROOT/entrypoint.sh" >"$BASE/worker.log" 2>&1 &
    WORKER_PID=$!
}

stop_worker() {
    kill -TERM "$WORKER_PID"
    wait "$WORKER_PID" || fail 'signal shutdown did not exit cleanly'
    WORKER_PID=""
}

test_linux_supervision_lock_health_and_signals() {
    if ! command -v setsid >/dev/null || ! command -v flock >/dev/null; then
        printf 'SKIP: Linux setsid/flock are unavailable\n'
        return 0
    fi
    export UPDATE_STATE_DIR="$BASE/persistent" UPDATE_INTERVAL=1
    export STARTUP_GRACE_SECONDS=1 HEALTHCHECK_TIMEOUT=3 STOP_TIMEOUT=1
    export RUN_COMMAND='bash main.sh' TEST_MARKER="$BASE/marker" TEST_PID_FILE="$BASE/app.pid"
    export TEST_HEALTH="$BASE/health" HEALTHCHECK_URL=http://127.0.0.1/health
    # 模拟 HTTP 检查响应，测试真实后台进程的健康失败回滚。
    cat >"$BASE/bin/curl" <<'CURL'
#!/bin/bash
grep -q '^healthy$' "$TEST_HEALTH"
CURL
    chmod +x "$BASE/bin/curl"
    local v1 v2 bad app_pid
    # 命令中的变量由后端子进程展开，而非测试进程。
    # shellcheck disable=SC2016
    v1='printf "v1\n" >"$TEST_MARKER"; echo $$ >"$TEST_PID_FILE"; echo healthy >"$TEST_HEALTH"; trap "exit 0" TERM INT; while :; do sleep 1; done'
    v2="${v1/v1/v2}"
    bad="${v2/echo healthy/echo unhealthy}"
    commit "$v1"
    start_worker
    wait_for_text "$BASE/marker" v1
    wait_for_text "$BASE/worker.log" '每 1 秒'
    if bash -c 'source "$1"; au_main' _ "$ROOT/entrypoint.sh" >"$BASE/lock.log" 2>&1; then
        fail 'duplicate supervisor acquired the lock'
    fi
    commit "$v2"
    wait_for_text "$BASE/worker.log" "版本 ${COMMIT:0:12} 已通过"
    commit "$bad"
    wait_for_text "$BASE/worker.log" '恢复旧版本'
    wait_for_text "$BASE/worker.log" '同一提交本次运行不再重试'
    equal v2 "$(cat "$BASE/marker")"
    equal healthy "$(cat "$BASE/health")"
    app_pid=$(cat "$BASE/app.pid")
    stop_worker
    if kill -0 "$app_pid" 2>/dev/null; then fail 'backend survived supervisor shutdown'; fi
    # 远程不可用时，仍能从持久化状态启动已经验证的旧版。
    mv "$GIT_REPO" "$GIT_REPO.offline"
    rm "$BASE/marker"
    start_worker
    wait_for_text "$BASE/marker" v2
    wait_for_text "$BASE/worker.log" 'Git 检查失败'
    stop_worker
}

if [ "$#" -gt 0 ]; then
    setup
    "$1"
    exit 0
fi

failed=0
for test in test_validation test_snapshot_update_and_rollback \
    test_dependency_failure_does_not_stop_old_service test_network_failure_does_not_stop_old_service \
    test_failed_rollback_is_fatal test_release_cleanup_protects_current_and_previous \
    test_linux_supervision_lock_health_and_signals; do
    printf '\n== %s ==\n' "$test"
    if bash "${BASH_SOURCE[0]}" "$test"; then
        printf 'PASS\n'
    else
        failed=$((failed + 1))
    fi
done
[ "$failed" = 0 ] || fail "$failed tests failed"
