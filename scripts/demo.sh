#!/bin/zsh
# Records a demo of an isolated Canopy against the local seed database.
# Output: build/demo/canopy-demo.mp4 and .gif. Needs ffmpeg + mongosh.
set -u
cd "${0:A:h}/.."
OUT=build/demo; rm -rf $OUT; mkdir -p $OUT
URI="mongodb://localhost:27099/?directConnection=true"
scripts/run-dev.sh
c=scripts/ctl
$c appearance dark >/dev/null; $c size 1440 900 >/dev/null; sleep 0.8
$c record start $PWD/$OUT/frames 12
$c sleep 1200
$c connect Local dev; $c sleep 1300
$c open shop orders; $c sleep 1800
$c view table; $c select 1; $c sleep 1800
$c view list; $c sleep 400
$c ask "refunded orders over 15000 shipped to Rosario in the last 60 days, newest first"; $c sleep 2500
$c mode explain; $c sleep 1500
$c explain-ai; $c sleep 3500
$c askpipe "monthly revenue for delivered orders, split by payment method"; $c sleep 3000
$c copilot "Which payment methods have the highest refund rate? Give me a pipeline I can apply."; $c sleep 3500
$c apply-proposal; $c sleep 3000
$c copilot-open off; $c open shop customers schema; $c sleep 2500
$c expand address.location; $c sleep 3000
$c validator-ai; $c sleep 3500
$c open shop orders; $c mode documents; $c sleep 600
$c bulk-ai "cancel processing orders that haven't been updated in 45 days"; $c sleep 3500
$c close-sheet; $c open analytics events; $c sort "{ts: -1}"; $c live; $c sleep 600
mongosh --quiet $URI --eval 'var N=12' scripts/traffic.js >/dev/null &
$c sleep 7000
$c palette on; $c sleep 1500; $c palette off; $c sleep 500
$c record stop
cd $OUT/frames
ffmpeg -loglevel error -y -f concat -safe 0 -i frames.txt -vf "fps=30,format=yuv420p" -c:v libx264 -crf 20 -movflags +faststart ../canopy-demo.mp4
ffmpeg -loglevel error -y -i ../canopy-demo.mp4 -vf "fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" ../canopy-demo.gif
ls -la .. | grep demo
