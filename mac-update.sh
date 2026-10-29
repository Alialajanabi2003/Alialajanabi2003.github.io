#!/bin/bash
# Rawi (راوي) — update on macOS with ONE line in Terminal (Ali 2026-10-19: «كود تحديث للماك جيد ميحتاج يحذف و ينزل»):
#
#     curl -fsSL https://rawiplugin.com/mac-update.sh | bash
#
# What it does, in order:
#   1. reads the installed version (After Effects + Premiere panels) and the newest one (rawiplugin.com/version.json);
#      already up to date = it says so and stops (nothing is downloaded)
#   2. waits until After Effects / Premiere Pro are closed (no need to run it again)
#   3. downloads ONLY what changed since the installed version (Rawi-Mac-delta-<installed>.zip, a few MB); when there
#      is no such package (an old version) or it does not check out, the full Rawi-Mac.zip instead
#   4. builds the new version next to the installed one (outside the CEP extensions folder), checks EVERY file against
#      the release checksums, and only then switches folders; any failure puts the old version back
#   5. activation, settings and the user's projects are not touched (they live elsewhere)
# Nothing has to be deleted or downloaded by hand. Bash 3.2 (the macOS default); no sudo (it asks for the Mac password
# once, only when the Adobe extensions folder is owned by the system, like install.sh).
#   --force   reinstall the newest version even when it is already installed
set -u
SITE="${RAWI_SITE:-https://rawiplugin.com}"
DL="${RAWI_DL:-https://github.com/Alialajanabi2003/rawi-downloads/releases/latest/download}"
CEP="${RAWI_CEP:-$HOME/Library/Application Support/Adobe/CEP}"
DEST="$CEP/extensions"
WORK="$CEP/rawi-install"
BUNDLES="com.rawi.panel com.rawi.premiere"
ME="$(id -un)"; GRP="$(id -gn)"
# sudo asks for the password on the terminal (curl | bash: stdin is the script itself)
TTY=/dev/null; ( : </dev/tty ) 2>/dev/null && TTY=/dev/tty
HELP="تحتاج مساعدة؟ صوّر هذي الشاشة ودزها النا بالتليغرام: https://t.me/rawiplugin"
FORCE=0
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1; done

say() { printf '%s\n' "$*"; }
die() { say ""; say "✗ $*"; say "$HELP"; exit 1; }

if [ "$(id -u)" = "0" ]; then
  die "لا تشغّل التحديث بـ sudo. الصق السطر بدون sudo (إذا يحتاج، هو بنفسه يطلب الباسورد مرة وحدة)."
fi
mkdir -p "$HOME/Library/Caches" 2>/dev/null
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rawi-update.XXXXXX" 2>/dev/null || mktemp -d "$HOME/Library/Caches/rawi-update.XXXXXX")" || die "ما كدرنا نسوي مجلد مؤقت."
cleanup() { rm -rf "$TMP"; for B in $BUNDLES; do rm -rf "$WORK/staging-$B" 2>/dev/null; done; }
trap cleanup EXIT

# version of an installed / staged panel folder (CSXS/manifest.xml ExtensionBundleVersion)
ver_of() {
  [ -f "$1/CSXS/manifest.xml" ] || return 0
  sed -n 's/.*ExtensionBundleVersion="\([0-9][0-9.]*\)".*/\1/p' "$1/CSXS/manifest.xml" | head -1
}
# is $1 newer than $2 (dotted numbers)?
newer() {
  local IFS=.; local a=($1) b=($2) i x y
  for i in 0 1 2 3; do
    x=${a[$i]:-0}; y=${b[$i]:-0}
    [ "$x" -gt "$y" ] 2>/dev/null && return 0
    [ "$x" -lt "$y" ] 2>/dev/null && return 1
  done
  return 1
}
running() {   # by process name: After Effects, After Effects (Beta), Adobe Premiere Pro 20xx / (Beta)
  pgrep "^After Effects" >/dev/null 2>&1 && return 0
  pgrep "^Adobe Premiere" >/dev/null 2>&1 && return 0
  return 1
}

main() {
  say "راوي — تحديث الماك"
  say "─────────────────"

  # 1) what is installed, what is the newest
  IV="$(ver_of "$DEST/com.rawi.panel")"
  PV="$(ver_of "$DEST/com.rawi.premiere")"
  J="$(curl -fsSL --max-time 25 "$SITE/version.json" 2>/dev/null)" || die "ما كدرنا نوصل لموقع راوي. تأكد من الإنترنت وجرّب مرة ثانية."
  LATEST="$(printf '%s' "$J" | tr -d '\n' | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p')"
  [ -n "$LATEST" ] || die "ما كدرنا نقرا رقم آخر نسخة من الموقع."
  if [ -n "$IV" ]; then say "النسخة المثبتة: $IV   —   آخر نسخة: $LATEST"; else say "راوي مو مثبت على هذا الماك — راح نثبّت آخر نسخة ($LATEST)."; fi
  if [ "$FORCE" = 0 ] && [ -n "$IV" ] && ! newer "$LATEST" "$IV" && { [ -z "$PV" ] || ! newer "$LATEST" "$PV"; }; then
    say ""
    say "✓ راوي محدّث ($IV). ما يحتاج تسوي شي."
    exit 0
  fi

  # 2) After Effects / Premiere Pro must be closed while the files change
  if running; then
    say ""
    say "سكّر After Effects و Premiere Pro (احفظ شغلك أول) — ننتظرك هنا، لا تسكّر هذي النافذة…"
    n=0
    while running; do
      sleep 2; n=$((n + 1))
      [ $n -gt 600 ] && die "انتظرنا ٢٠ دقيقة وبعده After Effects أو Premiere مفتوح. سكّرهم وأعد نفس السطر."
    done
    say "✓ تسكّروا."
    sleep 2
  fi

  # the Adobe extensions folder must be writable by this user (some Macs have it owned by the system)
  FIXED=0
  fix_owner() {
    [ "$FIXED" = 1 ] && return 0
    say ""
    say "مجلد إضافات Adobe على هذا الماك محمي (مسوّيه برنامج ثاني بصلاحيات المدير)، فلازم نصلّحه مرة وحدة."
    say "اكتب باسورد الماك واضغط Enter — الباسورد ما يبين وإنت تكتبه، هذا طبيعي."
    sudo mkdir -p "$DEST" <"$TTY" || return 1
    sudo chown "$ME:$GRP" "$CEP" "$DEST" <"$TTY" && sudo chmod u+rwX "$CEP" "$DEST" <"$TTY" || return 1
    for B in $BUNDLES; do
      if [ -d "$DEST/$B" ]; then
        [ ! -L "$DEST/$B" ] || return 1
        sudo chown -R "$ME:$GRP" "$DEST/$B" <"$TTY" && sudo chmod -R u+rwX "$DEST/$B" <"$TTY" || return 1
      fi
    done
    if [ -d "$WORK" ]; then sudo chown -R "$ME:$GRP" "$WORK" <"$TTY" || return 1; fi
    FIXED=1; say "✓ تصلّح."
  }
  mkdir -p "$DEST" 2>/dev/null
  needfix=0
  { [ -d "$DEST" ] && [ -w "$DEST" ] && [ -w "$CEP" ]; } || needfix=1
  for B in $BUNDLES; do { [ -e "$DEST/$B" ] && [ ! -w "$DEST/$B" ]; } && needfix=1; done
  { [ -e "$WORK" ] && [ ! -w "$WORK" ]; } && needfix=1
  if [ $needfix = 1 ]; then fix_owner || die "ما كدرنا نصلّح صلاحيات مجلد إضافات Adobe."; fi
  mkdir -p "$WORK" || die "ما كدرنا نسوي مجلد التحديث."
  # leftovers of very old installers inside extensions/ (two folders with one bundle id make Adobe load the wrong one)
  for B in $BUNDLES; do
    for L in "$DEST/$B.staging" "$DEST/$B.previous"; do [ -e "$L" ] && rm -rf "$L"; done
  done

  # a staged folder is good when every file matches the release checksums, no other file is there, and the version is right
  check_stage() {   # $1 folder  $2 expected version
    local S="$1" f
    [ -f "$S/CSXS/manifest.xml" ] && [ -f "$S/release-manifest.json" ] && [ -f "$S/CHECKSUMS.sha256" ] || return 1
    (cd "$S" && /usr/bin/shasum -a 256 -c CHECKSUMS.sha256 >/dev/null 2>&1) || return 1
    # nothing that is not part of the release (a leftover could change what the panel loads)
    (cd "$S" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$TMP/have.txt"
    { sed 's/^[0-9a-f]\{64\}  //' "$S/CHECKSUMS.sha256"; printf '%s\n' CHECKSUMS.sha256 release-manifest.json; } | LC_ALL=C sort > "$TMP/want.txt"
    while IFS= read -r f; do rm -f "$S/$f"; done < <(LC_ALL=C comm -23 "$TMP/have.txt" "$TMP/want.txt")
    find "$S" -type d -empty -delete 2>/dev/null
    [ -z "$2" ] || [ "$(ver_of "$S")" = "$2" ] || return 1
    return 0
  }

  STAGED=""
  # 3a) only what changed: the installed folders + the delta package, built OUTSIDE extensions/
  try_delta() {
    [ -n "$IV" ] || return 1
    { [ -z "$PV" ] || [ "$PV" = "$IV" ]; } || return 1
    local z="$TMP/delta.zip" D="$TMP/delta/Rawi-Delta" B S f
    say ""
    say "ننزّل التغييرات بس (من $IV إلى $LATEST)…"
    curl -fsL --retry 2 --max-time 600 -o "$z" "$DL/Rawi-Mac-delta-$IV.zip" 2>/dev/null || return 1
    unzip -o -q "$z" -d "$TMP/delta" 2>/dev/null || return 1
    [ "$(cat "$D/FROM" 2>/dev/null)" = "$IV" ] && [ "$(cat "$D/TO" 2>/dev/null)" = "$LATEST" ] || return 1
    for B in $BUNDLES; do
      [ -d "$D/$B" ] || continue
      [ -d "$DEST/$B" ] || return 1                       # a panel that is not installed yet comes with the full package
      S="$WORK/staging-$B"; rm -rf "$S"
      cp -R "$DEST/$B" "$S" || return 1
      cp -R "$D/$B/." "$S/" || return 1
      if [ -f "$S/.rawi-removed" ]; then
        while IFS= read -r f; do
          case "$f" in ""|/*|*..*) continue ;; esac
          rm -f "$S/$f"
        done < "$S/.rawi-removed"
        rm -f "$S/.rawi-removed"
      fi
      check_stage "$S" "$LATEST" || return 1
      STAGED="$STAGED $B"
    done
    [ -n "$STAGED" ] || return 1
    return 0
  }
  # 3b) the full package
  full() {
    local B S NV
    STAGED=""
    for B in $BUNDLES; do rm -rf "$WORK/staging-$B"; done
    say ""
    say "ننزّل نسخة راوي الكاملة (حوالي ١٤٠ ميغا) — خليها تكمل…"
    curl -fL --retry 3 --max-time 3600 -# -o "$TMP/Rawi-Mac.zip" "$DL/Rawi-Mac.zip" || die "التحميل ما كمل. تأكد من الإنترنت وأعد نفس السطر."
    unzip -o -q "$TMP/Rawi-Mac.zip" -d "$TMP/full" || die "ملف التحميل ناقص. أعد نفس السطر."
    NV="$(ver_of "$TMP/full/Rawi-Mac/com.rawi.panel")"
    [ -n "$NV" ] || die "ملف التحميل ما بيه راوي."
    if [ -n "$IV" ] && [ "$FORCE" = 0 ] && ! newer "$NV" "$IV"; then
      die "النسخة الجديدة ($LATEST) بعدها دا تنرفع. جرّب بعد ساعة بنفس السطر."
    fi
    for B in $BUNDLES; do
      [ -d "$TMP/full/Rawi-Mac/$B" ] || continue
      S="$WORK/staging-$B"; rm -rf "$S"
      cp -R "$TMP/full/Rawi-Mac/$B" "$S" || die "ما كدرنا ننسخ الملفات."
      check_stage "$S" "$NV" || die "ملفات النسخة الجديدة ما طابقت (التحميل خربان). أعد نفس السطر."
      STAGED="$STAGED $B"
    done
    LATEST="$NV"
  }
  if ! try_delta; then
    for B in $BUNDLES; do rm -rf "$WORK/staging-$B"; done
    [ -n "$IV" ] && say "(ماكو حزمة تغييرات لنسختك — ننزّل الكاملة)"
    full
  fi

  # 4) switch: the installed folder becomes the backup copy, the checked new one takes its place
  DONE=""
  undo_all() {
    local B
    for B in $DONE; do
      if [ -d "$WORK/previous-$B" ]; then rm -rf "$DEST/$B"; mv "$WORK/previous-$B" "$DEST/$B"; else rm -rf "$DEST/$B"; fi
    done
  }
  for B in $STAGED; do
    P="$WORK/previous-$B"
    rm -rf "$P"
    if [ -d "$DEST/$B" ]; then mv "$DEST/$B" "$P" || { undo_all; die "ما كدرنا نبدّل ملفات $B. النسخة القديمة باقية."; }; fi
    DONE="$DONE $B"
    if ! mv "$WORK/staging-$B" "$DEST/$B"; then undo_all; die "ما كدرنا نبدّل ملفات $B. رجّعنا النسخة القديمة."; fi
    xattr -dr com.apple.quarantine "$DEST/$B" 2>/dev/null || true
  done
  for B in $STAGED; do
    [ "$(ver_of "$DEST/$B")" = "$LATEST" ] || { undo_all; die "التحديث ما ثبت. رجّعنا النسخة القديمة."; }
  done
  # unsigned Adobe extensions allowed for this user (same as install.sh)
  for v in 9 10 11 12 13 14; do
    if ! defaults write "com.adobe.CSXS.$v" PlayerDebugMode 1 2>/dev/null; then
      sudo chown "$ME:$GRP" "$HOME/Library/Preferences/com.adobe.CSXS.$v.plist" 2>/dev/null <"$TTY"
      defaults write "com.adobe.CSXS.$v" PlayerDebugMode 1 2>/dev/null || true
    fi
  done

  say ""
  if [ -n "$IV" ] && [ "$IV" = "$LATEST" ]; then say "✓ أعدنا تثبيت راوي $LATEST (كل ملفاته تصلّحت). التفعيل باقي مثل ما هو."
  elif [ -n "$IV" ]; then say "✓ تحدّث راوي من $IV إلى $LATEST. التفعيل باقي مثل ما هو."
  else say "✓ تثبّت راوي $LATEST."; fi
  say "افتح After Effects أو Premiere Pro ← Window ← Extensions ← Rawi"
}

# the whole script is read before anything runs (curl | bash: a cut download does nothing)
main "$@"
