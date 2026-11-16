# Rest voice cues

Rest starts play “Rest. Take a breath.” Rest completion plays “Rest over. Next
set.” Settings → Rest timer → Voice cues turns both recordings off, including
speech in an already scheduled rest alert. Voice cues start enabled. The
preference belongs to the local profile, is included in full backups, and is
excluded from account sync with the other device settings.

Android and iOS use the completion recording as the scheduled notification
sound, so it can play when the app is backgrounded. Notification permission,
system sound settings, and the notification channel's sound control still apply.
Android uses a separate voice channel because channel sounds are immutable
after creation. Turning voice cues off returns to the ordinary rest-alert channel.

On the web, the open page plays the recording at the deadline even when browser
notification permission is denied. Browsers can block autoplay or suspend a
background tab; a closed page cannot speak. Existing Web Push/OS alerts remain
available independently. Reopening the app re-arms a future rest deadline without
replaying the start phrase or announcing an already elapsed rest.

## Recordings

The source of truth is `tool/generate_rest_voice_cues.sh`, including the two
transcripts. Run `bash tool/generate_rest_voice_cues.sh` to regenerate the Flutter
assets and the identical Android/iOS completion resources. It accepts an output
directory for reproducibility checks. It requires FFmpeg with the Flite filter
and its built-in `slt` voice; no external voice model is downloaded. The bundled
files are mono, 22.05 kHz, 16-bit PCM WAV recordings shorter than three seconds.

The brief preferred development-time ElevenLabs generation. The maintainer's
vaulted-agent Bitwarden credentials returned `invalid_client`, and the alternate
backend had no configured token. Flite supplies the fixed recordings without
adding a runtime service. Regeneration is a development step only: the app uses
bundled assets and never synthesizes speech, sends text to a TTS service, or
requires a TTS API key.
