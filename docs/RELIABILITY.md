# Fiabilitat i diagnòstic

Subtítol Live no desa àudio per defecte. Per capturar voluntàriament una sessió de
diagnòstic, cal iniciar l’app amb una carpeta explícita:

```sh
SUBTITOL_DIAGNOSTICS_DIR="$PWD/diagnostics" "/Applications/Subtítol Live.app/Contents/MacOS/SubtitolLive"
```

Cada sessió crea una carpeta nova amb:

- `audio.f32le`: PCM mono Float32 little-endian de la sessió;
- `observations.jsonl`: hipòtesis, timestamps, origen live/final, qualitat del timing,
  latència, RMS, pic, clipping, discontinuïtats i paraules detectades amb energia baixa;
- `session.json`: perfil congelat, format i declaració d’opt-in.

La freqüència de mostreig consta a cada observació. La captura s’ha d’eliminar després
de l’anàlisi si conté conversa sensible.

## Perfils

| Perfil | Hop | Mostrar | Substituir | Edat per consolidar |
|---|---:|---:|---:|---:|
| Fiable (defecte) | 300 ms | 3 observacions | 3 observacions | 650 ms |
| Equilibrat | 240 ms | 2 observacions | 2 observacions | 350 ms |
| Immediat | 180 ms | 1 observació | 1 observació | comportament anterior (2 observacions/350 ms per consolidar) |

La selecció es desa entre obertures, però el coordinador la congela en començar una
sessió. El prefix consolidat no canvia durant la gravació; la descodificació final pot
reemplaçar una sola vegada el tram fiable dels últims sis segons.

## Porta d’entrada per a VAD o un model nou

VAD queda desactivat fins que un replay reproduïble demostri almenys un 80% menys
d’insercions durant no-parla i menys de 0,5 punts percentuals addicionals d’eliminació
de parla suau. El model empaquetat tampoc se substitueix sense recuperar el checkpoint
d’origen i comparar-lo amb FP16 sobre el mateix corpus. El manifest instal·lat és
`ModelManifest.json`.
