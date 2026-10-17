#!/usr/bin/env python3
"""Converts pyannote segmentation-3.0 (MIT) to Core ML for the speaker-change detector.

Source: the ONNX export at onnx-community/pyannote-segmentation-3.0 (same weights as
pyannote/segmentation-3.0, which is gated). Input: 10 s of 16 kHz mono audio in -1..1;
output: 589 frames x 7 powerset classes (0 silence, 1-3 one speaker, 4-6 two at once),
one frame every 270 samples. The conversion keeps float32, so it matches ONNX Runtime.

The ONNX graph has a dynamic branch Core ML cannot take, so the network (PyanNet:
SincNet, four bidirectional LSTMs, two linear layers, classifier) is rebuilt in
PyTorch from the ONNX weights, with the sinc filterbank the export already computed.

Run with .work/venv-coreml (coremltools, torch 2.7, onnx, onnxruntime):
    .work/venv-coreml/bin/python scripts/convert-speaker-model.py [WAV_FOR_PARITY]
Writes models/veus-segmentacio/segmentacio.mlpackage and LICENSE.
"""
import hashlib, pathlib, sys, urllib.request, wave

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "models" / "veus-segmentacio"
REVISION = "733a93b6473d019a773298e08cefa686894b1854"
ONNX_URL = f"https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/{REVISION}/onnx/model.onnx"
ONNX_SHA256 = "057ee564753071c0b09b5b611648b50ac188d50846bff5f01e9f7bbf1591ea25"
LICENSE_URL = "https://huggingface.co/pyannote/segmentation-3.0/resolve/main/LICENSE"
SAMPLES = 160_000


def fetch(url: str, path: pathlib.Path) -> None:
    if not path.exists():
        urllib.request.urlretrieve(url, path)


def PyanNet(weights):
    import torch
    from torch import nn

    class Net(nn.Module):
        def __init__(self):
            super().__init__()
            w = weights
            self.wav_norm = nn.InstanceNorm1d(1, affine=True)
            self.wav_norm.weight.data, self.wav_norm.bias.data = w["sincnet.wav_norm1d.weight"], w["sincnet.wav_norm1d.bias"]
            self.register_buffer("filters", w["/sincnet/conv1d.0/Concat_2_output_0"].float())
            self.convs = nn.ModuleList([nn.Conv1d(80, 60, 5), nn.Conv1d(60, 60, 5)])
            for index, conv in enumerate(self.convs, start=1):
                conv.weight.data = w[f"sincnet.conv1d.{index}.weight"]
                conv.bias.data = w[f"sincnet.conv1d.{index}.bias"]
            self.norms = nn.ModuleList([nn.InstanceNorm1d(c, affine=True) for c in (80, 60, 60)])
            for index, norm in enumerate(self.norms):
                norm.weight.data = w[f"sincnet.norm1d.{index}.weight"]
                norm.bias.data = w[f"sincnet.norm1d.{index}.bias"]
            self.lstm = nn.LSTM(60, 128, num_layers=4, bidirectional=True, batch_first=True)
            # ONNX gates are i, o, f, c; PyTorch's are i, f, c, o.
            def reorder(t):
                i, o, f, c = t.chunk(4, dim=0)
                return torch.cat([i, f, c, o], dim=0)
            names = [("onnx::LSTM_784", "onnx::LSTM_785", "onnx::LSTM_783"),
                     ("onnx::LSTM_827", "onnx::LSTM_828", "onnx::LSTM_826"),
                     ("onnx::LSTM_870", "onnx::LSTM_871", "onnx::LSTM_869"),
                     ("onnx::LSTM_913", "onnx::LSTM_914", "onnx::LSTM_912")]
            for layer, (wi, wh, b) in enumerate(names):
                for direction, suffix in enumerate(("", "_reverse")):
                    getattr(self.lstm, f"weight_ih_l{layer}{suffix}").data = reorder(w[wi][direction])
                    getattr(self.lstm, f"weight_hh_l{layer}{suffix}").data = reorder(w[wh][direction])
                    bias_ih, bias_hh = w[b][direction].chunk(2)
                    getattr(self.lstm, f"bias_ih_l{layer}{suffix}").data = reorder(bias_ih)
                    getattr(self.lstm, f"bias_hh_l{layer}{suffix}").data = reorder(bias_hh)
            self.linear = nn.ModuleList([nn.Linear(256, 128), nn.Linear(128, 128)])
            for index, (m, b) in enumerate([("onnx::MatMul_915", "linear.0.bias"), ("onnx::MatMul_916", "linear.1.bias")]):
                self.linear[index].weight.data = w[m].T.contiguous()
                self.linear[index].bias.data = w[b]
            self.classifier = nn.Linear(128, 7)
            self.classifier.weight.data = w["onnx::MatMul_917"].T.contiguous()
            self.classifier.bias.data = w["classifier.bias"]

        def forward(self, audio):
            act = nn.functional.leaky_relu
            pool = nn.functional.max_pool1d
            x = self.wav_norm(audio)
            x = act(self.norms[0](pool(torch.abs(nn.functional.conv1d(x, self.filters, stride=10)), 3, 3)), 0.01)
            for conv, norm in zip(self.convs, self.norms[1:]):
                x = act(norm(pool(conv(x), 3, 3)), 0.01)
            x, _ = self.lstm(x.transpose(1, 2))
            for linear in self.linear:
                x = act(linear(x), 0.01)
            return torch.log_softmax(self.classifier(x), dim=-1)

    return Net()


def main() -> None:
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx import numpy_helper

    OUT.mkdir(parents=True, exist_ok=True)
    onnx_path = OUT / "source.onnx"
    fetch(ONNX_URL, onnx_path)
    digest = hashlib.sha256(onnx_path.read_bytes()).hexdigest()
    if digest != ONNX_SHA256:
        sys.exit(f"ONNX SHA-256 {digest} does not match the pinned {ONNX_SHA256}")
    fetch(LICENSE_URL, OUT / "LICENSE")

    weights = {i.name: torch.from_numpy(numpy_helper.to_array(i).copy())
               for i in onnx.load(onnx_path).graph.initializer}
    module = PyanNet(weights).eval()
    example = torch.zeros(1, 1, SAMPLES)
    traced = torch.jit.trace(module, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, 1, SAMPLES), dtype=np.float32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "pyannote segmentation-3.0 (MIT, CNRS): speaker activity, 7-class powerset, 10 s at 16 kHz"
    mlmodel.save(str(OUT / "segmentacio.mlpackage"))

    # Parity: frame classes from Core ML against ONNX Runtime on real speech.
    if len(sys.argv) > 1:
        with wave.open(sys.argv[1]) as w:
            audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    else:
        rng = np.random.default_rng(0)
        audio = (rng.standard_normal(SAMPLES * 6) * 0.05).astype(np.float32)
    session = ort.InferenceSession(str(onnx_path))
    loaded = ct.models.MLModel(str(OUT / "segmentacio.mlpackage"))
    agree = total = 0
    worst = 0.0
    for start in range(0, len(audio) - SAMPLES + 1, SAMPLES):
        chunk = audio[start:start + SAMPLES][None, None, :]
        reference = session.run(None, {"input_values": chunk})[0][0]
        candidate = loaded.predict({"audio": chunk})["logits"][0]
        agree += int((reference.argmax(-1) == candidate.argmax(-1)).sum())
        total += reference.shape[0]
        worst = max(worst, float(np.abs(reference - candidate).max()))
    print(f"parity: {agree}/{total} frames agree, max |Δlogit| {worst:.5f}")
    onnx_path.unlink()


if __name__ == "__main__":
    main()
