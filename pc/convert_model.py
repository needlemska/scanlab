"""Конвертация модели в Core ML — там, где это вообще возможно.

Почему отдельный скрипт и почему запускается в CI:
у coremltools на PyPI нет колёс под Windows (только macOS и manylinux1_x86_64),
поэтому `pip install coremltools` на этой машине собирает sdist из исходников.
На Linux-раннере GitHub Actions ставится обычное колесо, и конвертация работает.
Готовый .mlpackage коммитится в ветку `models`; в приложении его компилирует
Xcode на macOS-раннере (шаг сборки), руками .mlmodelc делать не нужно.

Примеры:

    python pc/convert_model.py --source mil --out Models/Demo.mlpackage
    python pc/convert_model.py --source torch --out Models/FrameGate.mlpackage

Источники:
  mil   — крошечная программа на MIL, без torch: проверяет, что toolchain живой.
  torch — MobileNetV3-small (случайные веса) через torch.jit.trace: проверяет
          полный путь «PyTorch → Core ML», который нужен для настоящей модели.
"""

from __future__ import annotations

import argparse
import os
import sys


def convert_mil(out_path: str) -> None:
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 64, 64))])
    def program(x):
        return mb.relu(x=x)

    model = ct.convert(program, minimum_deployment_target=ct.target.iOS17)
    model.save(out_path)


def convert_torch(out_path: str) -> None:
    import coremltools as ct
    import torch
    import torchvision

    net = torchvision.models.mobilenet_v3_small(weights=None).eval()
    example = torch.rand(1, 3, 224, 224)
    with torch.no_grad():
        traced = torch.jit.trace(net, example)

    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=example.shape)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    model.save(out_path)


def directory_size(path: str) -> int:
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert a model to Core ML")
    parser.add_argument("--source", choices=["mil", "torch"], default="mil")
    parser.add_argument("--out", default=os.path.join("Models", "Demo.mlpackage"))
    args = parser.parse_args()

    import coremltools as ct

    print(f"coremltools {ct.__version__}, python {sys.version.split()[0]}, platform {sys.platform}")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    if args.source == "mil":
        convert_mil(args.out)
    else:
        convert_torch(args.out)

    if not os.path.exists(args.out):
        print(f"ERROR: {args.out} was not created")
        return 1

    size = directory_size(args.out)
    print(f"OK: {args.out} ({size / 1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
