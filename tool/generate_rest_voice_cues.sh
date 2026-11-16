#!/usr/bin/env bash
# Development-time speech generation only. Requires ffmpeg with the flite filter.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_root=${1:-$repo_root}
mkdir -p "$output_root/assets/audio" \
  "$output_root/android/app/src/main/res/raw" "$output_root/ios/Runner"

ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "flite=text='Rest. Take a breath.':voice=slt" \
  -ar 22050 -ac 1 -c:a pcm_s16le "$output_root/assets/audio/rest_start.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "flite=text='Rest over. Next set.':voice=slt" \
  -ar 22050 -ac 1 -c:a pcm_s16le "$output_root/assets/audio/rest_complete.wav"

# OS notification sounds must be native resources, outside Flutter's bundle.
cp "$output_root/assets/audio/rest_complete.wav" \
  "$output_root/android/app/src/main/res/raw/rest_complete.wav"
cp "$output_root/assets/audio/rest_complete.wav" \
  "$output_root/ios/Runner/rest_complete.wav"
