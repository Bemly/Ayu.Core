# test/test_maint.sh — log rotation and temp cleanup

test_maint_rotate_below_threshold() {
    _d="/tmp/test-maint-$$"
    mkdir -p "$_d"
    printf 'hello' > "$_d/a.log"
    maint_rotate "$_d/a.log" 1024 2
    assert_eq "$(cat "$_d/a.log")" "hello" "small file not rotated"
    [ -f "$_d/a.log.1" ] && _r=yes || _r=no
    assert_eq "$_r" "no" "no archive created below threshold"
    rm -rf "$_d"
}

test_maint_rotate_over_threshold() {
    _d="/tmp/test-maint-$$"
    mkdir -p "$_d"
    # ~2 KB of data, threshold 1024 bytes
    i=0
    while [ $i -lt 40 ]; do
        printf '0123456789abcdefghijklmnopqrstuvwxyz0123456789\n' >> "$_d/a.log"
        i=$((i+1))
    done
    maint_rotate "$_d/a.log" 1024 2
    [ -f "$_d/a.log.1" ] && _r=yes || _r=no
    assert_eq "$_r" "yes" "archive created above threshold"
    assert_eq "$(wc -c < "$_d/a.log")" "0" "live log truncated after rotation"
    rm -rf "$_d"
}

test_maint_rotate_keeps_n_archives() {
    _d="/tmp/test-maint-$$"
    mkdir -p "$_d"
    printf 'one\n' > "$_d/a.log.1"
    printf 'two\n' > "$_d/a.log"
    maint_rotate "$_d/a.log" 1 2
    assert_contains "$(cat "$_d/a.log.1")" "two" "newest rotated to .1"
    assert_contains "$(cat "$_d/a.log.2")" "one" "previous .1 pushed to .2"
    rm -rf "$_d"
}

test_maint_trim_state_keeps_recent() {
    _d="/tmp/test-maint-state-$$"
    _old="$_HB"
    _HB="$_d"; _MAINT_LOG_DIR="$_d/var/log"
    mkdir -p "$_d/var/state/msg-map/123" "$_d/var/log"
    i=0
    while [ $i -lt 20 ]; do
        printf '1 2\n' > "$_d/var/state/msg-map/123/$((1000+i))"
        i=$((i+1))
    done
    find "$_d/var/state/msg-map/123" -type f | head -10 | while read -r f; do
        touch -t 202001010000 "$f"
    done
    maint_trim_state 30 5000 0
    assert_eq "$(ls -1 "$_d/var/state/msg-map/123" | wc -l)" "10" "aged map entries pruned"
    _HB="$_old"; test_purge "$_d"
}

test_maint_trim_state_dry_run() {
    _d="/tmp/test-maint-state-$$"
    _old="$_HB"
    _HB="$_d"; _MAINT_LOG_DIR="$_d/var/log"
    mkdir -p "$_d/var/state/msg-map/555" "$_d/var/log"
    i=0
    while [ $i -lt 5 ]; do
        printf '1 2\n' > "$_d/var/state/msg-map/555/$((100+i))"
        touch -t 202001010000 "$_d/var/state/msg-map/555/$((100+i))"
        i=$((i+1))
    done
    maint_trim_state 30 5000 1
    assert_eq "$(ls -1 "$_d/var/state/msg-map/555" | wc -l)" "5" "dry-run deletes nothing"
    _HB="$_old"; test_purge "$_d"
}

test_maint_trim_state_cap_keeps_newest() {
    _d="/tmp/test-maint-state-$$"
    _old="$_HB"
    _HB="$_d"; _MAINT_LOG_DIR="$_d/var/log"
    mkdir -p "$_d/var/state/msg-map/777" "$_d/var/log"
    i=0
    while [ $i -lt 30 ]; do
        printf '1 2\n' > "$_d/var/state/msg-map/777/$((1000+i))"
        touch -t "2026010100$(printf '%02d' $i)" "$_d/var/state/msg-map/777/$((1000+i))" 2>/dev/null
        i=$((i+1))
    done
    MAINT_STATE_MIN_ITEMS=10 maint_trim_state 0 25 0
    assert_eq "$(ls -1 "$_d/var/state/msg-map/777" | wc -l)" "25" "per-conversation cap enforced"
    [ -f "$_d/var/state/msg-map/777/1029" ] && _r=yes || _r=no
    assert_eq "$_r" "yes" "newest entry survives the cap"
    _HB="$_old"; test_purge "$_d"
}

test_maint_trim_state_spares_cursor() {
    _d="/tmp/test-maint-state-$$"
    _old="$_HB"
    _HB="$_d"; _MAINT_LOG_DIR="$_d/var/log"
    mkdir -p "$_d/var/state/dc-cursor" "$_d/var/log"
    printf '1510244300007669840' > "$_d/var/state/dc-cursor/1364457581099089970"
    touch -t 202001010000 "$_d/var/state/dc-cursor/1364457581099089970"
    maint_trim_state 30 5000 0
    [ -f "$_d/var/state/dc-cursor/1364457581099089970" ] && _r=yes || _r=no
    assert_eq "$_r" "yes" "dc-cursor never trimmed"
    _HB="$_old"; test_purge "$_d"
}

test_maint_does_not_clear_state() {
    _src="$(cat "$(dirname "$0")/../plugin/maint/clean.sh")"
    assert_not_contains "$_src" "rm -rf \"\$_HB/var/state" "clean.sh never removes var/state"
    assert_not_contains "$_src" " -delete" "clean.sh uses no delete sweeps"
}

test_maint_trim_state_keeps_recent
test_maint_trim_state_dry_run
test_maint_trim_state_cap_keeps_newest
test_maint_trim_state_spares_cursor
test_maint_rotate_below_threshold
test_maint_rotate_over_threshold
test_maint_rotate_keeps_n_archives
test_maint_does_not_clear_state
