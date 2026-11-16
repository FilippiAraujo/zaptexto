<p align="center">
  <img src="docs/icon.png" width="128" alt="ZapTexto icon">
</p>

<h1 align="center">ZapTexto</h1>

<p align="center">
  Read your WhatsApp voice messages on the Mac.<br>
  A tiny menu bar app that transcribes the audios of the chat you open, <b>100% on-device</b>.
</p>

<p align="center">
  <a href="https://github.com/FilippiAraujo/zaptexto/releases/latest">Download</a> ·
  <a href="#português">Português</a>
</p>

---

The WhatsApp app on iPhone and Android can transcribe voice messages. The Mac app mostly can't. ZapTexto fills that gap.

- **Automatic:** open a chat with unread voice messages and their transcripts pop up in a small floating panel. New audios that arrive while the chat is open are transcribed too.
- **On demand:** pick any recent chat from the menu bar to transcribe its last 3 audios.
- **Private:** nothing leaves your Mac. Transcription runs on Apple's built-in speech recognition (`SpeechAnalyzer`), and WhatsApp's data is opened read-only.
- **Light:** no dependencies, no models to download, no accounts, no servers. Two Swift files.

  WhatsApp stores voice messages as Ogg/Opus, which macOS can't open directly. ZapTexto includes a tiny Ogg reader and decodes the Opus audio with Apple's built-in decoder.

Transcripts are in Brazilian Portuguese (`pt-BR`). Changing the locale in `main.swift` is a one-line change.

## Requirements

- macOS 26 (Tahoe) or later
- The [WhatsApp app for Mac](https://www.whatsapp.com/download)

That's it. No Homebrew or ffmpeg needed.

## Install

1. Download `ZapTexto.zip` from the [latest release](https://github.com/FilippiAraujo/zaptexto/releases/latest), unzip it and move `ZapTexto.app` to your Applications folder.
2. **First launch.** The app isn't notarized by Apple, so macOS blocks it the first time. Try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   Or, in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/ZapTexto.app
   ```
3. **Full Disk Access.** ZapTexto needs it to read WhatsApp's local files. On first launch it asks for it and opens the right settings page. Add ZapTexto, turn it on and open the app again.

A 💬 icon shows up in the menu bar. Open WhatsApp and go to a chat with new voice messages.

### Build from source

If you'd rather not run a downloaded binary:

```sh
git clone https://github.com/FilippiAraujo/zaptexto.git
cd zaptexto
./build.sh            # builds and installs to ~/Applications/ZapTexto.app
./build.sh --release  # builds build/ZapTexto.zip instead
```

Needs the Xcode command line tools (`xcode-select --install`).

## How it works

```
WhatsApp ──writes──▶ ChatStorage.sqlite + Media/*.opus
                              │ (read-only)
                              ▼
ZapTexto: "WhatsApp is in front and chat X went from N unread to 0"
          → you just opened chat X → take its last N incoming audios
                              │
           OggOpus.swift (.opus → PCM, Apple's decoder)
                              │
               Apple SpeechTranscriber (on-device)
                              │
                     floating panel + cache
```

ZapTexto doesn't use Accessibility and can't see your screen. It figures out which chat you opened from the moment WhatsApp marks its messages as read. It reacts to file changes (no busy polling), and only counts it if you used the Mac's keyboard or mouse in the last few seconds, so reading a chat on your phone doesn't trigger it. That means:

- It only triggers for chats that had **unread** messages. For older audios, use **"Transcribe last audios from…"** in the menu.
- If WhatsApp changes its internal database in an update, ZapTexto may stop working until it's updated.

Transcripts are cached for 30 days in `~/Library/Application Support/ZapTexto/transcripts.json`.

## Uninstall

Quit it from the menu bar, then:

```sh
rm -rf /Applications/ZapTexto.app ~/Applications/ZapTexto.app ~/Library/Application\ Support/ZapTexto
```

You can also remove it from **Full Disk Access** in System Settings.

## Disclaimer

ZapTexto is an independent project. It is not affiliated with, endorsed by, or connected to WhatsApp or Meta. It only reads files that the WhatsApp app already stores on your own Mac. It never talks to WhatsApp's servers or sends messages.

## License

[MIT](LICENSE)

---

## Português

O WhatsApp do celular transcreve áudio. O do Mac, na maioria das contas, não. O **ZapTexto** é um appzinho de barra de menu que resolve isso, **tudo no seu Mac**, sem mandar nada para servidor nenhum.

- **Automático:** abriu uma conversa com áudios não lidos? As transcrições aparecem num painel flutuante. Áudios que chegam com a conversa aberta também são transcritos.
- **Manual:** pelo ícone 💬 → "Transcrever últimos áudios de…", você escolhe uma conversa e ele transcreve os 3 últimos áudios dela.
- **Privado:** usa o reconhecimento de fala da própria Apple, no aparelho. Os dados do WhatsApp são abertos só para leitura.
- **Sem dependências:** não precisa de Homebrew nem ffmpeg. Baixou, abriu, pronto.

### Como instalar

1. Baixe o `ZapTexto.zip` da [última versão](https://github.com/FilippiAraujo/zaptexto/releases/latest), descompacte e arraste o `ZapTexto.app` para Aplicativos.
2. **Primeira vez:** o app não é notarizado pela Apple, então o macOS bloqueia. Tente abrir, vá em **Ajustes do Sistema → Privacidade e Segurança** e clique em **Abrir Mesmo Assim**. Ou rode no Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/ZapTexto.app
   ```
3. **Acesso Total ao Disco:** o app pede na primeira vez e abre a tela certa. Adicione o ZapTexto, ligue a chave e abra ele de novo.

Pronto: vai aparecer um 💬 na barra de menu. Abra uma conversa com áudio novo no WhatsApp.

Requer macOS 26 (Tahoe) ou mais novo. Projeto independente, sem relação com o WhatsApp ou a Meta.
