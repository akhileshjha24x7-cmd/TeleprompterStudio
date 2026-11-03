# TeleprompterStudio

An Android-first Flutter teleprompter and voice-recording app.

## Features planned in this starter
- Paste a script and split it into lines.
- Timed line-by-line teleprompter with pause, resume, next and previous.
- Audio-only recording mode (camera is not requested or started).
- Optional video mode is planned as a separate feature.
- Recording takes are listed as timeline segments; delete and re-record takes.
- GitHub Actions builds an Android APK.

## Build
Open this repository in GitHub, go to **Actions**, select **Build Android APK**, and run the workflow. Download the `teleprompterstudio-apk` artifact from the completed run.

> This is an initial project scaffold. Test on a physical Android device before using it for production recording. MP3 export and fine-grained waveform trimming are not yet included in this scaffold.
