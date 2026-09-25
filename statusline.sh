#!/usr/bin/env bash
SL_DAY_START="${SL_DAY_START:-2}"
SL_SLEEP_HOURS="${SL_SLEEP_HOURS:-6}"
SL_STATUS="${SL_STATUS:-1}"
slp=$(( SL_SLEEP_HOURS * 3600 ))
aday=$(( 86400 - slp ))
CACHE="$HOME/.claude/.cache"; mkdir -p "$CACHE" 2>/dev/null

input=$(cat)

IFS=$'\x1f' read -r dir model cpct r5 r5reset r7 r7reset eff ladd lrem sid cost x200k durms ctok cwsz tier is_agy < <(echo "$input" | jq -r '
  def is_gemini: (.model.display_name // .model.id // "" | test("gemini"; "i"));
  def is_agy_host: (.product == "antigravity" or .quota != null or (.model.display_name // "" | test("gemini"; "i")));
  def q_5h: if is_gemini then .quota["gemini-5h"] else .quota["3p-5h"] end;
  def q_wk: if is_gemini then .quota["gemini-weekly"] else .quota["3p-weekly"] end;
  [ .workspace.current_dir // .cwd // "",
    .model.display_name // .model.id // "",
    (.context_window.used_percentage        // (if .context_window.total_input_tokens != null and .context_window.context_window_size != null and .context_window.context_window_size > 0 then ((.context_window.total_input_tokens / .context_window.context_window_size) * 100) elif .context_window.used_tokens != null and .context_window.context_window_size != null and .context_window.context_window_size > 0 then ((.context_window.used_tokens / .context_window.context_window_size) * 100) elif .context_window.current_usage != null and .context_window.context_window_size != null and .context_window.context_window_size > 0 then ((.context_window.current_usage / .context_window.context_window_size) * 100) else "" end) // "" | tostring),
    (.rate_limits.five_hour.used_percentage // (if q_5h.remaining_fraction != null then ((1 - q_5h.remaining_fraction) * 100) else "" end) // "" | tostring),
    (.rate_limits.five_hour.resets_at       // (if q_5h.reset_in_seconds != null then (now + q_5h.reset_in_seconds | floor) else "" end) // "" | tostring),
    (.rate_limits.seven_day.used_percentage // (if q_wk.remaining_fraction != null then ((1 - q_wk.remaining_fraction) * 100) else "" end) // "" | tostring),
    (.rate_limits.seven_day.resets_at       // (if q_wk.reset_in_seconds != null then (now + q_wk.reset_in_seconds | floor) else "" end) // "" | tostring),
    (.effort.level // .model.effort // ""),
    (.cost.total_lines_added   // 0 | tostring),
    (.cost.total_lines_removed // 0 | tostring),
    (.session_id // ""),
    (.cost.total_cost_usd // "" | tostring),
    (.exceeds_200k_tokens // .context_window.exceeds_200k_tokens // false | tostring),
    (.cost.total_duration_ms // 0 | tostring),
    (.context_window.total_input_tokens  // "" | tostring),
    (.context_window.context_window_size // "" | tostring),
    (.plan_tier // ""),
    (if is_agy_host then "1" else "0" end) ] | join("\u001f")')

agyq=""
[ "$is_agy" = "1" ] && agyq=1

AGY="${SL_AGY_BIN:-$(command -v agy 2>/dev/null || echo "$HOME/.local/bin/agy")}"
if { [ -z "$r5" ] || [ -z "$r7" ]; } && [ -x "$AGY" ] && command -v python3 >/dev/null 2>&1; then
  QCACHE="$CACHE/agy-quota.cache"
  now_ts=$(date +%s)
  last_mod=$(stat -c %Y "$QCACHE" 2>/dev/null || stat -f %m "$QCACHE" 2>/dev/null || echo 0)
  if [ $(( now_ts - last_mod )) -ge "${SL_AGY_TTL:-180}" ]; then
    touch "$QCACHE" 2>/dev/null
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

if [ -z "$eff" ]; then
  case "$model" in
    *\(Low\)*|*\(low\)*)       eff="low" ;;
    *\(Medium\)*|*\(medium\)*) eff="medium" ;;
    *\(High\)*|*\(high\)*)     eff="high" ;;
    *\(XHigh\)*|*\(xhigh\)*|*\(Max\)*|*\(max\)*) eff="xhigh" ;;
  esac
fi
model="${model%% (*}"
model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')

DIM=$'\e[2m'; CYAN=$'\e[36m'; RST=$'\e[0m'; esc=$'\e'
NEU=$'\e[38;2;148;155;168m'; YEL=$'\e[38;2;234;179;8m'; ORG=$'\e[38;2;236;141;47m'; RED=$'\e[38;2;239;68;68m'

I_CTX="CX"; I_5H="5H"; I_WK="WK"

FRAMEF="$CACHE/sl-frame"
fn=$(cat "$FRAMEF" 2>/dev/null); case "$fn" in ''|*[!0-9]*) fn=0 ;; esac
fn=$(( fn + 1 )); printf '%s' "$fn" > "$FRAMEF" 2>/dev/null

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
case "$eff" in
  low)       effc="$NEU" ;;
  medium)    effc="$YEL" ;;
  high)      effc="$ORG" ;;
  xhigh|max) effc="$RED" ;;
  *)         effc="$DIM" ;;
esac
eff=$(printf '%s' "$eff" | tr '[:lower:]' '[:upper:]')

SUN8=("148;155;168" "178;162;144" "203;169;114" "224;176;68" "235;169;26" "236;145;45" "238;115;58" "239;68;68")
SUN5=("148;155;168" "197;168;123" "234;179;8" "237;138;48" "239;68;68")
SUNV=("148;155;168" "163;158;158" "176;162;146" "189;165;133" "200;168;119" "210;171;102" "220;175;80" "230;178;47" "234;174;18" "235;164;31" "236;153;40" "236;141;47" "237;128;53" "238;112;59" "238;93;63" "239;68;68")
gradc() {
  local v=$1; [ "$v" -gt 99 ] && v=99; [ "$v" -lt 0 ] && v=0
  printf '%s' "${SUNV[$(( v * 16 / 100 ))]}"
}
bar() {
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

rainbow() {
  local s="$1" o="" i h n=${#MHUES[@]}
  for (( i=0; i<${#s}; i++ )); do
    h=${MHUES[$(( (i + fn) % n ))]}
    o="${o}${esc}[38;5;${h}m${s:$i:1}"
  done
  printf '%s%s' "$o" "$RST"
}

todaycol() {
  if   [ "$1" -ge 50 ]; then printf '%s' "$NEU"
  elif [ "$1" -ge 25 ]; then printf '%s' "$YEL"
  elif [ "$1" -ge 10 ]; then printf '%s' "$ORG"
  else                       printf '%s' "$RED"; fi
}
pacecol() {
  if   [ "$1" -ge 14 ]; then printf '%s' "$NEU"
  elif [ "$1" -ge 11 ]; then printf '%s' "$CYAN"
  elif [ "$1" -ge 8  ]; then printf '%s' "$YEL"
  elif [ "$1" -ge 5  ]; then printf '%s' "$ORG"
  else                       printf '%s' "$RED"; fi
}
reset_str() {
  [ -z "$1" ] && return
  rem=$(( ($1 - $(date +%s)) / 60 )); [ "$rem" -lt 0 ] && rem=0
  if [ "$rem" -ge 60 ]; then printf '%dh%dm' "$(( rem/60 ))" "$(( rem%60 ))"; else printf '%dm' "$rem"; fi
}

ctx=""
if [ -n "$cpct" ]; then
  p=$(printf '%.0f' "$cpct")
fi

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

frac=0
TICKF="$CACHE/sl-tick"
if [ -n "$r7" ] && [ -n "$sid" ] && [ -n "$cost" ]; then
  tu=""; tsid=""; tc=""; tk=""
  read -r tu tsid tc tk 2>/dev/null < "$TICKF" || true
  tick=$(awk -v u="$r7" -v c="$cost" -v sid="$sid" -v tu="$tu" -v tsid="$tsid" -v tc="$tc" -v tk="$tk" 'BEGIN{
    k = tk+0; if (k < 1 || k > 20) k = 4.5
    if (tu == "" || u+0 != tu+0 || sid != tsid) {
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

week=""; today=""; pace=""; trend=""; tl=0
if [ -n "$r7" ]; then
  p7=$(printf '%.0f' "$r7")
  if [ -n "$r7reset" ]; then
    now=$(date +%s)
    anchor=$(date -v"${SL_DAY_START}"H -v0M -v0S +%s 2>/dev/null || date -d "${SL_DAY_START}:00" +%s 2>/dev/null)
    ds=$anchor; [ "$now" -lt "$anchor" ] 2>/dev/null && ds=$(( anchor - 86400 ))
    tv=$(awk -v used="$r7" -v fr="$frac" -v ds="$ds" -v reset="$r7reset" -v now="$now" -v A="$anchor" -v slp="$slp" -v aday="$aday" '
      function awake(a, b,   s, t, x, de, se, as) {
        s = 0; t = a
        while (t < b) {
          x = (t - A) % 86400; if (x < 0) x += 86400
          de = t + (86400 - x)
          se = (b < de) ? b : de
          as = t + ((x < slp) ? slp - x : 0)
          if (as < se) s += se - as
          t = de
        }
        return s
      }
      BEGIN{
        if (reset <= now || A <= 0) exit 1
        rem = 100 - used; if (rem < 0) rem = 0
        d = awake(now, reset) / aday; if (d < 1) d = 1
        pr = rem / d
        pv = (pr < 10) ? sprintf("%.1f", pr) : sprintf("%.0f", pr)
        ws = reset - 604800
        aw = awake(ws, reset)
        if (aw <= 0) exit 1
        fv = "NA"
        de = ds + 86400; if (de > reset) de = reset
        d0 = ds; if (d0 < ws) d0 = ws
        ckpt  = awake(ws, de) / aw * 100
        share = ckpt - awake(ws, d0) / aw * 100
        if (share > 0.1) {
          f = (ckpt - (used + fr)) / share * 100
          if (f > 100) f = 100
          fv = sprintf("%.0f", f)
        }
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
      case "$pv" in *[0-9]*) pace="$(pacecol "${pv%.*}")${pv}%/d${RST}" ;; esac
    fi
    case "$df" in ''|*[!0-9-]*) df="" ;; esac
    if [ -n "$df" ]; then
      if   [ "$df" -ge 8 ];  then trend="${RED}▲${df}${RST}"; tl=$(( 1 + ${#df} ))
      elif [ "$df" -ge 3 ];  then trend="${YEL}▲${df}${RST}"; tl=$(( 1 + ${#df} ))
      elif [ "$df" -le -3 ]; then trend="${NEU}▼${df#-}${RST}"; tl=${#df}
      else                        trend="${NEU}✓${RST}"; tl=1
      fi
    fi
  fi
fi

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

dur=""
mins=$(( ${durms:-0} / 60000 ))
if [ "$mins" -le 0 ] && [ -n "$sid" ]; then
  SESSF="$CACHE/sess_${sid}"
  if [ ! -f "$SESSF" ]; then date +%s > "$SESSF" 2>/dev/null; fi
  st=$(cat "$SESSF" 2>/dev/null)
  case "$st" in
    ''|*[!0-9]*) ;;
    *) now_s=$(date +%s)
       [ "$now_s" -ge "$st" ] && mins=$(( (now_s - st) / 60 )) ;;
  esac
fi
if   [ "$mins" -ge 60 ]; then dur="$(( mins / 60 ))h$(( mins % 60 ))m"
elif [ "$mins" -ge 1 ];  then dur="${mins}m"; fi

# ---- Assemble 3 condensed blocks on ONE line -------------------------------
BX=$'\e[38;2;90;98;112m'
SEP=" ${DIM}│${RST} "

blk1=""; len1=0
if [ -n "$r7" ]; then
  blk1="${DIM}${I_WK}${RST} $(bar "$p7" 8) ${esc}[38;2;$(gradc "$p7")m${p7}%${RST}"
  len1=$(( 13 + ${#p7} ))
  if [ -n "$today" ]; then
    blk1="${blk1} $today"
    len1=$(( len1 + 1 + ${#tfrac} + 2 ))
  fi
  if [ -n "$pace" ]; then
    blk1="${blk1} $pace"
    len1=$(( len1 + 1 + ${#pv} + 3 ))
  fi
  if [ -n "$trend" ]; then
    blk1="${blk1} $trend"
    len1=$(( len1 + 1 + tl ))
  fi
fi

blk2=""; len2=0
if [ -n "$cpct" ]; then
  blk2="${DIM}${I_CTX}${RST} $(bar "$p" 5) ${esc}[38;2;$(gradc "$p")m${p}%${RST}"
  len2=$(( 10 + ${#p} ))
  if [ -n "$dur" ]; then
    blk2="${blk2} ${DIM}${dur}${RST}"
    len2=$(( len2 + 1 + ${#dur} ))
  fi
  if [ -n "$tokfig" ]; then
    blk2="${blk2} $tokfig"
    len2=$(( len2 + 1 + tokfigl ))
  fi
fi

blk3=""; len3=0
if [ -n "$r5" ]; then
  blk3="${DIM}${I_5H}${RST} $(bar "$p5" 5) ${esc}[38;2;$(gradc "$p5")m${p5}%${RST}"
  len3=$(( 10 + ${#p5} ))
  if [ -n "$b5" ]; then
    blk3="${blk3} $b5"
    len3=$(( len3 + 1 + b5l ))
  fi
fi

blocks=()
lens=()
[ -n "$blk1" ] && { blocks+=("$blk1"); lens+=("$len1"); }
[ -n "$blk2" ] && { blocks+=("$blk2"); lens+=("$len2"); }
[ -n "$blk3" ] && { blocks+=("$blk3"); lens+=("$len3"); }

row=""
tw=0
n=${#blocks[@]}
for (( i=0; i<n; i++ )); do
  row="${row:+${row}${SEP}}${blocks[$i]}"
  tw=$(( tw + lens[$i] ))
  [ "$i" -gt 0 ] && tw=$(( tw + 3 ))
done

tt=""; ttl=0
if [ -n "$model" ]; then tt="$(rainbow "$model")"; ttl=${#model}; fi
if [ -n "$eff" ]; then tt="${tt:+$tt ${BX}·${RST} }${effc}${eff}${RST}"; ttl=$(( ttl + 3 + ${#eff} )); fi
inner=$(( tw + 2 ))

if [ -n "$tt" ] && [ "$inner" -lt $(( ttl + 12 )) ]; then
  pad=$(printf '%*s' "$(( ttl + 12 - inner ))" '')
  row="${row}${pad}"; inner=$(( ttl + 12 ))
fi

clk=$(date +%H:%M)
nd=$(( inner - ttl - 11 )); [ "$nd" -lt 1 ] && nd=1
dash=""; for (( i=0; i<nd; i++ )); do dash="${dash}─"; done
BXW=$(( inner + 2 ))

bxrun() {
  local c="$1" k="$2" p="${3:-0}" o="" i h n=${#MHUES[@]}
  for (( i=0; i<k; i++ )); do
    h=${MHUES[$(( ( (i + p) * n / BXW + fn ) % n ))]}
    o="${o}${esc}[38;5;${h}m${c}"
  done
  printf '%s' "$o"
}

if [ -n "$tt" ]; then
  c=$(( 3 + ttl ))
  top="$(bxrun '╭' 1 0)$(bxrun '─' 1 1)$(bxrun ' ' 1 2)${RST}${tt}"
  top="${top}$(bxrun ' ' 1 "$c")$(bxrun '─' "$nd" $(( c + 1 )))$(bxrun ' ' 1 $(( c + 1 + nd )))${RST}${DIM}${clk}${RST}"
  c=$(( c + 2 + nd + ${#clk} ))
  top="${top}$(bxrun ' ' 1 "$c")$(bxrun '─' 1 $(( c + 1 )))$(bxrun '╮' 1 $(( c + 2 )))${RST}"
else
  top="$(bxrun '╭' 1 0)$(bxrun '─' "$inner" 1)$(bxrun '╮' 1 $(( inner + 1 )))${RST}"
fi
lp="$(bxrun '│' 1 0)${RST}"; rp="$(bxrun '│' 1 $(( inner + 1 )))${RST}"
printf '%s\n%s\n%s\n' \
  "$top" \
  "${lp} ${row} ${rp}" \
  "$(bxrun '╰' 1 0)$(bxrun '─' "$inner" 1)$(bxrun '╯' 1 $(( inner + 1 )))${RST}"
