#!/usr/bin/env bash
# claude-statusline-burnrate — a Claude Code status line that does the
# weekly-limit math: real rate_limits data, today's share of the week,
# sustainable burn rate, sleep-aware pacing. Every meter color-coded.
#
# v2: a TUI card. Two aligned rows in a rounded frame, model in the border:
#   ╭─ FABLE 5 · HIGH ─────────────────────────────── 14:32 ─╮
#   │ WK ▰▰▰▱▱▱▱▱ 32% │ CX ▰▱▱▱▱ 10% │ 5H ▰▱▱▱▱ 12% │ 💵 $3.20      │
#   │ 72%t 17%/d ▼11  │ 34m 180k     │ ↻4h54m ▼9    │ ⌚ 12m ⌂ my-app │
#   ╰────────────────────────────────────────────────────────╯
# The one-line v1 lives on as statusline-classic.sh.
#
#   border   = model (its own drifting color family) · effort (cool -> hot)
#             · time of the last render (event-driven: freezes while idle)
#   WK       = REAL weekly plan usage, straight from rate_limits.seven_day
#   today%t  = % of TODAY'S share of the weekly glide still available. The
#             ideal burn is a line from 0% at the weekly reset to 100% at the
#             next, drawn over AWAKE hours only: "days" run day-start to
#             day-start (default 2am), and the first SL_SLEEP_HOURS after
#             day-start count for nothing (18h awake = 1 day by default).
#             Today's share = the line's rise between day-start and the coming
#             one (14.3 on a full day); %t = (line@tonight - wk%) / share.
#             100 = the whole share is ahead of you, 0 = you are exactly ON
#             tonight's checkpoint (done for today), ↓N red = past it,
#             eating tomorrow. Capped at 100 when running behind the line.
#             The weekly % arrives as an INTEGER (1 tick = 7 %t points), so a
#             sub-tick interpolator (see its section) smooths %t between ticks
#             using this session's live cost; re-anchored at every real tick.
#   pace%/d  = sustainable burn in weekly points: (100-wk%) / awake-days-left
#             (clamped >=1 so with <1 day left pace = all that remains). By
#             construction it is tomorrow's envelope if you stop now; constant
#             while you spend exactly at it. Fresh week = 100/7 = 14.3. One
#             decimal below 10, where rounding error starts to matter.
#   trend    = wk% vs the AWAKE-time burn target (% of the week's awake hours
#             elapsed — calendar time would fall ~3.6 pts "behind" every night
#             while asleep). Goal = land at 100% exactly when the week resets.
#             ▲N = ahead (will cap early), ▼N = behind (leaving sub unused),
#             ✓ = within ±3.
#   CX       = how full THIS chat's context window is (resets on /clear or compact)
#   34m      = session wall-clock time
#   Nk       = tokens left before the 200k context line; a yellow ╳ from 200k
#             to 300k, red above — i.e. "time to start a fresh session"
#   5H       = REAL 5-hour plan usage; ↻ = time until it resets, then the same
#             ▲/▼/✓ trend against an even burn of the 5h window (±5 band)
#   💵       = session cost (or PM task counts, see SL_TASKS)
#   ⌚ ⌂     = time since the last commit in this folder, and the folder
#   🔥       = only on a Claude service disruption (status.claude.com)
#
# Color rule: gray means fine. Only a meter that has actually warmed up is
# allowed to pull the eye (gray -> yellow -> orange -> red).
#
# NOTE on animation cadence: this script only runs when Claude Code re-renders
# the status line (event-driven: often while streaming, never while idle).
# Nothing here can self-animate between renders — frames advance per render.
#
# WHY read rate_limits directly: it is the true server-side plan usage, the
# same numbers /usage shows. Per-field gotchas are commented at their code
# sites below.

# ---- tunables ---------------------------------------------------------------
SL_DAY_START="${SL_DAY_START:-2}"      # your "day" flips at this hour (2 = 2am)
SL_SLEEP_HOURS="${SL_SLEEP_HOURS:-6}"  # hours after day-start that count as sleep
SL_STATUS="${SL_STATUS:-1}"            # 0 = never poll status.claude.com
SL_TASKS="${SL_TASKS:-0}"              # 1 = count project-management/TASKS.md boxes
slp=$(( SL_SLEEP_HOURS * 3600 ))       # sleep seconds per day
aday=$(( 86400 - slp ))                # awake seconds per day
CACHE="$HOME/.claude/.cache"; mkdir -p "$CACHE" 2>/dev/null

input=$(cat)

# One jq pass extracts every field, joined by US (0x1f) and read with IFS=$'\x1f'.
# NOT tab: tab is IFS-whitespace, so `read` would collapse empty fields and
# misalign everything after a missing value (empty dir, or no rate_limits on older CC).
IFS=$'\x1f' read -r dir model cpct r5 r5reset r7 r7reset eff ladd lrem sid cost x200k durms ctok cwsz < <(echo "$input" | jq -r '
  [ .workspace.current_dir // .cwd // "",
    .model.display_name // "",
    (.context_window.used_percentage      // "" | tostring),
    (.rate_limits.five_hour.used_percentage // "" | tostring),
    (.rate_limits.five_hour.resets_at       // "" | tostring),
    (.rate_limits.seven_day.used_percentage // "" | tostring),
    (.rate_limits.seven_day.resets_at       // "" | tostring),
    (.effort.level // ""),
    (.cost.total_lines_added   // 0 | tostring),
    (.cost.total_lines_removed // 0 | tostring),
    (.session_id // ""),
    (.cost.total_cost_usd // "" | tostring),
    (.exceeds_200k_tokens // .context_window.exceeds_200k_tokens // false | tostring),
    (.cost.total_duration_ms // 0 | tostring),
    (.context_window.total_input_tokens  // "" | tostring),
    (.context_window.context_window_size // "" | tostring) ] | join("")')

# ---- Antigravity CLI (agy) fallback: quota from a cached `agy -p "/usage"` --
# agy runs this same script as its statusLine but its payload has no
# rate_limits. When they are missing and agy + python3 exist, parse agy's own
# /usage report instead. The call is slow, so it refreshes in the BACKGROUND
# at most every SL_AGY_TTL seconds; this render reads the last cached result.
# Gemini and Claude/GPT models have separate quotas: pick by model name.
agyq=""   # set once agy's cached quota is in use (no Claude status then)
AGY="${SL_AGY_BIN:-$(command -v agy 2>/dev/null || echo "$HOME/.local/bin/agy")}"
if { [ -z "$r5" ] || [ -z "$r7" ]; } && [ -x "$AGY" ] && command -v python3 >/dev/null 2>&1; then
  QCACHE="$CACHE/agy-quota.cache"
  now_ts=$(date +%s)
  last_mod=$(stat -c %Y "$QCACHE" 2>/dev/null || stat -f %m "$QCACHE" 2>/dev/null || echo 0)
  if [ $(( now_ts - last_mod )) -ge "${SL_AGY_TTL:-180}" ]; then
    touch "$QCACHE" 2>/dev/null  # claim this refresh: no stampede of parallel agy calls
    (
      out=$("$AGY" -p "/usage" 2>/dev/null)
      if [ -n "$out" ]; then
        python3 -c '
import sys, re, datetime
text = sys.stdin.read()
for is_gemini, tag in [(True, "gemini"), (False, "other")]:
    prefix = "Gemini Models" if is_gemini else "Claude and GPT models"
    r5 = ""; r5reset = ""; r7 = ""; r7reset = ""
    for line in text.splitlines():
        if not line.startswith(prefix): continue
        m_wk = re.search(r"Weekly Limit Remaining\s+(\d+)%\s+(\S+)", line)
        if m_wk:
            r7 = str(100 - int(m_wk.group(1)))
            r7reset = str(int(datetime.datetime.fromisoformat(m_wk.group(2).replace("Z", "+00:00")).timestamp()))
        m_5h = re.search(r"Five Hour Limit Remaining\s+(\d+)%\s+(\S+)", line)
        if m_5h:
            r5 = str(100 - int(m_5h.group(1)))
            r5reset = str(int(datetime.datetime.fromisoformat(m_5h.group(2).replace("Z", "+00:00")).timestamp()))
    # "-" holds an empty slot: bash `read` would collapse a bare gap and shift
    # the weekly figures into the 5h fields
    print(tag, *[v or "-" for v in (r5, r5reset, r7, r7reset)])
' <<< "$out" > "$QCACHE.tmp" 2>/dev/null && mv -f "$QCACHE.tmp" "$QCACHE" 2>/dev/null
      fi
    ) >/dev/null 2>&1 &
  fi
  if [ -f "$QCACHE" ]; then
    model_type="other"
    case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in
      *gemini*) model_type="gemini" ;;
    esac
    while read -r tag qr5 qr5reset qr7 qr7reset; do
      if [ "$tag" = "$model_type" ]; then
        agyq=1
        [ -z "$r5" ] && [ "$qr5" != "-" ] && r5="$qr5"
        [ -z "$r5reset" ] && [ "$qr5reset" != "-" ] && r5reset="$qr5reset"
        [ -z "$r7" ] && [ "$qr7" != "-" ] && r7="$qr7"
        [ -z "$r7reset" ] && [ "$qr7reset" != "-" ] && r7reset="$qr7reset"
      fi
    done < "$QCACHE"
  fi
fi

# agy has no .effort field: it lives in the name, e.g. "Gemini 3.8 Flash (High)"
if [ -z "$eff" ]; then
  case "$model" in
    *\(Low\)*|*\(low\)*)       eff="low" ;;
    *\(Medium\)*|*\(medium\)*) eff="medium" ;;
    *\(High\)*|*\(high\)*)     eff="high" ;;
    *\(XHigh\)*|*\(xhigh\)*|*\(Max\)*|*\(max\)*) eff="xhigh" ;;
  esac
fi
model="${model%% (*}"          # trim verbose suffixes e.g. "Opus 4.8 (1M context)" -> "Opus 4.8"
model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')   # ALL CAPS display

DIM=$'\e[2m'; CYAN=$'\e[36m'; RST=$'\e[0m'; esc=$'\e'
# semantic scale: gray = good -> yellow -> orange -> red = bad (truecolor,
# same stops as the bar ramp below so bars, numbers and accents all match).
# NEU is the "nothing to see here" gray: a healthy meter should be silent, so
# the eye is only ever pulled by something that has actually warmed up.
NEU=$'\e[38;2;148;155;168m'; YEL=$'\e[38;2;234;179;8m'; ORG=$'\e[38;2;236;141;47m'; RED=$'\e[38;2;239;68;68m'

# Meter labels — dim two-letter text (the TUI card look; the emoji live on in
# statusline-classic.sh).
I_CTX="CX"; I_5H="5H"; I_WK="WK"

# ---- animation frame counter (advances once per status-line render) --------
# Still needed with the spinner gone: drives the rainbow drift and the pet.
FRAMEF="$CACHE/sl-frame"
fn=$(cat "$FRAMEF" 2>/dev/null); case "$fn" in ''|*[!0-9]*) fn=0 ;; esac
fn=$(( fn + 1 )); printf '%s' "$fn" > "$FRAMEF" 2>/dev/null

# ---- per-model hue family + per-effort color --------------------------------
# Each model gets its own rainbow: Opus = warm reds/golds, Sonnet = blues,
# Fable = purples/magentas, Haiku = greens; agy hosts: Gemini Flash = electric
# cyan, GPT = emerald, Gemini Pro = royal indigo; unknown = full rainbow.
# This one is deliberately exempt from the gray-until-it-matters rule: it is
# identity, not a meter, and it sits outside the bar columns where it can't be
# confused for one.
case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in
  *opus*)   MHUES=(196 202 208 214 220 226 214 208) ;;
  *sonnet*) MHUES=(21 27 33 39 45 51 45 39) ;;
  *fable*)  MHUES=(93 99 135 141 177 201 171 135) ;;
  *haiku*)  MHUES=(22 28 34 40 46 82 118 46) ;;
  *flash*)  MHUES=(39 45 51 81 117 123 51 45) ;;
  *gpt*)    MHUES=(34 40 46 82 118 82 46 40) ;;
  *pro*)    MHUES=(27 33 63 99 135 171 135 99) ;;
  *gemini*) MHUES=(27 33 39 69 75 99 135 141) ;;
  *)        MHUES=(196 208 226 46 51 33 201 129) ;;
esac
case "$eff" in  # effort tier, cool -> hot on the same gray->yellow->red scale
  low)       effc="$NEU" ;;
  medium)    effc="$YEL" ;;
  high)      effc="$ORG" ;;
  xhigh|max) effc="$RED" ;;
  *)         effc="$DIM" ;;
esac
eff=$(printf '%s' "$eff" | tr '[:lower:]' '[:upper:]')  # ALL CAPS (after the color match)

# ---- traffic-light battery bars ---------------------------------------------
# Gapped segments (▉ leaves a hairline of background = battery look), colored by
# POSITION along a gamma-corrected truecolor ramp: green -> yellow -> orange ->
# red (green = good, red = bad). Palettes precomputed (see repo tools/ for the generator).
SUN8=("148;155;168" "178;162;144" "203;169;114" "224;176;68" "235;169;26" "236;145;45" "238;115;58" "239;68;68")
SUN5=("148;155;168" "197;168;123" "234;179;8" "237;138;48" "239;68;68")
SUNV=("148;155;168" "163;158;158" "176;162;146" "189;165;133" "200;168;119" "210;171;102" "220;175;80" "230;178;47" "234;174;18" "235;164;31" "236;153;40" "236;141;47" "237;128;53" "238;112;59" "238;93;63" "239;68;68")
gradc() {  # % text color: the ramp sampled at the VALUE's position
  local v=$1; [ "$v" -gt 99 ] && v=99; [ "$v" -lt 0 ] && v=0
  printf '%s' "${SUNV[$(( v * 16 / 100 ))]}"
}
bar() {  # $1 = pct 0-100, $2 = cells (8 or 5)
  local v=$1 n=$2 lit i out=""
  local -a P
  if [ "$n" -eq 8 ]; then P=("${SUN8[@]}"); else P=("${SUN5[@]}"); fi
  [ "$v" -gt 100 ] && v=100; [ "$v" -lt 0 ] && v=0
  lit=$(( (v * n + 50) / 100 ))
  [ "$v" -gt 0 ] && [ "$lit" -eq 0 ] && lit=1
  for (( i=0; i<n; i++ )); do
    if [ "$i" -lt "$lit" ]; then out="${out}${esc}[38;2;${P[$i]}m▰"
    else out="${out}${esc}[38;2;55;60;70m▱"; fi
  done
  printf '%s%s' "$out" "$RST"
}

rainbow() {  # color each char of $1 with the model's hue family, drifting per frame
  local s="$1" o="" i h n=${#MHUES[@]}
  for (( i=0; i<${#s}; i++ )); do
    h=${MHUES[$(( (i + fn) % n ))]}
    o="${o}${esc}[38;5;${h}m${s:$i:1}"
  done
  printf '%s%s' "$o" "$RST"
}

todaycol() { # today's envelope: the displayed value IS the fraction of today's
  # allowance still unspent (100 -> 0), so color thresholds read off it directly.
  if   [ "$1" -ge 50 ]; then printf '%s' "$NEU"   # most of today still ahead
  elif [ "$1" -ge 25 ]; then printf '%s' "$YEL"   # over half spent
  elif [ "$1" -ge 10 ]; then printf '%s' "$ORG"   # nearly tapped
  else                       printf '%s' "$RED"; fi # envelope spent/overdrawn
}
pacecol() { # sustainable %/day vs the ~14%/day even-burn baseline (100%÷7d).
  # Higher pace = more runway left per day = cooler; a low pace means you've
  # overspent and are forced to slow down, so it warms toward red.
  if   [ "$1" -ge 12 ]; then printf '%s' "$NEU"   # at/above even burn: healthy
  elif [ "$1" -ge 8  ]; then printf '%s' "$YEL"   # rationing needed
  elif [ "$1" -ge 5  ]; then printf '%s' "$ORG"   # tight
  else                       printf '%s' "$RED"; fi # forced hard slowdown
}
reset_str() {  # unix ts -> "1h41m" / "12m" time remaining
  [ -z "$1" ] && return
  rem=$(( ($1 - $(date +%s)) / 60 )); [ "$rem" -lt 0 ] && rem=0
  if [ "$rem" -ge 60 ]; then printf '%dh%dm' "$(( rem/60 ))" "$(( rem%60 ))"; else printf '%dm' "$rem"; fi
}

# ---- context % ------------------------------------------------------------
ctx=""
if [ -n "$cpct" ]; then
  p=$(printf '%.0f' "$cpct")
fi

# ---- 5-hour plan usage (real, from rate_limits) ---------------------------
# Row 2 of the 5H column: time until the window resets + burn trend against it.
# The window is a fixed 300 min, so elapsed = 300 - remaining and the even-burn
# line is just elapsed%. trend = used% - elapsed%, the same shape as the weekly
# one: ▲ red = will hit the cap before the window turns over, ▼ green = the
# block will expire part-unused, ✓ = within ±5. Wider dead band than the
# weekly ✓ (±3) because a 5h window is short enough that one big turn moves it
# several points.
b5=""; b5l=0
if [ -n "$r5" ]; then
  p5=$(printf '%.0f' "$r5")
  rs=$(reset_str "$r5reset")
  [ -n "$rs" ] && { b5="${DIM}↻${rs}${RST}"; b5l=$(( 1 + ${#rs} )); }
  case "$r5reset" in
    ''|*[!0-9]*) ;;
    *) rem5=$(( ( r5reset - $(date +%s) ) / 60 ))
       [ "$rem5" -lt 0 ] && rem5=0; [ "$rem5" -gt 300 ] && rem5=300
       d5=$(( p5 - ( 300 - rem5 ) * 100 / 300 ))
       if   [ "$d5" -ge 12 ]; then t5="${RED}▲${d5}${RST}"; t5l=$(( 1 + ${#d5} ))
       elif [ "$d5" -ge 5 ];  then t5="${YEL}▲${d5}${RST}"; t5l=$(( 1 + ${#d5} ))
       elif [ "$d5" -le -5 ]; then t5="${NEU}▼${d5#-}${RST}"; t5l=${#d5}
       else                        t5="${NEU}✓${RST}"; t5l=1; fi
       b5="${b5:+$b5 }$t5"; [ "$b5l" -gt 0 ] && b5l=$(( b5l + 1 )); b5l=$(( b5l + t5l )) ;;
  esac
fi

# ---- sub-tick interpolation for the weekly % -------------------------------
# The payload's weekly used% is an INTEGER, so %t would only move in 7-point
# jumps (1 wk-pt = 7% of a 14.3-pt daily share). Between ticks, estimate the
# fraction of the next point already burned from THIS session's live cost
# (total_cost_usd, penny precision), divided by a dollars-per-weekly-point
# rate that self-calibrates: each tick landing inside one session yields a
# measured $-delta sample, folded in by EMA (seeded $4.50, clamped 1..20).
# Anchored to ground truth at EVERY tick, so drift is bounded by one point.
# Blind spots (parallel sessions, other machines, claude.ai) only make it
# UNDER-estimate — shows a touch more left than reality until the next tick.
# A session switch just re-anchors (frac restarts at 0: graceful degradation
# back to integer steps, never wrong direction).
frac=0
TICKF="$CACHE/sl-tick"
if [ -n "$r7" ] && [ -n "$sid" ] && [ -n "$cost" ]; then
  tu=""; tsid=""; tc=""; tk=""
  read -r tu tsid tc tk 2>/dev/null < "$TICKF"
  tick=$(awk -v u="$r7" -v c="$cost" -v sid="$sid" -v tu="$tu" -v tsid="$tsid" -v tc="$tc" -v tk="$tk" 'BEGIN{
    k = tk+0; if (k < 1 || k > 20) k = 4.5
    if (tu == "" || u+0 != tu+0 || sid != tsid) {
      # tick / first run / weekly reset / session switch: re-anchor here.
      # Calibrate only on a clean +1 tick within one session, sane $ range.
      if (tsid == sid && u+0 == tu+1 && c-tc > 0.5 && c-tc < 40) k = 0.5*k + 0.5*(c-tc)
      printf "ANCHOR %s %s %.4f %.2f", u, sid, c, k
    } else {
      f = (c - tc) / k; if (f < 0) f = 0; if (f > 0.95) f = 0.95
      printf "FRAC %.3f", f
    }
  }' 2>/dev/null)
  case "$tick" in
    ANCHOR\ *) printf '%s' "${tick#ANCHOR }" > "$TICKF" 2>/dev/null ;;
    FRAC\ *)   frac="${tick#FRAC }" ;;
  esac
fi

# ---- weekly (7-day) plan: used% + today's glide gauge + pace + trend -------
# Awake-time model: the day runs day-start->day-start and the first
# SL_SLEEP_HOURS after day-start are sleep, so ALL the budget math counts
# AWAKE seconds only. awake(a,b) walks day by day; sleep = the first `slp`
# seconds of each such day.
# Today gauge %t: the ideal burn is a LINE over the week's awake hours, 0% at
# the last reset -> 100% at the next (a reset that lands inside sleep => the
# line really ends at the surrounding day-start). Tonight's checkpoint = the
# line's value at the coming day-start; today's share = its rise since the
# last one (14.3 on a full day).
#   %t = (checkpoint - used) / share * 100
# 100 = the whole share ahead, 0 = exactly ON tonight's checkpoint, negative
# red = past it (eating tomorrow); capped at 100 when behind the line.
# Everything derives from the live payload: no cache, no day-start snapshot,
# so every machine shows the identical number.
# pace = (100-used) / awake-days-left = sustainable %/day from this moment
# (clamped >=1 day: with <1 day left, spendable = all that remains).
# trend = used% minus the same line at NOW: ahead/behind in weekly points.
# Positive = burning faster than the even awake-glide (caps early);
# negative = slower (would end the week with unused credits).
week=""; today=""; pace=""; trend=""; tl=0
if [ -n "$r7" ]; then
  p7=$(printf '%.0f' "$r7")
  if [ -n "$r7reset" ]; then
    now=$(date +%s)
    # anchor = today's day-start local (only matters mod 24h); BSD date first,
    # GNU date fallback.
    anchor=$(date -v"${SL_DAY_START}"H -v0M -v0S +%s 2>/dev/null || date -d "${SL_DAY_START}:00" +%s 2>/dev/null)
    # start of the current day (anchor is today-calendar day-start, which
    # before day-start lies in the future -> step back one day)
    ds=$anchor; [ "$now" -lt "$anchor" ] 2>/dev/null && ds=$(( anchor - 86400 ))
    tv=$(awk -v used="$r7" -v fr="$frac" -v ds="$ds" -v reset="$r7reset" -v now="$now" -v A="$anchor" -v slp="$slp" -v aday="$aday" '
      function awake(a, b,   s, t, x, de, se, as) {  # awake seconds in [a,b)
        s = 0; t = a
        while (t < b) {
          x = (t - A) % 86400; if (x < 0) x += 86400  # position in the day
          de = t + (86400 - x)                        # next day-start
          se = (b < de) ? b : de                      # end of this segment
          as = t + ((x < slp) ? slp - x : 0)          # asleep? skip to wake
          if (as < se) s += se - as
          t = de
        }
        return s
      }
      BEGIN{
        if (reset <= now || A <= 0) exit 1
        rem = 100 - used; if (rem < 0) rem = 0
        d = awake(now, reset) / aday; if (d < 1) d = 1  # awake-days left
        pr = rem / d
        pv = (pr < 10) ? sprintf("%.1f", pr) : sprintf("%.0f", pr)
        # the even-burn line: % of the weeks awake hours elapsed by time t
        ws = reset - 604800
        aw = awake(ws, reset)
        if (aw <= 0) exit 1
        fv = "NA"
        de = ds + 86400; if (de > reset) de = reset   # day ends: next day-start/reset
        d0 = ds; if (d0 < ws) d0 = ws                 # day start clamped to week
        ckpt  = awake(ws, de) / aw * 100              # the line at tonight
        share = ckpt - awake(ws, d0) / aw * 100       # todays slice of the line
        if (share > 0.1) {
          # used + fr: integer weekly % plus the sub-tick interpolation, so
          # %t moves ~1 point per ~$0.65 instead of 7-point jumps per tick
          f = (ckpt - (used + fr)) / share * 100
          if (f > 100) f = 100                        # behind the line: capped
          fv = sprintf("%.0f", f)
        }
        # trend: same line evaluated at NOW (awake-aware — calendar time would
        # fall ~3.6 pts "behind" every night while asleep)
        e = awake(ws, now) / aw * 100
        if (e < 0) e = 0; if (e > 100) e = 100
        dfv = sprintf("%.0f", used - e)
        print fv, pv, dfv
      }' 2>/dev/null)
    df=""
    if [ -n "$tv" ]; then
      read -r tfrac pv df <<< "$tv"
      if [ "$tfrac" != "NA" ]; then
        tfd="$tfrac"; [ "${tfrac#-}" != "$tfrac" ] && tfd="↓${tfrac#-}"
        today="$(todaycol "$tfrac")${tfd}%t${RST}"
      fi
      # pacecol needs an integer: strip any decimal before comparing
      case "$pv" in *[0-9]*) pace="$(pacecol "${pv%.*}")${pv}%/d${RST}" ;; esac
    fi
    case "$df" in ''|*[!0-9-]*) df="" ;; esac
    if [ -n "$df" ]; then
      if   [ "$df" -ge 8 ];  then trend="${RED}▲${df}${RST}"; tl=$(( 1 + ${#df} ))    # badly overspending
      elif [ "$df" -ge 3 ];  then trend="${YEL}▲${df}${RST}"; tl=$(( 1 + ${#df} ))    # overspending
      elif [ "$df" -le -3 ]; then trend="${NEU}▼${df#-}${RST}"; tl=${#df}             # underspending
      else                        trend="${NEU}✓${RST}"; tl=1                          # on track ±3
      fi
    fi
  fi
fi

# ---- headroom before the 200k context line ---------------------------------
# Past 200k tokens the request runs in extended context: recall gets worse and
# the price per token steps up, so 200k — not the window size — is the number
# worth watching, and this is the cue to start a fresh session.
# Below it: tokens still to spare, counting down, gray (nothing wrong yet).
# 200k-300k: yellow cross — over the line, degrading, still workable.
# 300k+: red cross — refresh now.
# Source: total_input_tokens = input + cache-creation + cache-read = the whole
# prompt, i.e. real context occupancy. Falls back to used% x window size when
# an older CC omits it, so the figure degrades instead of vanishing.
tokfig=""; tokfigl=0
tk="$ctok"; case "$tk" in ''|*[!0-9]*) tk="" ;; esac
if [ -z "$tk" ] && [ -n "$cpct" ]; then
  case "$cwsz" in ''|*[!0-9]*) : ;;
    *) tk=$(awk -v p="$cpct" -v w="$cwsz" 'BEGIN{printf "%d", p*w/100}' 2>/dev/null) ;;
  esac
  case "$tk" in ''|*[!0-9]*) tk="" ;; esac
fi
if [ -n "$tk" ]; then
  if   [ "$tk" -ge 300000 ]; then tokfig="${RED}╳${RST}"; tokfigl=1
  elif [ "$tk" -ge 200000 ]; then tokfig="${YEL}╳${RST}"; tokfigl=1
  else
    left=$(( 200000 - tk ))
    if [ "$left" -ge 1000 ]; then t="$(( left / 1000 ))k"; else t="<1k"; fi
    tokfig="${NEU}${t}${RST}"; tokfigl=${#t}
  fi
fi

# ---- session wall-clock duration -------------------------------------------
dur=""
mins=$(( ${durms:-0} / 60000 ))
if   [ "$mins" -ge 60 ]; then dur="$(( mins / 60 ))h$(( mins % 60 ))m"
elif [ "$mins" -ge 1 ];  then dur="${mins}m"; fi

# ---- service status (status.claude.com, Atlassian Statuspage API) ----------
# No auth. Refreshed in the BACKGROUND so a slow network never stalls a render:
# 2min TTL on success, 30s on failure (failure = empty cache file). Hidden
# while all systems are operational; on disruption a fire with severity bars:
# minor / major / critical. Skipped under agy (not a Claude session) and
# with SL_STATUS=0.
svc=""; svcl=0
if [ "$SL_STATUS" != "0" ] && [ -z "$agyq" ] && command -v curl >/dev/null 2>&1; then
  SVCF="$CACHE/claude-status.json"
  snow=$(date +%s); sage=999999
  if [ -f "$SVCF" ]; then
    smod=$(stat -c %Y "$SVCF" 2>/dev/null || stat -f %m "$SVCF" 2>/dev/null)
    case "$smod" in ''|*[!0-9]*) ;; *) sage=$(( snow - smod )) ;; esac
  fi
  if { [ -s "$SVCF" ] && [ "$sage" -ge 120 ]; } || { [ ! -s "$SVCF" ] && [ "$sage" -ge 30 ]; }; then
    [ -f "$SVCF" ] && touch "$SVCF" 2>/dev/null   # claim it: parallel renders don't stampede
    ( curl -fsSL -m 3 https://status.claude.com/api/v2/status.json -o "$SVCF.tmp" 2>/dev/null \
        && mv -f "$SVCF.tmp" "$SVCF" || : > "$SVCF" ) >/dev/null 2>&1 &
  fi
  case "$(jq -r '.status.indicator // "none"' "$SVCF" 2>/dev/null)" in
    minor)    svc="${YEL}🔥▂${RST}";  svcl=3 ;;
    major)    svc="${ORG}🔥▄▂${RST}";  svcl=4 ;;
    critical) svc="${RED}🔥▆▄▂${RST}"; svcl=5 ;;
  esac
fi

# ---- PM task counts (opt-in: SL_TASKS=1) ------------------------------------
# For repos that keep a project-management/TASKS.md board (monorepos keep one
# per app): open checkboxes / [status:in-progress] / [status:blocked] tags,
# summed. Replaces the cost cell when any are found. Off by default because it
# walks the tree on every render.
ttodo=0; tprog=0; tblock=0
if [ "$SL_TASKS" = "1" ] && [ -n "$dir" ] && [ -d "$dir" ]; then
  while IFS= read -r tf; do
    [ -f "$tf" ] || continue
    o=$(grep -c '^[[:space:]]*- \[ \]' "$tf" 2>/dev/null) || o=0
    pg=$(grep -c 'status:in-progress' "$tf" 2>/dev/null) || pg=0
    bl=$(grep -c 'status:blocked' "$tf" 2>/dev/null) || bl=0
    ttodo=$(( ttodo + o )); tprog=$(( tprog + pg )); tblock=$(( tblock + bl ))
  done < <(find "$dir" -maxdepth 4 -path '*/project-management/TASKS.md' -not -path '*node_modules*' 2>/dev/null)
fi

# ---- last-commit age + current dir ------------------------------------------
# Rendered as one cell, age FIRST: the number that should make you act comes
# before the label that never changes.
# Folder name truncated past 7 chars (+ ellipsis) so a long repo name can never
# widen the card. Branch dropped: it cost a variable-width column and never
# changed a decision the meters didn't already make.
# Widths are counted arithmetically, not with ${#…}, because the ellipsis is
# one column but not one byte outside a UTF-8 locale.
loc=""; locl=0; age=""; agel=0
if [ -n "$dir" ] && [ -d "$dir" ]; then
  base="${dir##*/}"; blen=${#base}
  if [ "$blen" -gt 7 ]; then base="${base:0:7}…"; blen=8; fi
  loc="⌂ ${base}"; locl=$(( 2 + blen ))
  # A quiet commit nudge: green <30m, yellow <2h, orange <6h, red beyond.
  ct=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)
  if [ -n "$ct" ]; then
    am=$(( ( $(date +%s) - ct ) / 60 )); [ "$am" -lt 0 ] && am=0
    if   [ "$am" -ge 1440 ]; then ad="$(( am / 1440 ))d$(( am % 1440 / 60 ))h"
    elif [ "$am" -ge 60 ];   then ad="$(( am / 60 ))h$(( am % 60 ))m"
    else                          ad="${am}m"; fi
    if   [ "$am" -ge 360 ]; then agc="$RED"
    elif [ "$am" -ge 120 ]; then agc="$ORG"
    elif [ "$am" -ge 30 ];  then agc="$YEL"
    else                         agc="$NEU"; fi
    age="⌚ ${agc}${ad}${RST}"; agel=$(( 3 + ${#ad} ))
  fi
fi

# ---- assemble: TUI card — the two aligned rows boxed, model in the border --
#   ╭─ FABLE 5 · HIGH ─────────────────────────────── 14:32 ─╮
#   │ WK ▰▰▰▰▰▱▱▱ 65% │ CX ▰▰▱▱▱ 42% │ 5H ▰▰▰▰▱ 88% │ 📋 3☐ 1▶      │
#   │ 38%t 9.8%/d ▲4  │ 34m 80k      │ ↻1h41m ▲7    │ ⌚ 12m ⌂ my-rep… │
#   ╰────────────────────────────────────────────────────────╯
# Same cells as statusline-classic.sh, stacked into aligned columns; the
# model+effort cell moved into the top border. Widths are hand-tracked (ANSI
# is invisible, an emoji = 2 terminal columns).
BX=$'\e[38;2;90;98;112m'   # fallback slate, still used for the model·effort dot
SEP=" ${DIM}│${RST} "
# ---- frame gradient ---------------------------------------------------------
# The box contour is painted in the SAME per-model hue family as the model name,
# stretched so one full pass of the palette spans the whole frame width (not
# tiled — tiling at 70 columns reads as stripes, not a gradient) and drifting by
# the frame counter, so the frame breathes in step with the name while Claude
# works. BXW is the frame's total width and must be set before the first call.
#
# Runs are emitted char-by-char from a COUNT, never by indexing into a string:
# ╭ ─ ╯ are multi-byte, and ${s:i:1} would slice them into garbage under a
# non-UTF-8 locale. This way the border is correct whatever LANG happens to be.
BXW=1
bxrun() {  # $1 = char, $2 = how many, $3 = starting column in the frame
  local c="$1" k="$2" p="${3:-0}" o="" i h n=${#MHUES[@]}
  for (( i=0; i<k; i++ )); do
    h=${MHUES[$(( ( (i + p) * n / BXW + fn ) % n ))]}
    o="${o}${esc}[38;5;${h}m${c}"
  done
  printf '%s' "$o"
}
# tasks / cost cell — row1 of the last column
tcell=""; tlen=0
if [ "$(( ttodo + tprog + tblock ))" -gt 0 ]; then
  tcell="📋 ${ttodo}☐"; tlen=$(( 4 + ${#ttodo} ))
  [ "$tprog" -gt 0 ]  && { tcell="$tcell ${NEU}${tprog}▶${RST}"; tlen=$(( tlen + 2 + ${#tprog} )); }
  [ "$tblock" -gt 0 ] && { tcell="$tcell ${RED}${tblock}⛔${RST}"; tlen=$(( tlen + 3 + ${#tblock} )); }
else
  costd=""; [ -n "$cost" ] && costd=$(printf '$%.2f' "$cost" 2>/dev/null)
  [ -n "$costd" ] && { tcell="💵 ${costd}"; tlen=$(( 3 + ${#costd} )); }
fi
ca=(); cb=(); la=(); lb=()
if [ -n "$r7" ]; then
  ca+=("${DIM}${I_WK}${RST} $(bar "$p7" 8) ${esc}[38;2;$(gradc "$p7")m${p7}%${RST}")
  la+=("$(( 13 + ${#p7} ))")
  s=""; l=0
  if [ -n "$today" ]; then s="$today"; l=$(( ${#tfrac} + 2 )); fi
  if [ -n "$pace" ];  then s="${s:+$s }$pace"; [ "$l" -gt 0 ] && l=$(( l + 1 )); l=$(( l + ${#pv} + 3 )); fi
  if [ -n "$trend" ]; then s="${s:+$s }$trend"; [ "$l" -gt 0 ] && l=$(( l + 1 )); l=$(( l + tl )); fi
  cb+=("$s"); lb+=("$l")
fi
if [ -n "$cpct" ]; then
  s="${DIM}${I_CTX}${RST} $(bar "$p" 5) ${esc}[38;2;$(gradc "$p")m${p}%${RST}"; l=$(( 10 + ${#p} ))
  ca+=("$s"); la+=("$l")
  s=""; l=0
  if [ -n "$dur" ]; then s="${DIM}${dur}${RST}"; l=${#dur}; fi
  if [ -n "$tokfig" ]; then s="${s:+$s }$tokfig"; [ "$l" -gt 0 ] && l=$(( l + 1 )); l=$(( l + tokfigl )); fi
  cb+=("$s"); lb+=("$l")
fi
if [ -n "$r5" ]; then
  ca+=("${DIM}${I_5H}${RST} $(bar "$p5" 5) ${esc}[38;2;$(gradc "$p5")m${p5}%${RST}")
  la+=("$(( 10 + ${#p5} ))")
  cb+=("$b5"); lb+=("$b5l")
fi
# last column: tasks over commit-age + folder — last so a long directory name
# can never push the inner columns apart. The service-status flame is rare
# (hidden while all systems are operational) so it rides ahead of the tasks
# rather than owning a slot that would otherwise sit empty.
r1=""; r1l=0; r2=""; r2l=0
if [ -n "$svc" ]; then r1="$svc"; r1l=$svcl; fi
if [ -n "$tcell" ]; then
  r1="${r1:+$r1 }$tcell"; [ "$r1l" -gt 0 ] && r1l=$(( r1l + 1 )); r1l=$(( r1l + tlen ))
fi
if [ -n "$age" ]; then r2="$age"; r2l=$agel; fi
if [ -n "$loc" ]; then
  r2="${r2:+$r2 }$loc"; [ "$r2l" -gt 0 ] && r2l=$(( r2l + 1 )); r2l=$(( r2l + locl ))
fi
if [ -n "$r1" ] || [ -n "$r2" ]; then
  ca+=("$r1"); la+=("$r1l"); cb+=("$r2"); lb+=("$r2l")
fi
row1=""; row2=""; tw=0; n=${#ca[@]}
for (( i=0; i<n; i++ )); do
  wa=${la[$i]}; wb=${lb[$i]}
  w=$(( wa > wb ? wa : wb ))
  c1="${ca[$i]}$(printf '%*s' "$(( w - wa ))" '')"
  c2="${cb[$i]}$(printf '%*s' "$(( w - wb ))" '')"
  row1="${row1:+${row1}${SEP}}${c1}"
  row2="${row2:+${row2}${SEP}}${c2}"
  tw=$(( tw + w )); [ "$i" -gt 0 ] && tw=$(( tw + 3 ))
done
# top border carries model · effort; borders sized to the rows' visible width
tt=""; ttl=0
if [ -n "$model" ]; then tt="$(rainbow "$model")"; ttl=${#model}; fi
if [ -n "$eff" ]; then tt="${tt:+$tt ${BX}·${RST} }${effc}${eff}${RST}"; ttl=$(( ttl + 3 + ${#eff} )); fi
inner=$(( tw + 2 ))                     # one space of padding inside each border
# a long model name (or a near-empty card) must widen the frame, not overflow
# it: the title row needs inner >= title + 12 (corners, gaps, a dash, clock)
if [ -n "$tt" ] && [ "$inner" -lt $(( ttl + 12 )) ]; then
  pad=$(printf '%*s' "$(( ttl + 12 - inner ))" '')
  row1="${row1}${pad}"; row2="${row2}${pad}"; inner=$(( ttl + 12 ))
fi
# clock in the right corner — time of the LAST render (event-driven, so it
# freezes while idle; reads as "last activity", not a live wall clock)
clk=$(date +%H:%M)
nd=$(( inner - ttl - 11 )); [ "$nd" -lt 1 ] && nd=1   # ╭─ tt ␣dash␣ HH:MM ─╮
dash=""; for (( i=0; i<nd; i++ )); do dash="${dash}─"; done
bdash=""; for (( i=0; i<inner; i++ )); do bdash="${bdash}─"; done
BXW=$(( inner + 2 ))                    # full frame width: the gradient's span
if [ -n "$tt" ]; then
  # ╭─␣ | model·effort | ␣dash␣ | HH:MM | ␣─╮   — column tracked across the gaps
  # so the hue keeps climbing through the pieces the title interrupts.
  c=$(( 3 + ttl ))
  top="$(bxrun '╭' 1 0)$(bxrun '─' 1 1)$(bxrun ' ' 1 2)${RST}${tt}"
  top="${top}$(bxrun ' ' 1 "$c")$(bxrun '─' "$nd" $(( c + 1 )))$(bxrun ' ' 1 $(( c + 1 + nd )))${RST}${DIM}${clk}${RST}"
  c=$(( c + 2 + nd + ${#clk} ))
  top="${top}$(bxrun ' ' 1 "$c")$(bxrun '─' 1 $(( c + 1 )))$(bxrun '╮' 1 $(( c + 2 )))${RST}"
else
  top="$(bxrun '╭' 1 0)$(bxrun '─' "$inner" 1)$(bxrun '╮' 1 $(( inner + 1 )))${RST}"
fi
lp="$(bxrun '│' 1 0)${RST}"; rp="$(bxrun '│' 1 $(( inner + 1 )))${RST}"
printf '%s\n%s\n%s\n%s' \
  "$top" \
  "${lp} ${row1} ${rp}" \
  "${lp} ${row2} ${rp}" \
  "$(bxrun '╰' 1 0)$(bxrun '─' "$inner" 1)$(bxrun '╯' 1 $(( inner + 1 )))${RST}"
