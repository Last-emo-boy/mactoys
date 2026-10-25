#!/bin/zsh
# Renders every deliverable into out/:
#   MacToys_BRoll_<lang>.mp4 for each film language, MacToys_Loop.mp4, poster.png, audio/{score,mix}.wav
#   pnpm render            # everything
#   pnpm render en         # one film (plus nothing else)
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p out

pnpm -s check
pnpm -s audio # the score follows the timeline, which follows the exported languages

langs=("$@")
(( ${#langs} )) || langs=(en zh-Hans)
for lang in $langs; do
  npx remotion render src/index.ts MacToysFilm "out/MacToys_BRoll_${lang}.mp4" --props="{\"lang\":\"${lang}\"}" --log=error
done

if (( ! $# )); then
  npx remotion render src/index.ts MacToysLoop out/MacToys_Loop.mp4 --muted --props='{"lang":"en"}' --log=error
  npx remotion still src/index.ts MacToysPoster out/poster.png --props='{"lang":"en"}' --log=error
fi
ls -lh out/*.mp4 out/*.png out/audio/*.wav 2>/dev/null
