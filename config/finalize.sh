#!/bin/bash
set -e

RECORDING_FILE="$1"
FILENAME=$(basename "$RECORDING_FILE")

echo "Processing: $FILENAME"

if ! command -v ffmpeg &> /dev/null || ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    apt-get update && apt-get install -y ffmpeg curl jq coreutils
fi

# Сжимаем аудио с удалением тишины
AUDIO_FILE="/tmp/${FILENAME%.*}.mp3"
echo "Compressing audio..."
ffmpeg -i "$RECORDING_FILE" \
       -vn -ac 1 -ar 16000 -ab 32k \
       -af "silenceremove=stop_periods=-1:stop_duration=1:stop_threshold=-50dB" \
       -y "$AUDIO_FILE" 2>/dev/null

FILESIZE=$(stat -c%s "$AUDIO_FILE")
echo "Compressed: $FILESIZE bytes"

# Транскрибируем через Deepgram с diarization
echo "Transcribing with Deepgram (speaker diarization enabled)..."
RESULT=$(curl -s -X POST \
  --max-time 600 \
  "https://api.deepgram.com/v1/listen?model=nova-2&language=ru&diarize=true&punctuate=true&utterances=true&smart_format=true" \
  -H "Authorization: Token $DEEPGRAM_API_KEY" \
  -H "Content-Type: audio/mp3" \
  --data-binary @"$AUDIO_FILE")

rm "$AUDIO_FILE"

# Проверяем ошибки
if echo "$RESULT" | jq -e '.err_msg' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESULT" | jq -r '.err_msg')
    echo "ERROR from Deepgram: $ERROR_MSG"
    exit 1
fi

# Форматируем транскрипт с говорящими
echo "Formatting transcript..."
TRANSCRIPT=$(echo "$RESULT" | jq -r '
  if .results.utterances then
    .results.utterances[] | 
    "[Говорящий \(.speaker)]: \(.transcript)"
  else
    .results.channels[0].alternatives[0].transcript
  end
' | paste -sd '\n')

if [ -z "$TRANSCRIPT" ] || [ "$TRANSCRIPT" = "null" ]; then
    echo "ERROR: Empty transcript"
    exit 1
fi

# Сохраняем транскрипт
TRANSCRIPT_FILE="recordings/${FILENAME%.*}_transcript.txt"
mkdir -p /root/clawd/recordings
echo "$TRANSCRIPT" > "/root/clawd/$TRANSCRIPT_FILE"

echo "Transcript saved: ${#TRANSCRIPT} chars with speaker labels"

# Отправляем ClawdBot
curl -s -X POST http://clawdbot:18789/hooks \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CLAWDBOT_GATEWAY_TOKEN" \
  --max-time 30 \
  -d "$(jq -n \
    --arg type "meeting_transcript" \
    --arg filename "$FILENAME" \
    --arg transcript_file "$TRANSCRIPT_FILE" \
    --arg instruction "Прочитай файл $TRANSCRIPT_FILE - транскрипт митинга с разметкой [Говорящий 0], [Говорящий 1] и т.д. Определи по контексту и упоминаниям кто есть кто. Создай структурированный список задач с указанием ответственных (используй реальные имена если определишь, иначе номера говорящих)." \
    '{type: $type, filename: $filename, transcript_file: $transcript_file, instruction: $instruction}'
  )"

echo "Done!"
