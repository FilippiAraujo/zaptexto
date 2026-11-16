# ZapTexto

App de barra de menu para macOS que transcreve os áudios do WhatsApp **da conversa que você abre**, sem mandar nada pra fora do Mac.

- Lê o banco local do WhatsApp (`ChatStorage.sqlite`, somente leitura).
- Transcreve com o reconhecimento de fala da Apple (`SpeechAnalyzer`/`SpeechTranscriber`, pt-BR, no aparelho).
- Não usa Acessibilidade: detecta a conversa aberta quando, com o WhatsApp em primeiro plano, o contador de não lidas de uma conversa vai a zero. Áudios que chegam depois nessa conversa também são transcritos.
- Pelo menu dá pra transcrever os 3 últimos áudios de qualquer conversa recente.
- Transcrições ficam em cache em `~/Library/Application Support/ZapTexto/transcricoes.json`.

## Requisitos

- macOS 26+
- `ffmpeg` (`brew install ffmpeg`), para converter o `.opus` do WhatsApp
- Acesso Total ao Disco para o ZapTexto (Ajustes → Privacidade e Segurança)

## Build

```sh
./build.sh   # compila e instala em ~/Applications/ZapTexto.app
```

A assinatura é ad-hoc, então depois de recompilar o macOS pode pedir o Acesso Total ao Disco de novo.
